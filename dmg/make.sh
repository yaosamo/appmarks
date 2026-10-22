#!/usr/bin/env bash
# Wraps an exported, notarized Bubbleg.app in the drag-to-Applications disk image the site serves.
#   dmg/make.sh path/to/Bubbleg.app
# Needs dmgbuild (`pipx install dmgbuild`). The window layout is dmg/settings.py; the background,
# pink arrow and hint included, is dmg/background.tiff (1x and 2x in one file).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=${1:?usage: dmg/make.sh path/to/Bubbleg.app}
xcrun stapler validate "$APP" >/dev/null || { echo "$APP isn't notarized and stapled" >&2; exit 1; }

dmgbuild -s dmg/settings.py \
  -D app="$APP" -D background=dmg/background.tiff -D icon=Resources/AppIcon.icns \
  Bubbleg site/Bubbleg.dmg
echo "Built site/Bubbleg.dmg"
