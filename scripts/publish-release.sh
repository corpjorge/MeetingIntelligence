#!/bin/zsh
# Publishes the packaged release (scripts/package-release.sh) as a GitHub release:
#
#   scripts/publish-release.sh docs/releases/<VERSION>.md [--prerelease]
#
# Creates the tag v<VERSION> on the current commit and uploads the DMG, the ZIP, its update
# signature (.zip.sig, required by the in-app updater, TD-29) and SHA256SUMS.txt.
# The commit must be pushed and the working tree clean, so the release matches the repository.
set -euo pipefail
ROOT="${0:A:h:h}"
source "$ROOT/config/app.env"
cd "$ROOT"

NOTES="${1:?Uso: scripts/publish-release.sh docs/releases/<versión>.md [--prerelease]}"
shift
[[ -f "$NOTES" ]] || { echo "No existe $NOTES." >&2; exit 1; }
NAME="${APP_NAME// /-}-$VERSION"
ASSETS=("dist/$NAME.dmg" "dist/$NAME.zip" "dist/$NAME.zip.sig" "dist/SHA256SUMS.txt")
for asset in "${ASSETS[@]}"; do
  [[ -f "$asset" ]] || { echo "Falta $asset: ejecuta scripts/package-release.sh." >&2; exit 1; }
done
[[ -z "$(git status --porcelain)" ]] || { echo "Hay cambios sin confirmar." >&2; exit 1; }
[[ -f dist/SOURCE_TREE ]] || { echo "Falta dist/SOURCE_TREE: ejecuta scripts/package-release.sh." >&2; exit 1; }
[[ "$(<dist/SOURCE_TREE)" == "$(git rev-parse 'HEAD^{tree}')" ]] \
  || { echo "dist/ no se empaquetó desde este commit: ejecuta scripts/package-release.sh otra vez." >&2; exit 1; }
git fetch --quiet origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{u}')" ]] || { echo "Sube primero la rama (git push)." >&2; exit 1; }
if gh release view "v$VERSION" >/dev/null 2>&1; then echo "Ya existe el release v$VERSION." >&2; exit 1; fi

# Same checks the app will make: signature for the embedded key, and the version inside the ZIP.
RELEASE_TOOL="$("$ROOT/scripts/swiftw" build -c release --show-bin-path)/mi-release"
"$RELEASE_TOOL" verify "dist/$NAME.zip" --version "$VERSION" --signature "dist/$NAME.zip.sig" --public-key "$UPDATE_PUBLIC_KEY"
INSIDE="$(unzip -p "dist/$NAME.zip" "$APP_NAME.app/Contents/Info.plist" | plutil -extract CFBundleShortVersionString raw -)"
[[ "$INSIDE" == "$VERSION" ]] || { echo "El ZIP contiene la versión $INSIDE, no $VERSION." >&2; exit 1; }
( cd dist && shasum -a 256 -c SHA256SUMS.txt )

gh release create "v$VERSION" "${ASSETS[@]}" --target "$(git rev-parse HEAD)" \
  --title "$APP_NAME $VERSION" --notes-file "$NOTES" "$@"
echo "✓ Publicado v$VERSION"
