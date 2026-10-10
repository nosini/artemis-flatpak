#!/usr/bin/env bash
# Tests scripts/generate-dotnet-deps.sh against a local upstream repository,
# with a fake `flatpak` standing in for `dotnet restore` in the SDK. The
# pinned flatpak-dotnet-generator itself is fetched and run for real.
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# An upstream repository with the project file the script restores.
upstream="$work/upstream"
git init -q "$upstream"
mkdir -p "$upstream/src/Artemis.UI.Linux"
echo '<Project />' > "$upstream/src/Artemis.UI.Linux/Artemis.UI.Linux.csproj"
git -C "$upstream" add .
git -C "$upstream" -c user.name=t -c user.email=t@t commit -qm upstream
commit=$(git -C "$upstream" rev-parse HEAD)

# A packaging checkout with a patch that marks the project file.
repo="$work/repo"
mkdir -p "$repo/scripts" "$repo/patches"
cp "$here/scripts/generate-dotnet-deps.sh" "$here/scripts/builder-tools.sh" "$repo/scripts/"
if [[ -d "$here/.cache/flatpak-builder-tools" ]]; then
  mkdir -p "$repo/.cache"
  cp -r "$here/.cache/flatpak-builder-tools" "$repo/.cache/"
fi
cat > "$repo/patches/0001-mark.patch" <<'EOF'
--- a/src/Artemis.UI.Linux/Artemis.UI.Linux.csproj
+++ b/src/Artemis.UI.Linux/Artemis.UI.Linux.csproj
@@ -1 +1 @@
-<Project />
+<Project><!-- patched --></Project>
EOF
cat > "$repo/eu.nosini.Test.yml" <<EOF
id: eu.nosini.Test
runtime: org.freedesktop.Platform
runtime-version: '26.08'
modules:
  - name: artemis
    sources:
      - type: git
        url: file://$upstream/.git
        commit: $commit
        x-checker-data:
          url: https://example.com/graphql/?query=x
      - type: patch
        path: patches/0001-mark.patch
      - nuget-sources.json
EOF

# The fake flatpak records its arguments, checks that the patched project is
# restored, and "restores" the packages named in FAKE_PACKAGES.
mkdir "$work/bin"
cat > "$work/bin/flatpak" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$FAKE_LOG"
packages=; project=
while (( $# )); do
  case "$1" in
    --packages) packages=$2; shift ;;
    *.csproj) project=$1 ;;
  esac
  shift
done
grep -q patched "$project"
for package in $FAKE_PACKAGES; do
  name=${package%@*}; version=${package#*@}
  mkdir -p "$packages/$name/$version"
  python3 -c 'import base64, hashlib, sys
print(base64.b64encode(hashlib.sha512(sys.argv[1].encode()).digest()).decode(), end="")' \
    "$name" > "$packages/$name/$version/$name.$version.nupkg.sha512"
done
EOF
chmod +x "$work/bin/flatpak"
export PATH="$work/bin:$PATH" FAKE_LOG="$work/flatpak.log"

# A complete restore: runtime packs from the SDK extension are left out.
export FAKE_PACKAGES='avalonia.desktop@11.3.10 rgb.net.core@3.1.0 skiasharp@2.88.9
  microsoft.netcore.app.runtime.linux-x64@10.0.12 microsoft.aspnetcore.app.runtime.linux-x64@10.0.12'
bash "$repo/scripts/generate-dotnet-deps.sh" > /dev/null
grep -qx 'org.freedesktop.Sdk.Extension.dotnet10//26.08' "$FAKE_LOG" || fail 'wrong SDK extension'
grep -qx -- '--runtime=org.freedesktop.Sdk//26.08' "$FAKE_LOG" || fail 'wrong SDK'
grep -qx 'linux-x64' "$FAKE_LOG" || fail 'not restored for linux-x64'
grep -qx -- '-p:SelfContained=true' "$FAKE_LOG" || fail 'not restored as self-contained'
python3 - "$repo/nuget-sources.json" <<'EOF'
import hashlib, json, sys
sources = json.load(open(sys.argv[1]))
names = sorted(s["dest-filename"] for s in sources)
assert names == ["avalonia.desktop.11.3.10.nupkg", "rgb.net.core.3.1.0.nupkg",
                 "skiasharp.2.88.9.nupkg"], names
for s in sources:
    name = s["dest-filename"].split(".")[0]
    assert s["url"].startswith("https://api.nuget.org/v3-flatcontainer/"), s
    assert s["url"].endswith("/" + s["dest-filename"]), s
    assert s["dest"] == "nuget-sources", s
assert sources[2]["sha512"] == hashlib.sha512(b"skiasharp").hexdigest()
EOF

# A failed restore stops the script and keeps the previous file.
cp "$repo/nuget-sources.json" "$work/previous.json"
export FAKE_PACKAGES='rgb.net.core@3.1.0'
if bash "$repo/scripts/generate-dotnet-deps.sh" > /dev/null 2>&1; then
  fail 'an incomplete restore was accepted'
fi
cmp -s "$repo/nuget-sources.json" "$work/previous.json" || fail 'previous file was replaced'

echo 'generate-dotnet-deps.sh tests passed.'
