#!/usr/bin/env bash
# Add tested per-architecture builds to the published repository in
# signed-repo/, sign them, and write the files used to install the package
# and receive updates. Usage: prepare-repository.sh REPO...
set -euo pipefail

: "${GNUPGHOME:?}"
: "${GPG_KEY:?}"
: "${REPO_URL:?}"
: "${HOMEPAGE:?}"
: "${APP_ID:?}"
: "${APP_NAME:?}"
: "${REMOTE_NAME:?}"
: "${FLATPAK_BRANCH:=stable}"
# Earlier versions kept for each app and extension, so users can roll back
# with `flatpak update --commit`. Set KEEP_HISTORY=false to start over.
: "${HISTORY_DEPTH:=5}"
: "${KEEP_HISTORY:=true}"
if (( $# == 0 )); then
  echo "Usage: $0 REPO..." >&2
  exit 2
fi
if [[ -e signed-repo ]]; then
  echo 'signed-repo already exists; remove it first.' >&2
  exit 1
fi
sign=(--gpg-sign="$GPG_KEY" --gpg-homedir="$GNUPGHOME")
key_file=$(mktemp)
trap 'rm -f "$key_file"' EXIT
gpg --batch --export --export-options export-minimal "$GPG_KEY" > "$key_file"
test -s "$key_file"

ostree --repo=signed-repo init --mode=archive-z2

# Start from the published repository, verified with the signing key, so new
# builds become children of the published commits.
if [[ "$KEEP_HISTORY" == true ]]; then
  status=$(curl --silent --show-error --retry 5 --output /dev/null \
    --write-out '%{http_code}' "${REPO_URL}summary")
  case "$status" in
    200)
      ostree --repo=signed-repo remote add --gpg-import="$key_file" \
        --set=gpg-verify=true --set=gpg-verify-summary=true published "$REPO_URL"
      # GitHub Pages sometimes answers the many object requests with 503.
      # Pulls resume, so retry a few times.
      for attempt in 1 2 3 4 5; do
        if ostree --repo=signed-repo pull --mirror --depth="$HISTORY_DEPTH" published; then
          break
        elif (( attempt == 5 )); then
          exit 1
        fi
        sleep $(( attempt * ${RETRY_DELAY:-30} ))
      done
      ostree --repo=signed-repo remote delete published
      ;;
    404)
      echo "Nothing published at $REPO_URL yet; starting a new repository."
      ;;
    *)
      echo "Unexpected HTTP status $status for ${REPO_URL}summary." >&2
      exit 1
      ;;
  esac
fi

# Commit every app and extension ref, including the Locale and Debug
# extensions flatpak-builder exports automatically. A ref whose content
# didn't change keeps its published commit.
declare -A built=()
for input in "$@"; do
  while read -r ref; do
    built[$ref]=1
    flatpak build-commit-from --untrusted --no-update-summary "${sign[@]}" \
      --src-repo="$input" signed-repo "$ref"
  done < <(ostree --repo="$input" refs | grep -E '^(app|runtime)/')
done
# Refs the new build no longer has, such as a dropped architecture, are
# removed rather than served with stale content.
while read -r ref; do
  if [[ -z "${built[$ref]:-}" ]]; then
    ostree --repo=signed-repo refs --delete "$ref"
  fi
done < <(ostree --repo=signed-repo refs | grep -E '^(app|runtime)/')

# Generate the catalogs again, so they come from the new builds and are signed
# together with the summary. Static deltas let installs and updates download a
# few large files instead of every file separately.
ostree --repo=signed-repo refs --delete appstream
ostree --repo=signed-repo refs --delete appstream2
flatpak build-update-repo "${sign[@]}" --generate-static-deltas \
  --prune --prune-depth="$HISTORY_DEPTH" \
  --title="$APP_NAME" --default-branch="$FLATPAK_BRANCH" signed-repo

public_key=$(base64 -w0 < "$key_file")

# Software centers show a summary and an icon when the remote or app is added.
# Both come from the built app, so they also work when upstream provides the
# metainfo and icon.
app_ref=$(ostree --repo=signed-repo refs | grep -m1 "^app/$APP_ID/")
summary=$(ostree --repo=signed-repo cat "$app_ref" "/files/share/metainfo/$APP_ID.metainfo.xml" \
  | python3 -c '
import sys
import xml.etree.ElementTree as ET
lang = "{http://www.w3.org/XML/1998/namespace}lang"
summary = next(e for e in ET.parse(sys.stdin).getroot().findall("summary") if lang not in e.attrib)
print(" ".join(summary.text.split()))
')
test -n "$summary"
ostree --repo=signed-repo cat "$app_ref" "/files/share/app-info/icons/flatpak/128x128/$APP_ID.png" \
  > "signed-repo/$REMOTE_NAME.png"
test -s "signed-repo/$REMOTE_NAME.png"

cat > "signed-repo/$REMOTE_NAME.flatpakrepo" <<REPO
[Flatpak Repo]
Title=$APP_NAME
Url=$REPO_URL
Homepage=$HOMEPAGE
Comment=$summary
Description=Unofficial Flatpak build of $APP_NAME
Icon=$REPO_URL$REMOTE_NAME.png
GPGKey=$public_key
REPO
cat > "signed-repo/$REMOTE_NAME.flatpakref" <<REF
[Flatpak Ref]
Name=$APP_ID
Branch=$FLATPAK_BRANCH
Title=$APP_NAME
Url=$REPO_URL
Homepage=$HOMEPAGE
Comment=$summary
Description=Unofficial Flatpak build of $APP_NAME
Icon=$REPO_URL$REMOTE_NAME.png
RuntimeRepo=https://dl.flathub.org/repo/flathub.flatpakrepo
IsRuntime=false
SuggestRemoteName=$REMOTE_NAME
GPGKey=$public_key
REF

# OSTree scratch files must not be published.
rm -rf signed-repo/tmp
