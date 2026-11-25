# MicSource Flatpak — Build and Submission Notes

## Building locally

```bash
flatpak-builder --user --install --force-clean builddir flatpak/io.github.mhasanmuammar.MicSource.yml
flatpak run io.github.mhasanmuammar.MicSource
```

## Creating a bundle for distribution

```bash
flatpak-builder --repo=repo --force-clean builddir flatpak/io.github.mhasanmuammar.MicSource.yml
flatpak build-bundle repo micsource.flatpak io.github.mhasanmuammar.MicSource
```

## Flathub submission

See `linux-install/docs/superpowers/specs/2026-11-25-flatpak-bundle-design.md`
for the full spec, permissions rationale, and checklist.

## USB prerequisite

Flatpak's `--device=usb` exposes `/dev/bus/usb` but does not grant the user
permission to open the nodes. Standard desktop udev `uaccess` rules apply
(usually installed by default). If `adb devices` reports `no permissions`,
install the standard Android udev rules, not a Flatpak permission change.
