#!/bin/bash
# Build, sign and install JellyCast on a paired iPhone.
#
# Signs by hand against the team's Xcode-managed wildcard profile, because
# xcodebuild refuses to use an Xcode-managed profile in manual mode and
# automatic mode needs an Apple ID added to Xcode. This path needs neither.
set -euo pipefail

DEVICE="${1:-11CCE7F9-C289-5D73-93B1-F93BBA424C56}"   # default: Yitzchok's iPhone 16 Pro Max
BUNDLE_ID="com.yitzchokwagner.jellycast"
TEAM="N484MY8AUM"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

cd "$(dirname "$0")"

# Prefer a profile issued for this exact bundle id: only an explicit App ID can
# carry the CarPlay and Siri entitlements. Fall back to the team wildcard
# otherwise. Only development profiles count (an App Store profile lists no
# devices), and the newest wins, so a freshly downloaded profile with a new
# capability beats the stale one it replaces.
PROFILE=""
WILDCARD=""
NEWEST=""
for candidate in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  security cms -D -i "$candidate" > "$BUILD_DIR/probe.plist" 2>/dev/null || continue
  dev=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:get-task-allow" \
    "$BUILD_DIR/probe.plist" 2>/dev/null || true)
  [ "$dev" = "true" ] || continue
  appid=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" \
    "$BUILD_DIR/probe.plist" 2>/dev/null || true)
  # ISO 8601 in UTC, so plain string comparison orders them.
  created=$(plutil -extract CreationDate raw -o - "$BUILD_DIR/probe.plist" 2>/dev/null || echo "")
  case "$appid" in
    "$TEAM.$BUNDLE_ID") [[ ! "$created" < "$NEWEST" ]] && { PROFILE="$candidate"; NEWEST="$created"; } ;;
    "$TEAM.*")          [ -z "$WILDCARD" ] && WILDCARD="$candidate" ;;
  esac
done
[ -z "$PROFILE" ] && PROFILE="$WILDCARD"
if [ -z "$PROFILE" ]; then
  echo "No provisioning profile for team $TEAM found." >&2
  echo "Open any project of yours in Xcode once to have it refresh profiles." >&2
  exit 1
fi

IDENTITY=$(security find-identity -v -p codesigning \
  | grep "Apple Development" | head -1 | awk '{print $2}')
if [ -z "$IDENTITY" ]; then
  echo "No 'Apple Development' signing certificate in the keychain." >&2
  exit 1
fi

echo "==> Building (Release)"
xcodebuild -project JellyCast.xcodeproj -scheme JellyCast -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build > "$BUILD_DIR/build.log" 2>&1 \
  || { echo "Build failed:"; grep -E "error:" "$BUILD_DIR/build.log" | head -20; exit 1; }

APP="$BUILD_DIR/JellyCast.app"

echo "==> Signing with $(basename "$PROFILE")"
cp "$PROFILE" "$APP/embedded.mobileprovision"
# Entitlements come from the profile itself, so once Apple grants CarPlay and a
# new profile is downloaded, com.apple.developer.carplay-audio flows in here
# automatically -- nothing else to change.
security cms -D -i "$PROFILE" > "$BUILD_DIR/profile.plist" 2>/dev/null
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$BUILD_DIR/profile.plist" > "$BUILD_DIR/ent.plist"
/usr/libexec/PlistBuddy -c "Set :application-identifier $TEAM.$BUNDLE_ID" "$BUILD_DIR/ent.plist"

codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Frameworks/GoogleCast.framework"
codesign --force --sign "$IDENTITY" --entitlements "$BUILD_DIR/ent.plist" \
  --generate-entitlement-der --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

# Report the entitlements that actually made it into the signature. CarPlay is
# granted via the profile, so this is the only honest proof it is really there.
echo "==> Signed entitlements"
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
  | plutil -convert xml1 -o - - 2>/dev/null \
  | grep -o 'com\.apple\.developer\.[a-z-]*' | sort -u | sed 's/^/    /'

echo "==> Installing to $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$APP" | tail -3
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" | tail -1
echo "==> Done"
