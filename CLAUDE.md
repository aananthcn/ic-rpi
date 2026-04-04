# ic-rpi5 — Instrument Cluster on Raspberry Pi 5

## Project Overview

**ic** = Instrument Cluster  
**rpi5** = Raspberry Pi 5 (running Raspberry Pi OS / Raspbian)

This is an integration project that assembles the instrument cluster UI stack on a Raspberry Pi 5. It ties together sub-projects, manages cross-environment builds via Conan, and handles the reality that the target OS and library versions (glibc, Qt, etc.) will drift over time.

---

## Sub-projects

These are managed as git submodules under this repo:

| Sub-project    | Repository                                      | Purpose                          |
|----------------|-------------------------------------------------|----------------------------------|
| `vhal-core`    | https://github.com/aananthcn/vhal-core.git      | Vehicle HAL core library         |
| `cluster-ui`   | https://github.com/aananthcn/cluster-ui.git     | Instrument cluster UI application|

The setup script is responsible for cloning these as submodules and keeping them registered.

---

## Build Targets

### Deploy Root (both targets)

All build artifacts for both `host` and `rpi5` are installed under **`/opt/car-ui`**:

| Artifact type | Install path        |
|---------------|---------------------|
| Binaries      | `/opt/car-ui/bin`   |
| Libraries     | `/opt/car-ui/lib`   |
| Config files  | `/opt/car-ui/etc`   |

### Target: Raspberry Pi 5 (`rpi5`)
- Cross-compiled (or built on-device) for Raspberry Pi OS (Raspbian)
- Conan profile is generated dynamically by scanning the live RPi5 (see Profile Script below)
- Artifacts are deployed to `/opt/car-ui` on the RPi5 via SSH/rsync

### Target: Host (`host`)
- Built for Ubuntu Linux PC for local development and testing
- Artifacts are installed to `/opt/car-ui` on the host machine
- This keeps host and target paths identical, simplifying config and testing

---

## Default Raspberry Pi 5 Connection Parameters

| Parameter | Default Value    |
|-----------|------------------|
| IP address | `192.168.10.10` |
| Username   | `$USER` (host username, assumed same on RPi5) |
| SSH port   | `22`             |

The user is expected to have `openssh-server` running on the RPi5. Scripts will check for this and guide the user if it is missing.

---

## Scripts

### 1. `scripts/scan-rpi5-profile.sh` — Profile Generator

**Purpose**: SSH into the RPi5, detect installed library versions, and generate a Conan cross-compilation profile.

**What it does**:
- Connects to RPi5 at `192.168.10.10` (or overridden via `RPI5_IP` env var) using `$USER`
- Checks that prerequisites are installed on RPi5 (openssh-server, Qt, glibc, etc.)
- If prerequisites are missing, prints instructions to help the user install them
- Detects versions of: glibc, Qt (qmake/qt-cmake), GCC/G++, Python, pkg-config
- Generates a Conan profile at `profiles/rpi5` tailored to the detected environment

**Usage**:
```bash
./scripts/scan-rpi5-profile.sh [RPI5_IP=192.168.10.10]
```

### 2. `scripts/setup.sh` — Project Setup

**Purpose**: Initialize the full project from scratch on a fresh clone.

**What it does**:
- Registers and clones `vhal-core` and `cluster-ui` as git submodules
- Installs Conan if not present
- Installs host build dependencies (checked, not silently assumed)
- Calls `scan-rpi5-profile.sh` to generate the RPi5 Conan profile
- Creates a host Conan profile (`profiles/host`) for Ubuntu PC builds

**Usage**:
```bash
./scripts/setup.sh
```

### 3. `scripts/build.sh` — Build Script

**Purpose**: Build for either target and stage outputs under `./build/install/`. Does **not** write to `/opt/car-ui` — that is done by `deploy.sh`.

**Usage**:
```bash
./scripts/build.sh --target rpi5    # Build for Raspberry Pi 5
./scripts/build.sh --target host    # Build for Ubuntu Linux host
```

**What it does**:
1. `conan install` — resolves and downloads Conan dependencies into `./build/`
2. `cmake configure` — configures with `CMAKE_INSTALL_PREFIX=./build/install`
3. `cmake build` — compiles everything, outputs stay in `./build/`
4. `cmake --install` — stages artifacts into `./build/install/{bin,lib,etc,...}`

**Behavior differences by target**:

| Aspect              | `host`                          | `rpi5`                          |
|---------------------|---------------------------------|---------------------------------|
| Conan profile       | `profiles/host`                 | `profiles/rpi5`                 |
| Staging dir         | `./build/install/`              | `./build/install/`              |
| Runtime prefix*     | `/opt/car-ui`                   | `/opt/car-ui`                   |
| Deploy step         | `deploy.sh --target host`       | `deploy.sh --target rpi5`       |

*Runtime prefix is baked into binaries at compile time (e.g. `VHAL_CONFIG_ROOT`). It is always `/opt/car-ui` regardless of where the staging tree lives.

### 4. `scripts/deploy.sh` — Deploy Script

**Purpose**: Copy the staged `./build/install/` tree to `/opt/car-ui` on the host or RPi5.

**Usage**:
```bash
./scripts/deploy.sh --target host             # deploy to local /opt/car-ui (asks for sudo)
./scripts/deploy.sh --target rpi5             # deploy to RPi5 via rsync+SSH
./scripts/deploy.sh --target rpi5 --rpi5-ip 192.168.10.10
```

**What it does**:
- Verifies `./build/install/` is non-empty (fails loudly if build.sh was not run first)
- Shows the list of files to be deployed and asks for confirmation before proceeding
- **host**: `sudo rsync -av ./build/install/ /opt/car-ui/` — creates `/opt/car-ui` subdirs if missing
- **rpi5**: SSHes into the RPi5 to create `/opt/car-ui` subdirs (with sudo on the device), then `rsync`s the staging tree over SSH

### 5. `scripts/run.sh` — Run Script

**Purpose**: Start the full instrument cluster stack (`vhal-core` + `cluster-ui`) on the host or RPi5. Handles startup order, `QT_QPA_PLATFORM`, and clean shutdown on Ctrl-C.

**Usage**:
```bash
./scripts/run.sh --target host                          # run locally
./scripts/run.sh --target rpi5                          # run on RPi5 via SSH
./scripts/run.sh --target rpi5 --qt-platform eglfs     # bare-metal fullscreen
```

**What it does**:
- Starts `vhal-core` first (gRPC server), waits 1 s for it to bind
- Starts `cluster-ui` (Qt app) with the appropriate `QT_QPA_PLATFORM`
- **host**: both processes run locally; Ctrl-C kills both
- **rpi5**: `vhal-core` runs in the background on the device (log: `/tmp/vhal-core.log`), `cluster-ui` runs in the foreground via an interactive SSH session; Ctrl-C or cluster-ui exit kills `vhal-core` on the device

**No environment variables need to be exported before running** — the script sets `QT_QPA_PLATFORM` itself, and library paths are handled by the RPATH baked into the binaries at build time.

---

## Conan Integration

- Build system: **Conan 2.x**
- Profiles live in `profiles/` at the project root
- The `rpi5` profile is **not committed** — it is regenerated each time via `scan-rpi5-profile.sh` because target library versions may change
- The `host` profile can be committed as it reflects a stable Ubuntu dev environment

---

## Key Decisions

1. **Dynamic profile generation**: Because Raspbian versions and Qt/glibc versions vary across setups and over time, we never hardcode target library versions. The profile is always derived from the live RPi5.

2. **Git submodules over monorepo copy**: `vhal-core` and `cluster-ui` remain independent repositories. They are integrated here as submodules so upstream changes can be pulled cleanly.

3. **Unified runtime prefix `/opt/car-ui`**: Both host and RPi5 builds deploy to the same path structure (`/opt/car-ui/{bin,lib,etc}`). This eliminates path-conditional logic in the application and makes host testing a faithful replica of the target environment.

4. **Build outputs stay in `./build/`**: `build.sh` stages artifacts into `./build/install/` — it never writes to `/opt/car-ui`. A separate `deploy.sh` handles the privileged copy, keeping the build step unprivileged and repeatable.

5. **Staging prefix vs runtime prefix**: `CMAKE_INSTALL_PREFIX` (the staging dir `./build/install/`) is decoupled from `CAR_UI_RUNTIME_PREFIX` (`/opt/car-ui`). Runtime paths baked into binaries at compile time (e.g. `VHAL_CONFIG_ROOT`) always point at `/opt/car-ui`, not at the staging tree.

6. **No system path pollution**: Nothing is installed to `/usr`, `/etc`, or other FHS system directories. The entire deployed stack lives under `/opt/car-ui`.

5. **Fail loudly on missing dependencies**: Scripts check for required tools and libraries before proceeding and print actionable instructions if something is missing — they do not silently skip or work around missing prerequisites.
