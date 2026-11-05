#!/usr/bin/env bash
# Builds an ad-hoc signed OpenLens.ipa for sideloading (SideStore re-signs it with
# the user's free Apple ID). Runs on macOS with Xcode 26+ (szupimac or a GitHub
# macOS runner). The entitlements are embedded ad hoc so SideStore can see and
# register the App Group; it replaces the signature on install anyway.
#
# Usage: scripts/build-ipa-ios18.sh [output-dir]   (default: build/ipa)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:-build/ipa}"
DERIVED="build/DerivedData"
APP_GROUP="$(sed -n 's/^OPENLENS_APP_GROUP *= *//p' Config/Signing.xcconfig)"

command -v xcodegen >/dev/null || brew install xcodegen
xcodebuild -version
xcodegen generate --quiet
mkdir -p build
rm -rf "$DERIVED/Build/Products/Release-iphoneos/OpenLens.app"

xcodebuild \
  -project OpenLens.xcodeproj \
  -scheme OpenLens \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build | tee build/xcodebuild.log | grep -E "error:|warning: .*only available|\*\* BUILD" || true

APP="$DERIVED/Build/Products/Release-iphoneos/OpenLens.app"
[ -d "$APP" ] || { echo "Build failed, see build/xcodebuild.log"; grep -E "error:" build/xcodebuild.log | head -50; exit 1; }

ENT="$(mktemp -t openlens-ent).plist"
cat > "$ENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>${APP_GROUP}</string>
	</array>
</dict>
</plist>
PLIST

for appex in "$APP"/PlugIns/*.appex; do
  [ -d "$appex" ] && codesign --force --sign - --entitlements "$ENT" --timestamp=none "$appex"
done
codesign --force --sign - --entitlements "$ENT" --timestamp=none "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "$APP_GROUP"

rm -rf "$OUT_DIR" && mkdir -p "$OUT_DIR/Payload"
cp -R "$APP" "$OUT_DIR/Payload/"
(cd "$OUT_DIR" && /usr/bin/zip -qry OpenLens.ipa Payload && rm -rf Payload)
echo "IPA: $OUT_DIR/OpenLens.ipa ($(du -h "$OUT_DIR/OpenLens.ipa" | cut -f1))"
