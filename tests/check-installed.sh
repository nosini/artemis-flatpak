# shellcheck shell=sh
# Runs inside the installed app's sandbox (see scripts/test-installed.sh).
# There is no display, sound server or session bus in CI, so keep these checks
# headless: Artemis itself needs a display, so check what it loads instead.
set -eu
dir=/app/lib/artemis

test -x /app/bin/artemis
test -x "$dir/Artemis.UI.Linux"
# The launcher switches off Artemis's own updater.
grep -q -- '--disable-updating' /app/bin/artemis

# The native libraries of the .NET runtime and the NuGet packages must find
# their dependencies in the Platform runtime.
for lib in libcoreclr.so libSkiaSharp.so libHarfBuzzSharp.so libe_sqlite3.so \
  libSystem.Native.so libSystem.Security.Cryptography.Native.OpenSsl.so; do
  test -f "$dir/$lib"
  if ldd "$dir/$lib" | grep 'not found'; then
    echo "$lib has missing dependencies." >&2
    exit 1
  fi
done
# .NET loads ICU, OpenSSL and the X11 libraries with dlopen.
for lib in libicuuc.so.* libssl.so.3 libX11.so.6 libXrandr.so.2 libXi.so.6 \
  libXcursor.so.1 libICE.so.6 libSM.so.6 libfontconfig.so.1; do
  # shellcheck disable=SC2086 # The pattern is meant to expand.
  ls /usr/lib/*/$lib > /dev/null
done

# The sandbox shares the host's network, so that Artemis reaches device
# servers such as OpenRGB on the host's localhost: it sees more interfaces
# than its own loopback device.
if ! awk -F: 'NR > 2 && $1 !~ /^ *lo$/ { found = 1 } END { exit !found }' /proc/net/dev; then
  echo 'The sandbox has no network interface besides lo.' >&2
  exit 1
fi

test -s /app/share/icons/hicolor/256x256/apps/eu.nosini.Artemis.png
# flatpak-builder records the license files it finds at the root of each
# module's source; the main module's must be there.
test -s "/app/share/licenses/$FLATPAK_ID/artemis/LICENSE"

echo 'Installed app checks passed.'
