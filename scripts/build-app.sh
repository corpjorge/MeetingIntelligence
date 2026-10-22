#!/bin/zsh
# Builds a signed (ad-hoc by default) macOS app bundle from the SwiftPM products.
#
#   scripts/build-app.sh [debug|release]
#
# Output: build/<APP_NAME>.app containing
#   Contents/MacOS/MeetingIntelligence          (SwiftUI app)
#   Contents/MacOS/meeting-intelligence-mcp     (read-only MCP server, stdio)
#   Contents/MacOS/mi                           (CLI)
#
# Signing: set SIGN_IDENTITY to a code-signing identity to keep macOS privacy
# grants (Microphone / System Audio Recording) across rebuilds. With ad-hoc
# signing ("-"), macOS asks again after every rebuild.
set -euo pipefail
ROOT="${0:A:h:h}"
CONFIG="${1:-release}"
source "$ROOT/config/app.env"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
cd "$ROOT"

echo "▸ Compilando ($CONFIG)…"
for product in "$EXECUTABLE_NAME" meeting-intelligence-mcp mi; do
  "$ROOT/scripts/swiftw" build -c "$CONFIG" --product "$product" 2>&1 \
    | grep -v "search path '/Library/Developer/CommandLineTools" | grep -E "error|warning: |Compiling|Build complete" || true
done
BIN="$("$ROOT/scripts/swiftw" build -c "$CONFIG" --show-bin-path)"
[[ -x "$BIN/$EXECUTABLE_NAME" ]] || { echo "No se encontró $BIN/$EXECUTABLE_NAME" >&2; exit 1; }

APP="$ROOT/build/$APP_NAME.app"
echo "▸ Ensamblando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$EXECUTABLE_NAME" "$APP/Contents/MacOS/$EXECUTABLE_NAME"
cp "$BIN/meeting-intelligence-mcp" "$APP/Contents/MacOS/"
cp "$BIN/mi" "$APP/Contents/MacOS/"
for bundle in "$BIN"/*.bundle(N); do cp -R "$bundle" "$APP/Contents/Resources/"; done
# License and third-party notices travel with the binary.
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"

echo "▸ Icono"
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ROOT/build/icon_1024.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$ROOT/build/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ROOT/build/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>es</string>
  <key>CFBundleLocalizations</key><array><string>es</string></array>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSMicrophoneUsageDescription</key>
  <string>$APP_NAME graba tu micrófono durante las reuniones que tú inicias, para transcribirlas localmente.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>$APP_NAME captura el audio de la app de llamada que elijas (o de todo el sistema, si lo eliges) durante las reuniones que tú inicias, para transcribirlas localmente.</string>
</dict>
</plist>
PLIST

echo "▸ Firmando (${SIGN_IDENTITY})"
ENTITLEMENTS="$ROOT/config/MeetingIntelligence.entitlements"
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/meeting-intelligence-mcp"
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/mi"
codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict "$APP"
echo "✓ $APP"
