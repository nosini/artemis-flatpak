#!/usr/bin/env bash
# Install the build exported to repo/ and run tests/check-installed.sh inside
# the installed app's sandbox, so the checks run against the Platform runtime
# rather than the SDK. Run from anywhere after building with --repo=repo.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${APP_ID:=$(sed -n 's/^id: *//p' ./*.yml)}"
: "${FLATPAK_BRANCH:=stable}"
: "${FLATPAK_ARCH:=$(flatpak --default-arch)}"
ref="app/$APP_ID/$FLATPAK_ARCH/$FLATPAK_BRANCH"

if ! flatpak --user remotes --columns=name | grep -qx local-test; then
  flatpak --user remote-add --no-gpg-verify local-test "$PWD/repo"
fi
url=$(flatpak --user remotes --columns=name,url | awk '$1 == "local-test" { print $2 }')
if [[ "$url" != "file://$PWD/repo" ]]; then
  echo "The local-test remote points to $url, not this checkout's repo/." >&2
  echo 'Remove it with: flatpak --user remote-delete local-test' >&2
  exit 1
fi

# Don't replace an existing installation when running locally.
if flatpak info --user "$ref" >/dev/null 2>&1; then
  echo "These checks need a fresh installation; $ref is already installed." >&2
  echo "Remove it with: flatpak --user uninstall $ref" >&2
  exit 1
fi

# flatpak-builder doesn't always refresh the summary of an existing repo.
flatpak build-update-repo repo
flatpak --user install --noninteractive --no-related local-test "$ref"
flatpak run --user --arch="$FLATPAK_ARCH" --branch="$FLATPAK_BRANCH" \
  --command=sh "$APP_ID" -s < tests/check-installed.sh
