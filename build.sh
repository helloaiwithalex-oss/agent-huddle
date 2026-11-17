#!/bin/zsh
# Builds "Agent Huddle.app" next to this script (no Xcode needed, just the Command Line Tools).
# install.sh runs this and copies the app to ~/Applications; after editing app/main.swift, run ./install.sh again.
set -e
HERE="${0:A:h}"
FINAL="$HERE/Agent Huddle.app"
# The whole app is built and signed in a side folder, then swapped in finished. Editing the app in place
# (the binary, or codesign rewriting it) makes macOS kill the running widget and refuse the next start
# once (OS_REASON_CODESIGNING).
STAGE="$(mktemp -d "$HERE/.build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Agent Huddle.app"
mkdir -p "$APP/Contents/MacOS"
build() { swiftc -O -o "$APP/Contents/MacOS/AgentHuddle" "$HERE/app/main.swift" \
  -framework Cocoa -framework SwiftUI -framework Network "$@"; }
# Some Macs have a newer macOS SDK than their Swift compiler can read (often left behind by a beta), and
# then every Swift build fails. If the default build fails, try each installed SDK, newest first.
if ! build 2>"$STAGE/err.log"; then
  DEV="$(xcode-select -p)"
  OK=""
  for SDK in "$DEV"/SDKs/MacOSX[0-9]*.sdk(NnOn) "$DEV"/Platforms/MacOSX.platform/Developer/SDKs/MacOSX[0-9]*.sdk(NnOn); do
    if build -sdk "$SDK" 2>/dev/null; then echo "built with $SDK (the default SDK didn't work with this Swift)"; OK=1; break; fi
  done
  if [[ -z "$OK" ]]; then
    cat "$STAGE/err.log" >&2
    echo "error: Swift couldn't build the app with any installed macOS SDK. Updating the Command Line Tools usually fixes it:" >&2
    echo "  softwareupdate --list   (then install the Command Line Tools update), or: sudo rm -rf $DEV && xcode-select --install" >&2
    exit 1
  fi
fi
# App icon (the blue blob): drawn by icon/make-icon.swift, turned into an .icns once
if [[ ! -f "$HERE/icon/AppIcon.icns" ]]; then
  [[ -f "$HERE/icon/AppIcon.png" ]] || swift "$HERE/icon/make-icon.swift" "$HERE/icon/AppIcon.png"
  SET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$HERE/icon/AppIcon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$HERE/icon/AppIcon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$HERE/icon/AppIcon.icns"
fi
mkdir -p "$APP/Contents/Resources"
cp "$HERE/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.agenthuddle.widget</string>
  <key>CFBundleName</key><string>Agent Huddle</string>
  <key>CFBundleExecutable</key><string>AgentHuddle</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
# Ad-hoc sign. macOS refuses to launch an app whose signature doesn't match (launchd: OS_REASON_CODESIGNING),
# so strip Finder/quarantine attributes first and stop loudly if signing or the check fails.
xattr -cr "$APP"
if ! codesign --force --deep --sign - "$APP" || ! codesign --verify --deep "$APP"; then
  echo "error: signing the app failed, so macOS won't launch it" >&2
  exit 1
fi
rm -rf "$FINAL"
mv "$APP" "$FINAL"
echo "built $FINAL"
