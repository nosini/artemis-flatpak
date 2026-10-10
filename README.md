# Artemis Flatpak

An unofficial Flatpak package of [Artemis](https://artemis-rgb.com/), which
controls the RGB lighting of keyboards, mice, headsets, LED strips and other
devices from many brands together. You lay out your devices on a surface
that matches your desk, then build profiles from layers of effects that react
to games, audio and other data.

This repository only contains the packaging. Artemis itself, its
[documentation](https://wiki.artemis-rgb.com/) and its
[issue tracker](https://github.com/Artemis-RGB/Artemis/issues) live upstream.

## Installing

Install [Flatpak](https://flatpak.org/setup/) if you don't already have it,
then:

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user https://nosini.github.io/artemis-flatpak/artemis.flatpakref
```

This adds a remote named `artemis`. Updates come through it like any other
Flatpak, from your software center or with:

```sh
flatpak update --user eu.nosini.Artemis
```

The package follows Artemis's published releases, the same ones its built-in
updater would install. It is built for x86_64 only, like upstream's Linux
version.

If an update causes problems, the `artemis` remote still has the five
previous versions. List them and go back to one by its commit:

```sh
flatpak remote-info --user --log artemis eu.nosini.Artemis
flatpak update --user --commit=COMMIT eu.nosini.Artemis
```

`flatpak mask --user eu.nosini.Artemis` then keeps it from updating until
you run `flatpak mask --user --remove eu.nosini.Artemis`.

Artemis is also available from the shared
[nosini remote](https://github.com/nosini/flatpak-repo), together with the
other packages published there.

## Using it

Start Artemis from your application menu, or with:

```sh
flatpak run eu.nosini.Artemis
```

On first start, a setup wizard offers default features from Artemis's
Workshop, including device providers: the plugins that talk to your
hardware. More are in the Workshop later.

### OpenRGB

The usual way to drive devices on Linux is through
[OpenRGB](https://openrgb.org/). Artemis talks to its SDK server, which
can run as a system service or as the OpenRGB app with its SDK server
started. The OpenRGB device provider connects to `127.0.0.1:6742` by
default. That is the host's own localhost, because the Flatpak shares the
host's network. Start the server before Artemis.

Because Artemis gets to the hardware through OpenRGB, the Flatpak needs no
access to USB, HID or I²C devices. OpenRGB's own udev rules and permissions
decide which devices can be controlled.

### Differences from a regular install

- **Updates** come from Flatpak. Artemis's own updater is switched off, and
  **Check now** in its settings says so. Plugins, profiles and layouts from
  the Workshop still update themselves.
- **Data**: settings, profiles, plugins and logs are kept in
  `~/.var/app/eu.nosini.Artemis/data/Artemis` instead of
  `~/.local/share/Artemis`, so they aren't shared with a regular install. To
  take over a regular install's setup, copy its data before the first start:

  ```sh
  mkdir -p ~/.var/app/eu.nosini.Artemis/data
  cp -a ~/.local/share/Artemis ~/.var/app/eu.nosini.Artemis/data/
  ```

- **Keyboard and mouse input** for effects that react to key presses comes
  from `/dev/input`, which the sandbox can't read. Those effects stay idle, as
  they do in a regular install for users without access to input devices.
- **Starting with the desktop**: Artemis has no autostart option on Linux.
  Add `flatpak run eu.nosini.Artemis --minimized` to your desktop's startup
  applications to have it start in the tray.
- **The tray icon** needs a tray, which GNOME only has with an extension
  such as AppIndicator.
- **Window**: Artemis's UI toolkit only supports X11, so on Wayland desktops
  the window runs through Xwayland.

## Permissions

- **Network** (`--share=network`): reaching OpenRGB and other device servers
  on localhost or the local network, downloading plugins and profiles from
  the Workshop, and Artemis's local web API (port 9696), which other programs
  and plugins use.
- **Display** (`--socket=x11`, `--share=ipc`) and **GPU**
  (`--device=dri`): showing and rendering the window.
- **Tray icon** (`--talk-name=org.kde.StatusNotifierWatcher`,
  `--own-name=org.kde.StatusNotifierItem-2-0`): showing the icon that keeps
  Artemis reachable when its window is closed.

Artemis has no access to your files outside its own data folder, and no
direct access to devices. Links and folders it opens go through the desktop's
portals.

## License

The packaging files in this repository are licensed under the GNU Affero
General Public License, version 3 (see [LICENSE](LICENSE)). Artemis itself
is under the
[PolyForm Noncommercial License 1.0.0](https://github.com/Artemis-RGB/Artemis/blob/master/LICENSE),
which allows using and sharing it only for noncommercial purposes.

Building it yourself, publishing, and how the package works are described
in [docs/development.md](docs/development.md).
