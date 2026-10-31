#!/usr/bin/env bash
# Archives the sandboxed "Bubbleg App Store" scheme and exports a signed installer package for the
# Mac App Store. With --upload it sends the build straight to App Store Connect instead.
#
#   AppStore/archive.sh            # → build/appstore/Bubbleg.pkg (check it, then upload with Transporter)
#   AppStore/archive.sh --upload   # → uploads to App Store Connect (the app record must exist)
#
# Signing is automatic: Xcode creates the Apple Distribution and Mac Installer Distribution certificates
# and the Mac App Store profile in the cloud, for the account signed in under Xcode → Settings → Accounts.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen >/dev/null
OUT=build/appstore
ARCHIVE=$OUT/Bubbleg.xcarchive
OPTIONS=$OUT/ExportOptions.plist
rm -rf "$OUT"
mkdir -p "$OUT"
cp AppStore/ExportOptions.plist "$OPTIONS"
if [[ "${1:-}" == "--upload" ]]; then
  /usr/libexec/PlistBuddy -c "Set :destination upload" "$OPTIONS"
fi

xcodebuild -project Bubbleg.xcodeproj -scheme "Bubbleg App Store" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" archive -allowProvisioningUpdates

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
  -exportPath "$OUT" -allowProvisioningUpdates

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
if [[ "${1:-}" == "--upload" ]]; then
  echo "Uploaded Bubbleg $VERSION ($BUILD). It shows up under TestFlight in App Store Connect after processing."
else
  echo "Exported $OUT/Bubbleg.pkg — Bubbleg $VERSION ($BUILD). Upload it with Transporter, or rerun with --upload."
fi
