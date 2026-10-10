#!/usr/bin/env bash
# Regenerate nuget-sources.json, the NuGet packages the offline build
# restores, for the Artemis commit and patches pinned in the manifest.
#
# Runs flatpak-dotnet-generator from the pinned flatpak-builder-tools, which
# restores the project with `flatpak run` in the SDK and its .NET extension:
#   flatpak install --user flathub org.freedesktop.Sdk//26.08 \
#     org.freedesktop.Sdk.Extension.dotnet10//26.08
set -euo pipefail
cd "$(dirname "$0")/.."

: "${APP_ID:=$(sed -n 's/^id: *//p' ./*.yml)}"
manifest="$APP_ID.yml"
dotnet=10
freedesktop=$(sed -n "s/^runtime-version: *'\{0,1\}\([0-9.]*\).*/\1/p" "$manifest")
project=src/Artemis.UI.Linux/Artemis.UI.Linux.csproj
output=nuget-sources.json

# The manifest has a single Git source; its commit is the one to restore.
url=$(sed -n 's/^ *url: *\(.*\.git\)$/\1/p' "$manifest")
commit=$(sed -n 's/^ *commit: *//p' "$manifest")
if [[ "$url" == *$'\n'* || ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "$manifest must have a single Git source with a commit." >&2
  exit 1
fi
mapfile -t patches < <(sed -n 's/^ *path: *\(patches\/.*\.patch\)$/\1/p' "$manifest")

source=.cache/artemis-source
if [[ ! -d "$source/.git" ]]; then
  rm -rf "$source"
  git init -q "$source"
fi
git -C "$source" fetch -q --depth=1 "$url" "$commit"
git -C "$source" checkout -q --force --detach FETCH_HEAD
git -C "$source" clean -qfdx
for patch in "${patches[@]}"; do
  git -C "$source" apply "$PWD/$patch"
done

tools=$(bash scripts/builder-tools.sh)
generated=$(mktemp --tmpdir=.cache nuget-sources.XXXXXX.json)
trap 'rm -f "$generated"' EXIT
# The publish step builds a self-contained app, so restore it that way too.
python3 "$tools/dotnet/flatpak-dotnet-generator.py" "$generated" "$source/$project" \
  --dotnet="$dotnet" --freedesktop="$freedesktop" --runtime=linux-x64 \
  --dotnet-args -p:SelfContained=true

# The generator ignores failed restores, so check that the result has the
# packages every Artemis build needs. The .NET runtime packs come from the SDK
# extension in the version that matches its SDK, so they are left out.
python3 - "$generated" "$output" <<'EOF'
import json
import sys

generated, output = sys.argv[1:]
with open(generated, encoding="utf-8") as f:
    sources = json.load(f)
names = {s["dest-filename"].lower() for s in sources}
for required in ("avalonia.desktop.", "rgb.net.core.", "skiasharp."):
    if not any(name.startswith(required) for name in names):
        sys.exit(f"The restore failed: no {required}* package was found.")
from_extension = (
    "microsoft.aspnetcore.app.runtime.",
    "microsoft.netcore.app.runtime.",
    "microsoft.netcore.app.crossgen2.",
    "microsoft.net.illink.tasks.",
)
sources = [s for s in sources if not s["dest-filename"].lower().startswith(from_extension)]
with open(output, "w", encoding="utf-8") as f:
    json.dump(sources, f, indent=4)
    f.write("\n")
print(f"Wrote {len(sources)} packages to {output}.")
EOF
