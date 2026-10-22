#!/usr/bin/env bash
# Builds build/Bubbleg.app. Signing with a stable identity keeps the Accessibility and
# Screen Recording grants across rebuilds; an ad-hoc signature has to be re-granted every time.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Bubbleg.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Bubbleg "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources"
cp Resources/* "$APP/Contents/Resources/"

IDENTITY="${BUBBLEG_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
