#!/bin/zsh
# Builds the release app and packages it for distribution:
#   dist/<APP_NAME>-<VERSION>.dmg   (drag-to-Applications image with license and notices)
#   dist/<APP_NAME>-<VERSION>.zip   (same app, ditto keeps the signature; used by in-app updates)
#   dist/<APP_NAME>-<VERSION>.zip.sig  (Ed25519 signature checked by the in-app updater, TD-29)
#   dist/SHA256SUMS.txt
#
#   scripts/package-release.sh
#
# Signing follows build-app.sh (ad-hoc unless SIGN_IDENTITY is set); the app is not
# notarized, so macOS asks to confirm the first launch (see the release notes).
set -euo pipefail
ROOT="${0:A:h:h}"
source "$ROOT/config/app.env"
cd "$ROOT"

[[ -n "${UPDATE_PUBLIC_KEY:-}" ]] || { echo "Falta UPDATE_PUBLIC_KEY en config/app.env (ver TD-29)." >&2; exit 1; }
TOOL_BUILD_LOG="$(mktemp)"
if ! "$ROOT/scripts/swiftw" build -c release --product mi-release >"$TOOL_BUILD_LOG" 2>&1; then
  cat "$TOOL_BUILD_LOG" >&2
  rm -f "$TOOL_BUILD_LOG"
  exit 1
fi
rm -f "$TOOL_BUILD_LOG"
RELEASE_TOOL="$("$ROOT/scripts/swiftw" build -c release --show-bin-path)/mi-release"
# Fail before building if the Keychain key does not match the key the app will embed.
[[ "$("$RELEASE_TOOL" public-key)" == "$UPDATE_PUBLIC_KEY" ]] \
  || { echo "La clave de firma del Llavero no corresponde a UPDATE_PUBLIC_KEY." >&2; exit 1; }

"$ROOT/scripts/third-party-notices.sh"
APP_OUTPUT_ROOT="$ROOT/build" "$ROOT/scripts/build-app.sh" release

# Finder metadata is written directly, without opening Finder or requesting Automation access.
DMG_TOOLS="$ROOT/build/dmg-tools"
[[ -x "$DMG_TOOLS/bin/python3" ]] || python3 -m venv "$DMG_TOOLS"
"$DMG_TOOLS/bin/python3" -m pip install --disable-pip-version-check -r "$ROOT/scripts/requirements-dmg.txt"

APP="$ROOT/build/$APP_NAME.app"
DIST="$ROOT/dist"
NAME="${APP_NAME// /-}-$VERSION"
rm -rf "$DIST" && mkdir -p "$DIST"

echo "▸ ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"

echo "▸ Firma de actualización"
"$RELEASE_TOOL" sign "$DIST/$NAME.zip" --version "$VERSION" --public-key "$UPDATE_PUBLIC_KEY" > "$DIST/$NAME.zip.sig"
"$RELEASE_TOOL" verify "$DIST/$NAME.zip" --version "$VERSION" --signature "$DIST/$NAME.zip.sig" --public-key "$UPDATE_PUBLIC_KEY"

echo "▸ DMG"
# Standard drag-to-Applications window: background with an arrow, the app on the left, the
# Applications alias on the right, docs in "Léeme". Finder stores the layout in the image's .DS_Store.
VOLUME="$APP_NAME $VERSION"
# Never touch a volume we did not mount (e.g. a downloaded copy of this DMG that is open).
[[ -e "/Volumes/$VOLUME" ]] && { echo "Expulsa primero el volumen «$VOLUME»." >&2; exit 1; }
STAGE="$(mktemp -d)"
RW="$(mktemp -d)/rw.dmg"
MOUNTED=""
trap 'rm -rf "$STAGE" "${RW:h}"; [[ -n "$MOUNTED" ]] && hdiutil detach -quiet "$MOUNTED" 2>/dev/null; true' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Aplicaciones"
mkdir -p "$STAGE/Léeme" "$STAGE/.background"
cp "$ROOT/LICENSE" "$STAGE/Léeme/LICENCIA.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/Léeme/AVISOS-DE-TERCEROS.md"
cat > "$STAGE/Léeme/LEEME.txt" <<TXT
$APP_NAME $VERSION

1. Arrastra "$APP_NAME" a la carpeta Aplicaciones.
2. Ábrela desde Aplicaciones. La app no está notarizada por Apple: macOS dirá que no pudo verificarla.
   Pulsa "Listo".
3. Abre Ajustes del Sistema › Privacidad y seguridad, baja hasta Seguridad y pulsa "Abrir de todos modos"
   junto a "Se bloqueó $APP_NAME". Confirma con tu contraseña y pulsa "Abrir". Solo hace falta la primera vez.
4. Al primer uso descarga los modelos locales (~650 MB) y pide permiso de micrófono y de audio del sistema.

Requisitos: Mac con Apple Silicon y macOS 15 (Sequoia) o posterior.
Más información: https://github.com/corpjorge/MeetingIntelligence
TXT
"$ROOT/scripts/swiftw" "$ROOT/scripts/make-dmg-background.swift" "$STAGE/.background/bg.png" "$STAGE/.background/bg@2x.png"
tiffutil -cathidpicheck "$STAGE/.background/bg.png" "$STAGE/.background/bg@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null
rm "$STAGE/.background/bg.png" "$STAGE/.background/bg@2x.png"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$RW"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$RW"
MOUNTED="/Volumes/$VOLUME"
SetFile -a C "$MOUNTED"
chflags hidden "$MOUNTED/.background"
"$DMG_TOOLS/bin/python3" "$ROOT/scripts/make-dmg-layout.py" "$MOUNTED" "$APP_NAME.app"
sync
hdiutil detach -quiet "$MOUNTED"
MOUNTED=""
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DIST/$NAME.dmg"

echo "▸ Sumas"
( cd "$DIST" && shasum -a 256 "$NAME.dmg" "$NAME.zip" "$NAME.zip.sig" > SHA256SUMS.txt )
ls -lh "$DIST"
