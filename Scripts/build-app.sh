#!/usr/bin/env bash
#
# Builds MimicOS.app — a self-contained macOS app bundle with adb + scrcpy
# (and scrcpy's dylibs + server) bundled inside, so end users need NO Homebrew.
#
# Output: dist/MimicOS.app
#
set -euo pipefail

# Kill any running instances of MimicOS so codesigning doesn't fail with "Operation not permitted"
pkill -x "MimicOS" || true

APP_NAME="MimicOS"
BUNDLE_ID="com.ayushman.mimicos"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
TOOLS="$RES/tools"

bold(){ printf "\033[1m%s\033[0m\n" "$1"; }

bold "1/6  Building release binary (swift build -c release)"
cd "$ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
[ -x "$BIN" ] || { echo "Build product not found at $BIN"; exit 1; }

bold "2/6  Assembling app bundle skeleton"
rm -rf "$APP"
mkdir -p "$MACOS" "$TOOLS"
cp "$BIN" "$MACOS/$APP_NAME"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>2.0</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

bold "3/6  Bundling adb + scrcpy + scrcpy-server"
ADB_SRC="$(command -v adb || true)"
SCRCPY_SRC="$(command -v scrcpy || true)"
[ -n "$ADB_SRC" ]   || { echo "adb not found on PATH (brew install --cask android-platform-tools)"; exit 1; }
[ -n "$SCRCPY_SRC" ]|| { echo "scrcpy not found on PATH (brew install scrcpy)"; exit 1; }

cp "$ADB_SRC" "$TOOLS/adb"
cp "$SCRCPY_SRC" "$TOOLS/scrcpy"

# scrcpy-server lives in Homebrew's share dir; scrcpy looks for it via the
# SCRCPY_SERVER_PATH env var, which the app sets to the bundled copy.
SERVER_SRC="$(find "$(brew --prefix scrcpy 2>/dev/null)/share/scrcpy" -name 'scrcpy-server' 2>/dev/null | head -1)"
[ -n "$SERVER_SRC" ] && cp "$SERVER_SRC" "$TOOLS/scrcpy-server" || echo "WARN: scrcpy-server not found; set SCRCPY_SERVER_PATH at runtime"

bold "4/6  Bundling scrcpy's dynamic libraries (so it runs without Homebrew)"
# Copy every Homebrew dylib scrcpy links against into tools/, then rewrite the
# binary's load paths to @executable_path so it's self-contained.
bundle_dylibs() {
  local target="$1"
  otool -L "$target" | awk 'NR>1 {print $1}' | grep -E '^/(opt/homebrew|usr/local)/' | while read -r dylib; do
    local base; base="$(basename "$dylib")"
    if [ ! -f "$TOOLS/$base" ]; then
      cp "$dylib" "$TOOLS/$base" 2>/dev/null || continue
      chmod u+w "$TOOLS/$base"
      bundle_dylibs "$TOOLS/$base"   # recurse into the dylib's own deps
    fi
    install_name_tool -change "$dylib" "@loader_path/$base" "$target" 2>/dev/null || true
  done
}
chmod u+w "$TOOLS/scrcpy"
bundle_dylibs "$TOOLS/scrcpy"

bold "5/6  Generating macOS AppIcon.icns from logo.png"
LOGO_SRC="$ROOT/docs/images/logo.png"
if [ -f "$LOGO_SRC" ]; then
  ICONSET="$DIST/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  
  # Scale and output all required standard macOS sizes using sips
  sips -z 16 16     "$LOGO_SRC" --out "$ICONSET/icon_16x16.png" >/dev/null 2>&1
  sips -z 32 32     "$LOGO_SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null 2>&1
  sips -z 32 32     "$LOGO_SRC" --out "$ICONSET/icon_32x32.png" >/dev/null 2>&1
  sips -z 64 64     "$LOGO_SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null 2>&1
  sips -z 128 128   "$LOGO_SRC" --out "$ICONSET/icon_128x128.png" >/dev/null 2>&1
  sips -z 256 256   "$LOGO_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1
  sips -z 256 256   "$LOGO_SRC" --out "$ICONSET/icon_256x256.png" >/dev/null 2>&1
  sips -z 512 512   "$LOGO_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1
  sips -z 512 512   "$LOGO_SRC" --out "$ICONSET/icon_512x512.png" >/dev/null 2>&1
  sips -z 1024 1024 "$LOGO_SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null 2>&1
  
  iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
  rm -rf "$ICONSET"
  echo "  Success: Compiled AppIcon.icns from docs/images/logo.png"
else
  echo "  Warning: docs/images/logo.png not found; skipping icon generation"
fi

bold "6/6  Removing quarantine attributes & ad-hoc signing"
# Remove any quarantine/extended attributes recursively first so they don't invalidate signing.
xattr -cr "$APP" 2>/dev/null || true
# Ad-hoc sign every binary and library so Gatekeeper allows it.
find "$TOOLS" -type f \( -name "*.dylib" -o -perm +111 \) -exec codesign --force --sign - {} \;
codesign --force --deep --sign - "$APP"

echo
bold "Done: $APP"
echo "Run it:  open \"$APP\""
echo "Make a DMG:  ./Scripts/make-dmg.sh"
echo
echo "⚠️  NOTE: Rebuilding changes the app's ad-hoc code signature hash."
echo "   macOS will revoke/invalidate any previously granted Accessibility permissions."
echo "   If you use the sidebar, you will need to re-grant access in System Settings"
echo "   (or toggle it off and on) and relaunch the app."
echo
