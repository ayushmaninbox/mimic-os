# Third-party components

MimicOS is a GUI built on top of two open-source tools. It bundles and/or
invokes them; their licenses and notices are preserved here.

## scrcpy
- Project: https://github.com/Genymobile/scrcpy
- License: Apache License 2.0
- Copyright © Genymobile / Romain Vimont
- MimicOS launches `scrcpy` to mirror and control the device and bundles the
  `scrcpy` binary, its dynamic libraries, and `scrcpy-server` inside the app.
  A copy of the Apache 2.0 license is included with the bundled binaries.

## Android Debug Bridge (adb)
- Part of the Android SDK Platform-Tools.
- License: Android Software Development Kit License / Apache 2.0 components.
- Distributed by Google; redistributable as part of platform-tools.
- MimicOS bundles and invokes `adb` to discover devices, transfer files, read
  device info, inject input, and switch transports.

When redistributing MimicOS, keep this NOTICE and the bundled licenses intact.
