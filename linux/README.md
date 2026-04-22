# Jellify — Linux

Native GTK4 + libadwaita Jellyfin music player. Consumes the shared `../core`
crate in-process (no FFI on Linux).

## Build requirements

Target stack is GNOME 46 / libadwaita 1.5. Audio playback, MPRIS2, notifications,
and individual screens land in follow-up batches; this crate currently produces
just the application shell.

### Fedora 40+

```sh
sudo dnf install \
  gtk4-devel libadwaita-devel \
  gstreamer1-devel gstreamer1-plugins-base-devel \
  libsecret-devel \
  pkgconf-pkg-config
```

### Ubuntu 24.04+ / Debian trixie+

```sh
sudo apt install \
  libgtk-4-dev libadwaita-1-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  libsecret-1-dev \
  pkg-config
```

(`libgstreamer*` is not strictly required by this bootstrap batch but will be
needed as soon as the GStreamer playback engine lands — installing now avoids
revisiting.)

### Rust toolchain

```sh
rustup toolchain install stable
```

The MSRV is pinned via the workspace `rust-version` field.

## Build

From the repo root:

```sh
cargo build -p jellify-desktop
```

Or from this directory:

```sh
cd linux && cargo build
```

Running `cargo check` (no link step) is useful on machines without the GTK dev
packages installed — it validates the Rust sources against published crate
metadata without requiring `pkg-config` to resolve native libraries.

## Run

```sh
cargo run -p jellify-desktop
```

Launching a second instance is a no-op — primary-instance registration routes
subsequent invocations to the first process, which raises its existing window.
