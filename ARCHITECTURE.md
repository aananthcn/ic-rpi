# Architecture — ic-rpi5

## Two-node platform overview

This repo builds the **Linux Instrument Cluster (IC)** stack — one of two RPi5
nodes in the platform. The peer node runs Android 16 AAOS as the Head Unit (HU).

```
 ┌──────────────────────────────────────────────────────┐
 │   Linux IC  (RPi5 — Raspberry Pi OS)  ← this repo   │
 │                                                      │
 │   /opt/car-ui/bin/vhal-core  ← gRPC :50051           │
 │   /opt/car-ui/bin/vhal-gateway  → pushes to HU       │
 │   /opt/car-ui/bin/cluster-ui  (Qt6/QML)              │
 └────────────────────┬─────────────────────────────────┘
                      │ Ethernet  192.168.10.x
 ┌────────────────────┴─────────────────────────────────┐
 │   Android HU  (RPi5 — Android 16 AAOS)               │
 │                                                      │
 │   vhal-core-server  ← receives gateway pushes        │
 │   vhal-bridge       ← AIDL IVehicle for CarService   │
 │   CarEvsService     ← owns rear camera on REVERSE    │
 │   rvc-evs-proto     ← H.264 RTP → IC (in progress)  │
 └──────────────────────────────────────────────────────┘
```

See `vendor/brcm/ARCHITECTURE.md` (in the Android repo) for the full
cross-node architecture including the Android HU internals.

---

## Linux IC Component Overview

```
┌─────────────────────────────────────────────────────┐
│                  ic-rpi5 (this repo)                │
│                  Integration superbuild             │
│                                                     │
│  src/                                               │
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

## Runtime Architecture

```
  ┌──────────────────────┐        gRPC (localhost:50051)
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
  │  properties to HU    │   192.168.10.20:50051   │    ↓ GStreamer pipeline  │
  └──────────────────────┘                         │    ↓ QVideoSink frames  │
                                                   │  PipOverlay (QML)       │
  ┌──────────────────────┐   RTP/UDP (port 5004)   │                         │
  │  Android HU          │ ──────────────────────► │  Renders on:            │
  │  rvc-evs-proto       │   H.264, payload 96     │  host → xcb             │
  │  (target state)      │                         │  rpi5 → wayland/eglfs   │
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
  → avdec_h264          (software; swap for v4l2h264dec for RPi5 HW decode)
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

cmake configure        →  ic-rpi5/CMakeLists.txt
  ExternalProject_Add(vhal-core)   →  src/vhal-core/CMakeLists.txt
  ExternalProject_Add(cluster-ui)  →  src/cluster-ui/CMakeLists.txt
                                      (depends on vhal-core)

cmake --build          →  compiles both sub-projects in order

cmake --install        →  stages artifacts into ./build/install/
                          (bin/, lib/, etc/, qml/, assets/)

deploy.sh              →  rsync ./build/install/ → /opt/car-ui/
                          (sudo on host, SSH on rpi5)
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
| vhal-core, cluster-ui | Git submodules under `src/` |

Conan dependencies are built as **static libraries**, so the deployed binaries have no external Conan `.so` dependencies at runtime. Qt shared libraries are located via the RPATH baked into the binary at build time (`CMAKE_INSTALL_RPATH_USE_LINK_PATH=ON`).

## Conan Profile Strategy

The `profiles/rpi5` profile is **never committed**. It is regenerated by `scan-rpi5-profile.sh` each time by SSHing into the live RPi5 and querying the installed library versions. This ensures the build always matches what is actually on the device, even as Raspbian packages are updated.

The `profiles/host` profile is committed since the Ubuntu dev environment is stable and version-controlled.

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
