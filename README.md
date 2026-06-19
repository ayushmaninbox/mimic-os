# iDroid

> Control your Android phone from your Mac — mirror the screen, run it with the screen off, transfer files, and automate taps. **No app to install on the phone.**

iDroid is an open-source, native **SwiftUI** Mac app that wraps the two best open-source Android tools — [`adb`](https://developer.android.com/tools/adb) and [`scrcpy`](https://github.com/Genymobile/scrcpy) — in a friendly GUI.

## Features (Phase 1)

- 🪞 **Mirror & control** your phone's screen with mouse and keyboard
- 🌙 **Screen-off control** — the phone looks asleep (black screen) while you fully control it from the Mac
- 📂 **File transfer & APK install** via drag-or-pick
- 🤖 **Quick controls / automation** — Home, Back, Power, and scriptable taps/swipes/text
- 📶 **USB *and* wireless** (same Wi-Fi) connections
- 🔔 **Notification snapshot** (app-free, best-effort)

Everything works **without installing anything on the phone** — you only enable USB debugging once.

## Requirements

- macOS 14 (Sonoma) or newer
- An Android phone with **USB debugging** enabled
- [Homebrew](https://brew.sh) (used to install the engine)

## Quick start

```bash
# 1. Install the engine (adb + scrcpy) and verify your phone is detected
./Scripts/setup.sh

# 2. (Optional) prove the concept immediately, no app needed:
scrcpy --turn-screen-off --stay-awake

# 3. Build & run the Mac app
swift run
```

### Enabling USB debugging on the phone (one time)

1. **Settings → About phone →** tap **Build number** 7 times
2. **Settings → System → Developer options →** enable **USB debugging**
3. Plug the phone into the Mac and **accept the prompt** ("Allow USB debugging?")

## Architecture

```
SwiftUI app (this repo)
   └── drives ──> adb        → devices, files, input, info, notifications
   └── drives ──> scrcpy     → screen mirror + control (incl. screen-off)
                     └── talks to ──> Android phone (USB debugging on)
```

The Swift code is a **controller and UI** over the engine — it does not reimplement screen mirroring. Key files:

| File | Role |
|------|------|
| `ToolLocator.swift` | Finds `adb` / `scrcpy` (bundled, Homebrew, or PATH) |
| `Shell.swift` | Async `Process` wrapper |
| `ADB.swift` | All app-free control: devices, files, input, info, notifications, wireless |
| `Scrcpy.swift` | Launches/stops mirror sessions, incl. `--turn-screen-off` |
| `AppModel.swift` | Observable app state bridging engine ↔ UI |
| `*View.swift` | SwiftUI interface |

## Roadmap

- **Phase 1 (this):** app-free core — mirror, screen-off, files, automation, basic notifications ✅
- **Phase 2:** wireless pairing UX polish, macro recorder/player, embedded mirror view
- **Phase 3:** optional companion Android app for live notifications + SMS reply
- **Phase 4:** internet/relay mode (opt-in, security-hardened)

## Distribution

Releases ship as a `.dmg` via **GitHub Releases** (direct download — no App Store).
The Mac App Store is intentionally not targeted; its sandbox forbids the process/USB control iDroid needs.

> First launch on an unsigned build: **right-click the app → Open** to bypass Gatekeeper.

## License

See [`LICENSE`](LICENSE). Note `scrcpy` is Apache-2.0 and `adb` ships with the Android SDK platform-tools — comply with their terms when bundling.
