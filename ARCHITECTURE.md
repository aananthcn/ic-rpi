# Architecture — ic-rpi

## Two-node platform overview

This repo builds the **Linux Instrument Cluster (IC)** stack — one of two RPi
nodes in the platform. The peer node runs Android 16 AAOS as the Head Unit (HU).

```
 ┌──────────────────────────────────────────────────────┐
 │   Linux IC  (RPi — Raspberry Pi OS)  ← this repo     │
 │                                                      │
 │   /opt/car-ui/bin/vhal-core  ← gRPC :50051           │
 │   /opt/car-ui/bin/vhal-gateway  → pushes to HU       │
 │   /opt/car-ui/bin/cluster-ui  (Qt6/QML)              │
 └────────────────────┬─────────────────────────────────┘
                      │ Ethernet  192.168.10.x
 ┌────────────────────┴─────────────────────────────────┐
 │   Android HU  (RPi — Android 16 AAOS)                │
 │                                                      │
 │   vhal-core-server  ← receives gateway pushes        │
 │   vhal-bridge       ← AIDL IVehicle for CarService   │
 │   CarEvsService     ← owns rear camera on REVERSE    │
 │   rvc-evs-proto     ← H.264 RTP → IC (in progress)   │
 └──────────────────────────────────────────────────────┘
```

See `vendor/brcm/ARCHITECTURE.md` (in the Android repo) for the full
cross-node architecture including the Android HU internals.

---

## Linux IC Component Overview

```
┌─────────────────────────────────────────────────────┐
│                  ic-rpi (this repo)                 │
│                  Integration superbuild             │
│                                                     │
│  src/                                               │
│  ├── SocketCanGW/   ← git submodule                 │
│  │   └── socket-can-gw      (CAN master — gRPC      │
│  │                           client, pushes SetValues  │
│  │                           to vhal-core; starts 1st) │
│  │                                                  │
│  ├── vhal-core/     ← git submodule                 │
│  │   ├── vhal-types         (data model)            │
│  │   ├── vhal-ipc-grpc      (gRPC transport)        │
│  │   ├── vhal-server        (HAL gRPC server)       │
│  │   └── vhal-gateway       (cross-domain forwarder)│
│  │                                                  │
│  └── cluster-ui/    ← git submodule                 │
│      └── cluster-ui          (Qt6/QML UI client)    │
└─────────────────────────────────────────────────────┘
```

## CAN Bus Architecture

### Hardware (RPi target)

The RPi carries a **Waveshare 2-CH CAN FD HAT** (MCP2518FD via SPI), presenting
two CAN FD network interfaces: `can0` and `can1`. These are brought up by
`can-setup.service` at boot (see *RPi Autostart* below).

```
  RPi hardware
  ┌──────────────────────────────────────────┐
  │  Waveshare 2-CH CAN FD HAT (MCP2518FD)   │
  │  SPI0 → can0   (500 kbps / 2 Mbps FD)   │
  │  SPI1 → can1   (500 kbps / 2 Mbps FD)   │
  └────────────────┬─────────────────────────┘
                   │ SocketCAN (kernel netdev)
         /opt/car-ui/bin/socket-can-gw
```

### pc simulation target

On pc, real CAN hardware is absent. `canX`/`vcanX` virtual interfaces are set
up separately by the **AutoNET** project (a pc-side tool). `socket-can-gw` then
runs against those virtual interfaces exactly as it would against real hardware.
No CAN setup is performed by this repo on the pc target.

### Process dependency chain

socket-can-gw is the **CAN master** and starts before vhal-core. Its gRPC
client thread (VhalPusher) connects to vhal-core once vhal-core is ready —
gRPC channels reconnect automatically so no explicit wait loop is needed.

```
  can0 / can1  (kernel interfaces — must exist before stack starts)
       │
       ▼
  socket-can-gw   CAN master: starts first, decodes frames immediately
       │           VhalPusher gRPC client thread: channel created at start,
       │           RPCs succeed once vhal-core is up (auto-reconnect)
       │  1 s ──► vhal-core starts 1 s after socket-can-gw
       ▼
  vhal-core       HAL gRPC server (localhost:50051); receives CAN signals
       │           via SetValues from socket-can-gw
       │  1 s
       ▼
  vhal-gateway    forwards selected properties to Android HU
       │
       ▼
  cluster-ui      Qt6/QML UI — reads vehicle properties from vhal-core via gRPC
```

Startup order: socket-can-gw → vhal-core → vhal-gateway → cluster-ui.
Shutdown is in reverse (systemd cgroup cleanup when cluster-ui exits).

---

## Runtime Architecture

```
  ┌──────────────────────┐
  │   socket-can-gw      │  CAN master: reads can0/can1 (SocketCAN)
  │  (gRPC CLIENT)       │  starts first; VhalPusher calls SetValues
  └──────────┬───────────┘  on vhal-core (auto-reconnects if not yet up)
             │ gRPC SetValues (localhost:50051)
  ┌──────────▼───────────┐        gRPC GetValues / Stream
  │   vhal-core          │ ◄──────────────────────────────────┐
  │  (HAL gRPC server)   │                                    │
  │                      │  Vehicle signal updates            │
  │  Reads:              │  (speed, rpm, fuel, gear, etc.)    │
  │  /opt/car-ui/etc/    │                                    │
  │  vhal/Default        │                         ┌──────────┴──────────────┐
  │  Properties.json     │                         │      cluster-ui         │
  └──────────────────────┘                         │    (Qt6/QML client)     │
                                                   │                         │
  ┌──────────────────────┐   gRPC SetValues        │  VehicleBridge          │
  │  vhal-gateway        │ ──────────────────────► │    ↓ DriveMode::REVERSE │
  │  forwards selected   │   → Android HU          │  RvcStreamHandler       │
  │  properties to HU    │   192.168.10.20:50051   │    ↓ GStreamer pipeline │
  └──────────────────────┘                         │    ↓ QVideoSink frames  │
                                                   │  PipOverlay (QML)       │
  ┌──────────────────────┐   RTP/UDP (port 5004)   │                         │
  │  Android HU          │ ──────────────────────► │  Renders on:            │
  │  rvc-evs-proto       │   H.264, payload 96     │  pc → xcb               │
  │  (target state)      │                         │  rpi → wayland/eglfs    │
  └──────────────────────┘                         └─────────────────────────┘
```

### RVC Stream Path (Reverse Gear)

When the gear changes to `GEAR_REVERSE`, `VehicleBridge` emits `stateChanged` with
`driveMode == DriveMode::REVERSE`. `main.cpp` connects this to `RvcStreamHandler::start()`,
which builds and starts a GStreamer pipeline:

```
udpsrc (port 5004)
  → rtph264depay
  → h264parse
  → avdec_h264          (software; swap for v4l2h264dec for RPi HW decode)
  → videoconvert
  → video/x-raw,format=RGBA
  → appsink             (pulls frames into Qt via QVideoSink)
```

Decoded RGBA frames arrive on GStreamer's internal streaming thread. Each frame is
deep-copied into a `QByteArray`, then marshalled to the Qt main thread via
`QMetaObject::invokeMethod(Qt::QueuedConnection)` before being pushed to
`QVideoSink::setVideoFrame()`. The QML `VideoOutput` in `PipOverlay.qml` renders
the frames in the PiP window. On gear exit from Reverse, `RvcStreamHandler::stop()`
tears down the pipeline.

## Build Architecture

The superbuild uses CMake's `ExternalProject_Add` to build each sub-project in isolation. This avoids CMake target name collisions: `cluster-ui` already pulls in `vhal-core` packages internally via its own `add_subdirectory()` calls.

```
conan install          →  resolves C++ deps (gRPC, jsoncpp, …)
                          outputs conan_toolchain.cmake + Find*.cmake

cmake configure        →  ic-rpi/CMakeLists.txt
  ExternalProject_Add(SocketCanGW)  →  src/SocketCanGW/CMakeLists.txt
  ExternalProject_Add(vhal-core)    →  src/vhal-core/CMakeLists.txt
  ExternalProject_Add(cluster-ui)   →  src/cluster-ui/CMakeLists.txt
                                        (depends on vhal-core)

cmake --build          →  compiles all sub-projects in order

cmake --install        →  stages artifacts into ./build/install/
                          (bin/, lib/, etc/, qml/, assets/)

deploy.sh --target rpi →  stop car-ui.service on RPi
                          rsync ./build/install/ → /opt/car-ui/ (SSH)
                          start car-ui.service on RPi

deploy.sh --target pc  →  sudo rsync ./build/install/ → /opt/car-ui/
```

## Path Design

Two prefixes are intentionally decoupled:

| Prefix | Value | Purpose |
|--------|-------|---------|
| Staging prefix | `./build/install/` | Where `cmake --install` writes outputs. No elevated privileges needed. |
| Runtime prefix | `/opt/car-ui/` | Where `deploy.sh` copies the staging tree. Baked into binaries at compile time (e.g. `VHAL_CONFIG_ROOT`). |

This means `build.sh` is always unprivileged and repeatable, while `deploy.sh` is the single privileged step.

## Dependency Management

| Dependency | How managed |
|------------|-------------|
| gRPC, Protobuf, jsoncpp, abseil, re2, c-ares, zlib, OpenSSL | Conan 2.x (static libs) |
| Qt6 (Core, Quick, QML, Multimedia, MultimediaQuick) | Qt Online Installer — **not** managed by Conan |
| GStreamer (gstreamer-1.0, gstreamer-app-1.0, gstreamer-video-1.0) | System package manager (`apt`); detected via `pkg-config` at CMake configure time |
| SocketCanGW, vhal-core, cluster-ui | Git submodules under `src/` |
| CAN interfaces (rpi) | Waveshare 2-CH CAN FD HAT; kernel driver `mcp251xfd`; brought up by `can-setup.service` |
| CAN interfaces (pc) | Virtual `vcanX` interfaces created by the **AutoNET** project; must be up before running the stack |

Conan dependencies are built as **static libraries**, so the deployed binaries have no external Conan `.so` dependencies at runtime. Qt shared libraries are located via the RPATH baked into the binary at build time (`CMAKE_INSTALL_RPATH_USE_LINK_PATH=ON`).

## RPi Autostart (systemd)

Two systemd unit files live in `config/systemd/` and are installed to the RPi
by `run.sh --target rpi` (always overwritten, so the repo is the source of
truth). They are **not** used on the pc target.

| Unit | Installed path | Purpose |
|------|----------------|---------|
| `can-setup.service` | `/etc/systemd/system/` | Brings up `can0`/`can1` via `ip link`; `RemainAfterExit=yes` |
| `car-ui.service` | `/etc/systemd/system/` | Starts the full stack via `car-ui-start.sh`; `After=can-setup.service` |

`car-ui-start.sh` (sourced from `config/car-ui-start.sh`, installed to
`/opt/car-ui/bin/`) sequences the processes and ends with `exec cluster-ui`.
The `exec` hands PID ownership to `cluster-ui` so systemd tracks it as the
main process and kills the background processes via cgroup cleanup when it exits.

```
boot
 └─ can-setup.service  →  ip link set can0/can1 up (CAN FD)
     └─ car-ui.service  →  /opt/car-ui/bin/car-ui-start.sh
           ├── socket-can-gw  &   → /tmp/socket-can-gw.log
           ├── (sleep 1)
           ├── vhal-core      &   → /tmp/vhal-core.log
           ├── (sleep 1)
           ├── vhal-gateway   &   → /tmp/vhal-gateway.log
           └── exec cluster-ui    ← systemd main PID (eglfs)
```

### Interaction with run.sh and deploy.sh

| Action | Effect on the stack |
|--------|---------------------|
| `run.sh --target rpi` | Installs/overwrites systemd files; stops `car-ui.service`; starts stack interactively via SSH for development |
| `deploy.sh --target rpi` | Stops `car-ui.service`; rsyncs new binaries; restarts `car-ui.service` so new binaries take effect immediately |
| RPi reboot | `can-setup.service` and `car-ui.service` start automatically (both are `enabled`) |

---

## Conan Profile Strategy

The `profiles/rpi` profile is **never committed**. It is regenerated by `scan-rpi-profile.sh` each time by SSHing into the live RPi and querying the installed library versions. This ensures the build always matches what is actually on the device, even as Raspbian packages are updated.

The `profiles/pc` profile is committed since the Ubuntu dev environment is stable and version-controlled.

---

## RVC Camera Migration Context

The IC's GStreamer RTP receiver (`RvcStreamHandler`) is intentionally
transport-agnostic — it opens UDP port 5004 and expects H.264/RTP regardless
of which Android-side component sends it. The migration from `rvc-app`
(Camera2 NDK) to `rvc-evs-proto` (EVS HAL) on the Android HU is transparent
to this side: same IP, same port, same codec.

```
Android HU camera pipeline migration:

  OLD: rvc-service → vendor.rvc.camera.active → rvc-app (Camera2 NDK) → RTP
  NEW: CarEvsService (auto) → rvc-evs-proto (CarEvsManager) → RTP

  Linux IC RvcStreamHandler: unchanged in both cases
```

See `vendor/brcm/ARCHITECTURE.md` in the Android repo for the HU-side details.
