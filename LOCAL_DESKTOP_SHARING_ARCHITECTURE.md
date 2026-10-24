# Universal Local Remote Desktop Architecture
### High-Performance Any-to-Any Screen Sharing (Offline / LAN / Hotspot)

---

## 1. Executive Summary & Vision

The objective is to build an ultra-low latency, high-framerate screen sharing and remote control application connecting **macOS, Windows, Linux, and Android** across a shared local network (Wi-Fi router or mobile hotspot) **with zero internet connectivity required**.

```
+-------------------------------------------------------------------------+
|                  ANY-TO-ANY LOCAL SCREEN SHARING                       |
|                                                                         |
|      [ macOS ] <====================> [ Windows ]                      |
|          ^  \                              /  ^                         |
|          |   \                            /   |                         |
|          |    \                          /    |                         |
|          v     v                        v     v                         |
|      [ Linux ] <====================> [ Android ]                      |
|                                                                         |
|               (Local Subnet Only -- Zero Cloud Relay)                   |
+-------------------------------------------------------------------------+
```

### Key Performance Targets
- **Framerate**: 60 FPS minimum, 120 FPS capable on supported displays.
- **Glass-to-Glass Latency**: Under 25ms over 5 GHz Wi-Fi / hotspot.
- **CPU & Memory Overhead**: < 5% CPU usage via hardware-accelerated video pipelines.
- **Network Dependency**: Pure LAN / subnet communication; works on offline mobile hotspots.

---

## 2. Framework & Tech Stack Evaluation

### Why Electron Fails for This Use Case
- **IPC Overhead**: Frame buffers must be copied across process boundaries (Main <-> Renderer).
- **Latency Jitter**: Garbage collection pauses cause frame drops and micro-stutters (+40ms to 100ms added latency).
- **GPU Inefficiencies**: Direct zero-copy hardware capture (DXGI, ScreenCaptureKit) cannot easily stream directly to the web canvas without native C++/Rust addons anyway.

### Comparison Table

| Criteria | Electron | Pure C++ | Rust Core + Native/Flutter UI |
| :--- | :--- | :--- | :--- |
| **Glass-to-Glass Latency** | ❌ 60–120ms (Poor) | ✅ 10–25ms (Top Tier) | ✅ 10–25ms (Top Tier) |
| **Memory Footprint** | ❌ 300MB–800MB | ✅ 20MB–50MB | ✅ 25MB–60MB |
| **Code Reuse** | High (HTML/JS) | Moderate (Platform glue) | High (Shared Rust core) |
| **Concurrency & Safety** | Node.js Single-Threaded | Manual / Error-prone | Memory safe / Fearless async |
| **Build Complexity** | Simple | Complex CMake across 4 OSs | Modern Cargo + FFI tooling |

### Recommended Architecture: **Shared Rust Engine + Native/Flutter UI**

Do not write 4 separate networking, encryption, discovery, and protocol stacks. Split the system into two clean layers:

1. **Shared Core Engine (`libradiant` / `core`) in Rust**:
   - Device discovery (mDNS / Zeroconf).
   - Session negotiation & encryption (ChaCha20-Poly1305 / TLS).
   - Local UDP / WebRTC peer-to-peer transport.
   - Audio/Video packetization and jitter buffer.
   - Remote input event serialization.

2. **Frontend UI Options**:
   - **Option A (Fastest UI iteration across all 4 OSs)**: **Flutter + Rust** (via `flutter_rust_bridge`). Flutter renders at native display refresh rates (60–120Hz) on Windows, macOS, Linux, and Android from a single UI codebase, while delegating raw video decoding to native GPU textures.
   - **Option B (Maximum Native Integration)**:
     - **macOS**: Swift / SwiftUI (invoking Rust core, using `ScreenCaptureKit` + `Metal`).
     - **Windows / Linux**: Rust with a lightweight GUI framework like **Slint** or **Tauri v2** with native DirectX/Vulkan HWND surfaces.
     - **Android**: Kotlin / Jetpack Compose with Rust FFI via JNI.

---

## 3. End-to-End Pipeline Architecture

```
[ HOST DEVICE (Sender) ]
  1. Capture Screen (GPU Buffer)
       │
       ▼
  2. Hardware Video Encoder (NVENC / VideoToolbox / VA-API / MediaCodec)
       │
       ▼
  3. Packetizer & Forward Error Correction (FEC)
       │
       ▼
  4. UDP / Local WebRTC Sender
       │
       │  (Offline LAN / Hotspot - Sub-5ms Packet Transfer)
       ▼
[ CLIENT DEVICE (Receiver) ]
  5. UDP Receiver & Jitter Buffer
       │
       ▼
  6. Hardware Video Decoder (DirectX / Metal / Vulkan / MediaCodec)
       │
       ▼
  7. Render Surface (Zero-Copy GPU Texture Display)
       │
       ▼
  8. Capture Local Mouse/Keyboard/Touch ──[Sub-5ms UDP]──> Inject on Host
```

---

## 4. Platform-Specific Component Breakdown

### A. Zero-Configuration Local Discovery (No Cloud)
When two devices are on the same Wi-Fi network or hotspot:
- **Discovery Protocol**: **mDNS (Multicast DNS / Bonjour)** on port `5353` or local UDP broadcast.
- **Service Type**: `_screencast._udp.local.`
- **Metadata Broadcast**: Device Name, OS, Host/Client capabilities, Public Key.
- **Pairing & Security**: 
  - One-time 6-digit PIN or QR code prompt.
  - Ephemeral key exchange via `X25519` + `ChaCha20-Poly1305` authenticated encryption.
  - Zero reliance on external STUN/TURN servers or cloud accounts.

### B. Screen Capture (Zero-Copy GPU APIs)
Capturing screens frame-by-frame must bypass CPU RAM copying:

| Operating System | API | Mechanism |
| :--- | :--- | :--- |
| **macOS** | `ScreenCaptureKit` (macOS 12.3+) | Captures display frames directly into `CVPixelBuffer` in unified GPU memory. |
| **Windows** | `DXGI Desktop Duplication API` or `Windows.Graphics.Capture` | Direct3D 11/12 surface capture directly in VRAM. |
| **Linux** | `PipeWire` + `xdg-desktop-portal` (Wayland) / `XShm` (X11) | Direct DMA-BUF sharing between Wayland compositor and encoder. |
| **Android** | `MediaProjection` API | Direct virtual display projection into `MediaCodec` input `Surface`. |

### C. Hardware Video Encoding & Decoding

- **Target Codecs**:
  - **H.264 (AVC)**: Universal compatibility, lowest decode latency on older hardware.
  - **HEVC (H.265)**: 30–40% bandwidth reduction over Wi-Fi, ideal for 2K/4K streams.
  - **AV1**: Ultra-efficient for high-end modern devices.
- **Encoders (Host)**:
  - macOS: Apple `VideoToolbox` (Apple Silicon hardware blocks).
  - Windows: NVIDIA `NVENC`, AMD `AMF`, Intel `QuickSync (QSV)`.
  - Linux: `VA-API` or `NVENC`.
  - Android: `MediaCodec` hardware encoder.
- **Decoders (Client)**:
  - Hardware decoding directly to GPU textures (`Metal` on macOS, `Direct3D 11/12` on Windows, `Vulkan`/`EGL` on Linux, `SurfaceView` on Android).

### D. Network Transport (Why UDP is Mandatory)

- **The Problem with TCP**: If a single video packet is lost on Wi-Fi, TCP stops the entire stream until the missing packet is retransmitted (Head-of-Line Blocking). This causes freezes and latency spikes.
- **The Solution (UDP)**:
  - **Local WebRTC**: Uses local IP ICE candidates without external STUN/TURN servers. Built-in congestion control, bandwidth estimation, and packet loss recovery.
  - **Custom UDP (RTP + FEC)**: Like Sunshine/Moonlight. Send Forward Error Correction (Reed-Solomon FEC) packets alongside video chunks to recover from 2–5% Wi-Fi packet loss instantly without retransmissions.

### E. Remote Input Simulation (Keyboard, Mouse, Touch)

Client mouse and keyboard interactions are captured and sent over a sub-millisecond UDP channel:

| Target Host OS | Input Simulation API | Permissions Required |
| :--- | :--- | :--- |
| **macOS** | `CGEventPost` / `CoreGraphics` | Accessibility & Screen Recording Permissions |
| **Windows** | `SendInput` (Win32 API) | Standard / Elevated if controlling admin windows |
| **Linux** | `uinput` kernel module or `libei` (Wayland emulation) | `/dev/uinput` read/write access |
| **Android** | `AccessibilityService` or `app_process` / `Shizuku` / `ADB` daemon | Accessibility or ADB permissions |

---

## 5. Recommended Repository Structure

```
mimic-crossplatform/
├── core/                         # Shared Rust Engine
│   ├── Cargo.toml
│   ├── src/
│   │   ├── discovery/            # mDNS / Bonjour Zeroconf
│   │   ├── protocol/             # Message headers, packetization, crypto
│   │   ├── transport/            # UDP / WebRTC local socket manager
│   │   ├── input/                # Input serialization & event handling
│   │   └── ffi/                  # C-ABI bindings for Swift, Kotlin, Dart
├── platforms/
│   ├── macos/                    # Swift / ScreenCaptureKit / VideoToolbox
│   ├── windows/                  # DXGI Capture / NVENC / Windows input
│   ├── linux/                    # PipeWire / DMA-BUF / uinput
│   └── android/                  # MediaProjection / MediaCodec / Kotlin UI
└── ui/                           # Optional: Unified Flutter frontend
```

---

## 6. Implementation Milestones

### Phase 1: Local Discovery & Ping
- Implement mDNS announcer and listener in Rust (`mdns-sd` crate).
- Validate that macOS, Windows, Linux, and Android instantly discover each other on the same hotspot.

### Phase 2: Host Video Capture & UDP Stream
- macOS: Capture display via `ScreenCaptureKit` and encode via `VideoToolbox`.
- Windows: Capture display via `DXGI` and encode via `NVENC` / `D3D11`.
- Stream raw H.264 NAL units over local UDP to a receiving client test window.

### Phase 3: Hardware Decoding & GPU Display
- Render decoded video frames directly into native GPU surfaces (Metal / Direct3D / Vulkan).
- Achieve sub-25ms glass-to-glass latency at 1080p 60 FPS.

### Phase 4: Bi-Directional Input & Controls
- Transmit mouse delta coordinates, clicks, scroll, and keyboard events from client to host.
- Inject input events on the host OS.

### Phase 5: Android Integration
- Build Android client receiver using `SurfaceView` and `MediaCodec`.
- Build Android host sender using `MediaProjection`.

---

## 7. Open-Source Projects to Study
- **[Sunshine](https://github.com/LizardByte/Sunshine)** (C++): Industry gold standard for low-latency host streaming across macOS, Windows, and Linux.
- **[Moonlight](https://github.com/moonlight-stream)**: Highly optimized client implementations for all platforms.
- **[RustDesk](https://github.com/rustdesk/rustdesk)** (Rust + Flutter): Open-source remote desktop architecture showing cross-platform FFI and capture integration.
- **[Scrcpy](https://github.com/Genymobile/scrcpy)** (C): Zero-latency Android screen mirroring.
