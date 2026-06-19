#!/usr/bin/env bash
#
# iDroid setup — installs the app-free engine (adb + scrcpy) and verifies it.
# Phase 0: prove the whole concept works before touching any Swift.
#
set -euo pipefail

bold()  { printf "\033[1m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }

bold "iDroid setup"
echo

# 1. Homebrew --------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  red "Homebrew not found. Install it from https://brew.sh and re-run."
  exit 1
fi
green "[ok] Homebrew found"

# 2. adb + scrcpy ----------------------------------------------------------
install_if_missing() {
  local tool="$1" cask_or_formula="$2" kind="$3"
  if command -v "$tool" >/dev/null 2>&1; then
    green "[ok] ${tool} already installed ($(command -v "$tool"))"
  else
    yellow "Installing ${tool}..."
    if [ "$kind" = "cask" ]; then
      brew install --cask "$cask_or_formula"
    else
      brew install "$cask_or_formula"
    fi
  fi
}

# scrcpy's formula pulls in android-platform-tools (adb) as a dependency,
# but we install adb explicitly so it's present even if that changes.
install_if_missing adb    android-platform-tools cask
install_if_missing scrcpy scrcpy                 formula

echo
bold "Versions"
adb --version | head -1 || true
scrcpy --version | head -1 || true

# 3. Device check ----------------------------------------------------------
echo
bold "Looking for a connected device..."
adb start-server >/dev/null 2>&1 || true
DEVICES=$(adb devices | sed '1d' | grep -v '^$' || true)

if [ -z "$DEVICES" ]; then
  yellow "No device detected. To connect one:"
  echo "  1. On the phone: Settings > About phone > tap 'Build number' 7 times"
  echo "  2. Settings > System > Developer options > enable 'USB debugging'"
  echo "  3. Plug the phone into this Mac with a USB cable"
  echo "  4. Accept the 'Allow USB debugging?' prompt on the phone"
  echo "  5. Re-run this script"
  exit 0
fi

green "[ok] Device(s) detected:"
echo "$DEVICES"

echo
bold "All set. Try the 'sleeping phone' experience now:"
echo "  scrcpy --turn-screen-off --stay-awake"
echo
echo "Then build the Mac app with:  swift run"
