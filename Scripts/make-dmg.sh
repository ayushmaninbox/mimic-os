#!/usr/bin/env bash
#
# Creates a distributable DMG from the built MimicOS.app.
#
# Prerequisites: run ./Scripts/build-app.sh first to produce dist/MimicOS.app.
#
# Output: dist/MimicOS-v2.0.dmg
#
set -euo pipefail

APP_NAME="MimicOS"
VERSION="2.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG_NAME="${APP_NAME}-v${VERSION}"
DMG_PATH="$DIST/${DMG_NAME}.dmg"
DMG_TEMP="$DIST/${DMG_NAME}-temp.dmg"
VOLUME_NAME="$APP_NAME"
DMG_SIZE="300m"   # generous; hdiutil will compact it

bold(){ printf "\033[1m%s\033[0m\n" "$1"; }
green(){ printf "\033[32m%s\033[0m\n" "$1"; }
red(){ printf "\033[31m%s\033[0m\n" "$1"; }

# Verify the app exists
if [ ! -d "$APP" ]; then
  red "MimicOS.app not found at $APP"
  echo "Run ./Scripts/build-app.sh first."
  exit 1
fi

# Clean previous DMGs
rm -f "$DMG_PATH" "$DMG_TEMP"

bold "1/4  Creating temporary DMG image"
hdiutil create -size "$DMG_SIZE" -fs HFS+ -volname "$VOLUME_NAME" "$DMG_TEMP"

bold "2/4  Mounting and copying app"
MOUNT_DIR=$(hdiutil attach "$DMG_TEMP" -readwrite -noverify | grep "/Volumes/" | awk -F'\t' '{print $NF}')
echo "  Mounted at: $MOUNT_DIR"

# Copy the app bundle
cp -R "$APP" "$MOUNT_DIR/"

# Create a symlink to /Applications for the drag-to-install UX
ln -s /Applications "$MOUNT_DIR/Applications"

# Create a Gatekeeper helper note
cat > "$MOUNT_DIR/Readme (If App Does Not Open).txt" << 'EOF'
MimicOS - If the App Won't Open
===============================
Because MimicOS is an open-source tool and signed with an ad-hoc signature,
macOS Gatekeeper might block it with a message saying:
"MimicOS Not Opened — Apple could not verify..." and only offer "Done" or "Move to Bin".

To bypass this and run the app, choose one of these methods:

Method 1: Right-Click Bypass (Recommended)
------------------------------------------
1. Drag MimicOS to your Applications folder.
2. In Finder, open your Applications folder.
3. Right-click (or Control-click) MimicOS.app and choose "Open".
4. A similar dialog will appear, but this time it will have an "Open" button. Click "Open".
5. macOS will remember your choice, and the app will open normally from then on.

Method 2: System Settings (macOS Ventura/Sonoma/Sequoia+)
---------------------------------------------------------
1. Attempt to open MimicOS once (letting it show the blocked dialog), then click "Done".
2. Open System Settings -> Privacy & Security.
3. Scroll down to the Security section. You will see:
   "MimicOS was blocked to protect your Mac."
4. Click "Open Anyway", enter your password/TouchID, and click "Open".

Method 3: Terminal Command (Most Reliable)
------------------------------------------
If macOS remains stubborn, open Terminal and run the following command to strip the quarantine attribute:

    xattr -dr com.apple.quarantine /Applications/MimicOS.app

Then open it normally from Applications.
EOF

# Set background and icon layout with AppleScript (clean, standard style)
VOLUME_BASE="$(basename "$MOUNT_DIR")"
echo '
   tell application "Finder"
     tell disk "'"$VOLUME_BASE"'"
       open
       set current view of container window to icon view
       set toolbar visible of container window to false
       set statusbar visible of container window to false
       set the bounds of container window to {100, 100, 640, 400}
       set viewOptions to the icon view options of container window
       set arrangement of viewOptions to not arranged
       set icon size of viewOptions to 96
       set position of item "'"$APP_NAME.app"'" of container window to {140, 120}
       set position of item "Applications" of container window to {400, 120}
       set position of item "Readme (If App Does Not Open).txt" of container window to {270, 240}
       close
       open
       update without registering applications
       delay 1
       close
     end tell
   end tell
' | osascript || echo "  (DMG layout hint skipped — cosmetic only)"

bold "3/4  Unmounting"
sync
hdiutil detach "$MOUNT_DIR" -quiet

bold "4/4  Compressing to final DMG"
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$DMG_TEMP"

echo
green "Done: $DMG_PATH"
echo
echo "Size: $(du -h "$DMG_PATH" | cut -f1)"
echo
echo "To distribute:"
echo "  1. Upload to GitHub Releases (see README for instructions)"
echo "  2. Users download, open the DMG, drag MimicOS to Applications"
echo "  3. First launch: right-click → Open → click 'Open'"
