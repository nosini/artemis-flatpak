#!/usr/bin/env bash
# Tests for scripts/prepare-repository.sh: publishes hand-made builds to a
# local web server and checks history, signatures, deltas and the files for
# users. Needs flatpak, ostree, gpg, curl and python3, but no SDK.
set -euo pipefail
script=$(realpath "$(dirname "$0")/../prepare-repository.sh")
tmp=$(mktemp -d)
server=
cleanup() {
  [[ -n "$server" ]] && kill "$server" 2> /dev/null
  if [[ -d "$tmp/gnupg" ]]; then
    GNUPGHOME=$tmp/gnupg gpgconf --kill all || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

export GNUPGHOME=$tmp/gnupg FLATPAK_USER_DIR=$tmp/flatpak-user
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
  --quick-generate-key 'Test signing' ed25519 sign 0 2> /dev/null
GPG_KEY=$(gpg --batch --list-secret-keys --with-colons | awk -F: '$1 == "fpr" { print $10; exit }')
gpg --batch --export "$GPG_KEY" > "$tmp/key.gpg"
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
export RETRY_DELAY=0 GPG_KEY APP_ID=eu.nosini.Test APP_NAME=Test REMOTE_NAME=test \
  REPO_URL=http://127.0.0.1:$port/ HOMEPAGE=https://example.invalid/ FLATPAK_BRANCH=stable
mkdir "$tmp/site"
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$tmp/site" > /dev/null 2>&1 &
server=$!

python3 - "$tmp/icon.png" <<'EOF'
import struct, sys, zlib
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
rows = b"".join(b"\0" + b"\xff\0\0\xff" * 128 for _ in range(128))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 128, 128, 8, 6, 0, 0, 0))
                              + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
EOF

# build NAME VERSION ARCH...: export the app and a Locale extension of
# VERSION for each ARCH into $tmp/NAME-ARCH/repo, as the build job does.
build() {
  local name=$1 version=$2 arch dir
  shift 2
  for arch in "$@"; do
    dir=$(mktemp -d "$tmp/build.XXXXXX")
    mkdir -p "$dir/app/files/bin" "$dir/app/files/share/metainfo" \
      "$dir/app/files/share/app-info/icons/flatpak/128x128" "$dir/app/files/share/app-info/xmls" \
      "$dir/app/export" "$dir/locale/files"
    printf '[Application]\nname=%s\nruntime=org.freedesktop.Platform/%s/26.08\nsdk=org.freedesktop.Sdk/%s/26.08\ncommand=test\n' \
      "$APP_ID" "$arch" "$arch" > "$dir/app/metadata"
    printf '#!/bin/sh\necho %s\n' "$version" > "$dir/app/files/bin/test"
    head -c 100000 /dev/zero > "$dir/app/files/share/unchanged"
    cat > "$dir/app/files/share/metainfo/$APP_ID.metainfo.xml" <<EOF
<?xml version="1.0"?>
<component type="desktop-application"><id>$APP_ID</id><name>Test</name>
<summary xml:lang="de">Ein Test</summary><summary>A test  &amp; more</summary></component>
EOF
    cp "$tmp/icon.png" "$dir/app/files/share/app-info/icons/flatpak/128x128/$APP_ID.png"
    printf '<components version="0.14" origin="%s"><component type="desktop-application"><id>%s</id><name>Test</name><summary>A test</summary></component></components>\n' \
      "$APP_ID" "$APP_ID" | gzip -n > "$dir/app/files/share/app-info/xmls/$APP_ID.xml.gz"
    printf '[Runtime]\nname=%s.Locale\n\n[ExtensionOf]\nref=app/%s/%s/stable\n' \
      "$APP_ID" "$APP_ID" "$arch" > "$dir/locale/metadata"
    echo "$version" > "$dir/locale/files/de"
    mkdir -p "$tmp/$name-$arch"
    flatpak build-export --no-update-summary --arch="$arch" "$tmp/$name-$arch/repo" "$dir/app" stable > /dev/null
    flatpak build-export --no-update-summary --runtime --arch="$arch" \
      "$tmp/$name-$arch/repo" "$dir/locale" stable > /dev/null
    rm -rf "$dir"
  done
}

# publish NAME: run the script on NAME's builds and deploy the result.
publish() {
  rm -rf "$tmp/work"
  mkdir "$tmp/work"
  (cd "$tmp/work" && bash "$script" "$tmp/$1"-*/repo) > "$tmp/publish.log" 2>&1 \
    || { cat "$tmp/publish.log" >&2; fail "publishing $1 failed"; }
  find "$tmp/site" -mindepth 1 -delete
  cp -a "$tmp/work/signed-repo/." "$tmp/site/"
}
app_ref() {
  echo "app/$APP_ID/${1:-x86_64}/stable"
}
versions() {
  ostree --repo="$tmp/site" log "$(app_ref)" | grep -c '^commit'
}

build v1 1.0 x86_64 aarch64
publish v1
grep -q 'starting a new repository' "$tmp/publish.log" || fail 'expected a new repository'
[[ "$(versions)" == 1 ]] || fail 'first publication should have one version'

# Clients that only know the public key accept every ref and catalog.
ostree --repo="$tmp/client" init --mode=bare-user-only
ostree --repo="$tmp/client" remote add --gpg-import="$tmp/key.gpg" \
  --set=gpg-verify=true --set=gpg-verify-summary=true test "$REPO_URL"
for arch in x86_64 aarch64; do
  ostree --repo="$tmp/client" pull --commit-metadata-only test \
    "$(app_ref $arch)" "runtime/$APP_ID.Locale/$arch/stable" "appstream2/$arch" > /dev/null \
    || fail "unsigned refs for $arch"
done

# The files users install from describe the app and point to its icon.
for file in test.flatpakrepo test.flatpakref; do
  grep -qx 'Comment=A test & more' "$tmp/site/$file" || fail "summary missing in $file"
  grep -qx "Icon=${REPO_URL}test.png" "$tmp/site/$file" || fail "icon missing in $file"
done
cmp -s "$tmp/icon.png" "$tmp/site/test.png" || fail 'icon not published'
[[ -n "$(find "$tmp/site/deltas" -name superblock)" ]] || fail 'no static deltas'
grep -q '^\[remote' "$tmp/site/config" && fail 'the download remote was published'

# A new version becomes the child of the published one; the old one stays
# signed and available.
first=$(ostree --repo="$tmp/site" rev-parse "$(app_ref)")
build v2 2.0 x86_64 aarch64
publish v2
[[ "$(versions)" == 2 ]] || fail 'second publication should have two versions'
[[ "$(ostree --repo="$tmp/site" rev-parse "$(app_ref)^")" == "$first" ]] \
  || fail 'new version is not a child of the published one'
ostree --repo="$tmp/client" pull --commit-metadata-only test "$first" > /dev/null \
  || fail 'earlier version not signed'
FLATPAK_USER_DIR=$tmp/flatpak-user flatpak --user remote-add --from test "$tmp/site/test.flatpakrepo"
flatpak --user remote-info --log test "$APP_ID" | grep -q "$first" \
  || fail 'Flatpak does not list the earlier version'

# A build with the same files adds no version.
second=$(ostree --repo="$tmp/site" rev-parse "$(app_ref)")
build v2again 2.0 x86_64 aarch64
publish v2again
[[ "$(ostree --repo="$tmp/site" rev-parse "$(app_ref)")" == "$second" ]] \
  || fail 'unchanged build added a version'

# History is limited to HISTORY_DEPTH earlier versions.
build v3 3.0 x86_64 aarch64
HISTORY_DEPTH=1 publish v3
[[ "$(versions)" == 2 ]] || fail 'HISTORY_DEPTH=1 should keep two versions'

# A dropped architecture disappears from the repository.
build v4 4.0 x86_64
publish v4
ostree --repo="$tmp/site" refs | grep -q aarch64 && fail 'aarch64 refs were kept'

# KEEP_HISTORY=false starts over.
build v5 5.0 x86_64
KEEP_HISTORY=false publish v5
[[ "$(versions)" == 1 ]] || fail 'KEEP_HISTORY=false kept earlier versions'

# A published repository that doesn't match the key stops publication.
mv "$GNUPGHOME" "$tmp/gnupg-old"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
  --quick-generate-key 'Other key' ed25519 sign 0 2> /dev/null
GPG_KEY=$(gpg --batch --list-secret-keys --with-colons | awk -F: '$1 == "fpr" { print $10; exit }')
build v6 6.0 x86_64
rm -rf "$tmp/work" && mkdir "$tmp/work"
if (cd "$tmp/work" && bash "$script" "$tmp"/v6-*/repo) > "$tmp/publish.log" 2>&1; then
  fail 'published on top of a repository signed with another key'
fi
GNUPGHOME=$tmp/gnupg-old gpgconf --kill all || true

echo 'prepare-repository.sh: all tests passed'
