#!/bin/zsh
# Builds the release app and packages it for distribution:
#   dist/<APP_NAME>-<VERSION>.dmg   (drag-to-Applications image with license and notices)
#   dist/<APP_NAME>-<VERSION>.zip   (same app, ditto keeps the signature)
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

"$ROOT/scripts/third-party-notices.sh"
"$ROOT/scripts/build-app.sh" release

APP="$ROOT/build/$APP_NAME.app"
DIST="$ROOT/dist"
NAME="${APP_NAME// /-}-$VERSION"
rm -rf "$DIST" && mkdir -p "$DIST"

echo "▸ ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"

echo "▸ DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/LICENSE" "$STAGE/LICENCIA.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/AVISOS-DE-TERCEROS.md"
cat > "$STAGE/LEEME.txt" <<TXT
$APP_NAME $VERSION

1. Arrastra "$APP_NAME" a la carpeta Aplicaciones.
2. Ábrela una vez. macOS dirá que no puede verificar al desarrollador (la app no está notarizada).
3. Ve a Ajustes del Sistema › Privacidad y seguridad y pulsa "Abrir de todos modos".
4. Al primer uso descarga los modelos locales (~650 MB) y pide permiso de micrófono y de audio del sistema.

Requisitos: Mac con Apple Silicon y macOS 26 o posterior.
Más información: https://github.com/corpjorge/MeetingIntelligence
TXT
hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DIST/$NAME.dmg"

echo "▸ Sumas"
( cd "$DIST" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt )
ls -lh "$DIST"
