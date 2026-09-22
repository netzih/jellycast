#!/bin/bash
# Archive JellyCast and upload it to App Store Connect.
#
# Unlike install.sh (development signing by hand), an App Store build needs a
# real "Apple Distribution" certificate and an App Store provisioning profile
# for com.yitzchokwagner.jellycast with CarPlay Audio ticked. Signing stays
# MANUAL so no Apple ID has to be added to Xcode -- the cert and profile just
# need to be installed locally, and the profile name goes in ExportOptions.plist.
#
# Upload uses an App Store Connect API key (.p8), which also avoids an Xcode
# account. Create one at App Store Connect -> Users and Access -> Integrations
# -> App Store Connect API, then export:
#
#   export ASC_API_KEY_ID=XXXXXXXXXX
#   export ASC_API_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   # place AuthKey_$ASC_API_KEY_ID.p8 in ~/.appstoreconnect/private_keys/
#
# Then: ./release.sh              # archive + export + upload
#       ./release.sh --no-upload  # archive + export only (.ipa left on disk)
set -euo pipefail
cd "$(dirname "$0")"

UPLOAD=1
[ "${1:-}" = "--no-upload" ] && UPLOAD=0

OUT="build/release"
ARCHIVE="$OUT/JellyCast.xcarchive"
rm -rf "$OUT"; mkdir -p "$OUT"

if grep -q REPLACE_WITH_APP_STORE_PROFILE_NAME ExportOptions.plist; then
  echo "Edit ExportOptions.plist: set the App Store provisioning profile name." >&2
  exit 1
fi

echo "==> Regenerating project"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null

echo "==> Archiving"
xcodebuild -project JellyCast.xcodeproj -scheme JellyCast \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" \
  archive

echo "==> Exporting .ipa"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$OUT"

IPA=$(ls "$OUT"/*.ipa | head -1)
echo "==> Built $IPA"

if [ "$UPLOAD" -eq 0 ]; then
  echo "==> Skipping upload (--no-upload)"; exit 0
fi

: "${ASC_API_KEY_ID:?set ASC_API_KEY_ID}"
: "${ASC_API_ISSUER_ID:?set ASC_API_ISSUER_ID}"

echo "==> Validating"
xcrun altool --validate-app -f "$IPA" -t ios \
  --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER_ID"

echo "==> Uploading to App Store Connect"
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER_ID"

echo "==> Done. Finish the submission in App Store Connect."
