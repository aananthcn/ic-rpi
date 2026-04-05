# ic-rpi5 — Instrument Cluster on Raspberry Pi 5

An integration project that assembles the instrument cluster UI stack on a Raspberry Pi 5 running Raspberry Pi OS (Raspbian). It uses Conan 2.x as the build system and automatically adapts to the library versions (glibc, Qt, etc.) present on the target device at the time of build.

---

## Repository Structure

```
ic-rpi5/
├── src/
│   ├── vhal-core/      # Submodule: Vehicle HAL core library
│   └── cluster-ui/     # Submodule: Instrument cluster UI application
├── profiles/
│   ├── host            # Conan profile for Ubuntu host (auto-generated)
│   └── rpi5            # Conan profile for RPi5 (auto-generated, not committed)
├── scripts/
│   ├── setup.sh        # One-time project initialisation
│   ├── scan-rpi5-profile.sh  # SSH into RPi5 and generate its Conan profile
│   ├── build.sh        # Build for host or rpi5 target
│   ├── deploy.sh       # Copy staged outputs to /opt/car-ui
│   └── run.sh          # Start vhal-core + cluster-ui (handles startup order)
├── ARCHITECTURE.md     # Component diagram and design decisions
└── CLAUDE.md           # Project goals and AI assistant context
```

---

## Sub-projects

| Sub-project  | Purpose                           |
|--------------|-----------------------------------|
| `vhal-core`  | Vehicle HAL core library          |
| `cluster-ui` | Instrument cluster UI application |

Both are managed as git submodules. `setup.sh` registers and clones them automatically.

---

## Build Targets

| Target | Description                                      |
|--------|--------------------------------------------------|
| `host` | Ubuntu Linux PC — for local development/testing  |
| `rpi5` | Raspberry Pi 5 running Raspberry Pi OS           |

### Install Layout (identical for both targets)

All artifacts are installed under `/opt/car-ui`:

| Type      | Path              |
|-----------|-------------------|
| Binaries  | `/opt/car-ui/bin` |
| Libraries | `/opt/car-ui/lib` |
| Configs   | `/opt/car-ui/etc` |

---

## Prerequisites

### Host machine (Ubuntu)

The following are checked and installed automatically by `setup.sh`:

- `git`, `cmake`, `ninja-build`
- `gcc`, `g++`
- `python3`, `python3-pip`, `python3-venv`
- `pkg-config`, `openssh-client`, `rsync`
- **Conan 2.x** (installed via pip if missing)

Qt6 is **not** managed by Conan — install it using the [Qt Online Installer](https://www.qt.io/download-qt-installer).

**For host (x86) builds — Qt 6.11.0:**
- In the installer select **Qt 6.11.0 → Desktop gcc 64-bit**
- Default install path: `~/Qt/6.11.0/gcc_64`

**For RPi5 cross-compilation — Qt 6.8.3:**
- In the installer select **Qt 6.8.3 → Desktop gcc 64-bit** (host tools — always required)
- Also select **Qt 6.8.3 → Raspberry Pi** (aarch64 target libraries)
- Default install path: `~/Qt/6.8.3/gcc_64`

`build.sh` auto-detects Qt via `qmake6` on `PATH` or by scanning common Qt installer paths.
If detection fails, pass the Qt lib directory explicitly:

```bash
./scripts/build.sh --target host  --qt-prefix ~/Qt/6.11.0/gcc_64
./scripts/build.sh --target rpi5  --qt-prefix ~/Qt/6.8.3/gcc_64
```

### Raspberry Pi 5

On the RPi5, install the following before running the profile scan:

```bash
sudo apt-get update
sudo apt-get install -y openssh-server build-essential cmake pkg-config
sudo systemctl enable --now ssh
```

The default connection parameters expected by the scripts:

| Parameter  | Default           |
|------------|-------------------|
| IP address | `192.168.10.10`   |
| Username   | `$USER` (from host) |
| SSH port   | `22`              |

Override the IP at any time by setting `RPI5_IP` in your environment.

---

## Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/aananthcn/ic-rpi5.git
cd ic-rpi5
```

### 2. Run setup

`setup.sh` performs all one-time initialisation steps in order:

1. Installs missing host build dependencies via `apt`
2. Clones `vhal-core` and `cluster-ui` as git submodules
3. Installs or upgrades Conan to 2.x
4. Generates the `profiles/host` Conan profile
5. SSHes into the RPi5 to scan library versions and generate `profiles/rpi5`

```bash
./scripts/setup.sh
```

> If the RPi5 is not yet reachable, setup completes without the rpi5 profile.
> Run `./scripts/scan-rpi5-profile.sh` separately once the device is on the network.

### 3. Build

Compiles everything and stages outputs under `./build/install/`. No elevated privileges required.

```bash
# Build for the Ubuntu host
./scripts/build.sh --target host

# Build for Raspberry Pi 5
./scripts/build.sh --target rpi5
```

Staged layout after a successful build:

```
build/install/
├── bin/        # vhal-core and cluster-ui executables
├── lib/        # static libraries
├── etc/        # runtime config files (e.g. vhal/DefaultProperties.json)
├── qml/        # QML UI files
└── assets/     # fonts and SVG icons
```

### 4. Deploy

Copies the staged `./build/install/` tree to `/opt/car-ui`. This step requires elevated privileges.

```bash
# Deploy to the local Ubuntu host (will prompt for sudo)
./scripts/deploy.sh --target host

# Deploy to the Raspberry Pi 5 over SSH
./scripts/deploy.sh --target rpi5

# Deploy to RPi5 at a non-default IP
./scripts/deploy.sh --target rpi5 --rpi5-ip 192.168.10.20
```

Both commands show the files to be deployed and ask for confirmation before proceeding.

### 5. Run

`run.sh` starts `vhal-core` (gRPC server) first, waits for it to bind, then starts `cluster-ui`. Ctrl-C stops both processes cleanly.

```bash
# Run on the Ubuntu host
./scripts/run.sh --target host

# Run on the Raspberry Pi 5
./scripts/run.sh --target rpi5

# Override the display platform (default: xcb for host, wayland for rpi5)
./scripts/run.sh --target rpi5 --qt-platform eglfs
```

No `PATH`, `LD_LIBRARY_PATH`, or `QT_*` exports are needed before running the script:

- Conan dependencies (gRPC, Protobuf, etc.) are compiled as static libraries — no extra `.so` lookup at runtime.
- Qt shared libraries are located via the RPATH baked into the binary at build time (`CMAKE_INSTALL_RPATH_USE_LINK_PATH=ON`). On the RPi5, Qt is system-installed and already on the `ldconfig` search path.
- `QT_QPA_PLATFORM` is set by the script itself based on the target (xcb for host, wayland for rpi5). Override with `--qt-platform` if needed.

On the RPi5, `vhal-core` output is redirected to `/tmp/vhal-core.log` on the device. To tail it while the stack is running:

```bash
ssh pi@192.168.10.10 tail -f /tmp/vhal-core.log
```

---

### 6. Re-scan RPi5 after OS or library updates

If the Raspbian OS or any library on the RPi5 is updated, regenerate the Conan profile and rebuild before the next deployment:

```bash
./scripts/scan-rpi5-profile.sh
./scripts/build.sh --target rpi5
./scripts/deploy.sh --target rpi5
```

---

## Environment Variables

| Variable  | Default          | Description                        |
|-----------|------------------|------------------------------------|
| `RPI5_IP` | `192.168.10.10`  | IP address of the Raspberry Pi 5   |
| `USER`    | current user     | SSH username used to connect to RPi5 |
