#!/usr/bin/env bash
# The checker command update-upstream.sh runs in the update workflow. It runs
# flatpak-external-data-checker and, when that moves Artemis to a new release,
# regenerates nuget-sources.json for it, since Artemis releases often change
# their NuGet packages.
#
# The regeneration runs scripts/generate-dotnet-deps.sh in the image the
# Flatpak build uses, which has flatpak and can run the SDK when privileged.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${APP_ID:?}"
: "${CHECKER_IMAGE:=ghcr.io/flathub/flatpak-external-data-checker:latest}"
manifest="$APP_ID.yml"
runtime=$(sed -n "s/^runtime-version: *'\{0,1\}\([0-9.]*\).*/\1/p" "$manifest")

commit() { sed -n 's/^ *commit: *//p' "$manifest"; }
old=$(commit)

docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e GITHUB_TOKEN \
  -v "$PWD:/work" -w /work "$CHECKER_IMAGE" --edit-only "$manifest"

if [[ "$(commit)" == "$old" ]]; then
  exit 0
fi
echo "Regenerating the NuGet sources for $(commit)."
docker run --rm --privileged -e APP_ID -v "$PWD:/work" -w /work \
  "ghcr.io/flathub-infra/flatpak-github-actions:freedesktop-$runtime" \
  bash -euo pipefail -c '
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    flatpak install -y --noninteractive flathub "org.freedesktop.Sdk//$1" \
      "org.freedesktop.Sdk.Extension.dotnet10//$1"
    status=0
    bash scripts/generate-dotnet-deps.sh || status=$?
    chown -R "$(stat -c %u:%g .)" nuget-sources.json .cache
    exit "$status"
  ' bash "$runtime"
