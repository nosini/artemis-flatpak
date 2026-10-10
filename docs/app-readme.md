# Example Flatpak

An unofficial Flatpak package of [Example](https://github.com/example/example),
which does one useful thing well. Say in a sentence or two what the app does
for its users.

This repository only contains the packaging. The app itself, its
documentation and its issue tracker live upstream.

## Installing

Install [Flatpak](https://flatpak.org/setup/) if you don't already have it,
then:

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user https://nosini.github.io/example-flatpak/example.flatpakref
```

This adds a remote named `example`. Updates come through it like any other
Flatpak, from your software center or with:

```sh
flatpak update --user eu.nosini.Example
```

If an update causes problems, the `example` remote still has the five
previous versions. List them and go back to one by its commit:

```sh
flatpak remote-info --user --log example eu.nosini.Example
flatpak update --user --commit=COMMIT eu.nosini.Example
```

`flatpak mask --user eu.nosini.Example` then keeps it from updating until
you run `flatpak mask --user --remove eu.nosini.Example`.

Example is also available from the shared
[nosini remote](https://github.com/nosini/flatpak-repo), together with the
other packages published there.

## Using it

Start Example from your application menu, or with:

```sh
flatpak run eu.nosini.Example
```

Describe a simple first use here, and link to the upstream documentation
for everything else.

### Differences from a regular install

List what behaves differently inside the sandbox, where the app keeps its
settings and data, and whether they are shared with a regular install.

## Permissions

Explain in plain words each permission the manifest grants and what the
app uses it for, and what it has no access to.

## License

The packaging files in this repository are licensed under the GNU Affero
General Public License, version 3 (see [LICENSE](LICENSE)). Example itself is
under the MIT license; see its
[repository](https://github.com/example/example).

Building it yourself, publishing, and how the package works are described
in [docs/development.md](docs/development.md).
