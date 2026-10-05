#!/usr/bin/env bash
# Archive the iOS app with a timestamp build number and upload it to
# App Store Connect / TestFlight.
#
# Usage: ios-src/scripts/testflight.sh [--archive-only]
#
#   --archive-only  Archive and verify build numbers, but skip export/upload.
#
# BUILD_NUMBER may be set in the environment to override the default
# UTC timestamp (YYYYMMDDHHMM). It must be greater than any build already
# uploaded for the current MARKETING_VERSION.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="$IOS_DIR/KV4P HT/KV4P HT.xcodeproj"
SCHEME="KV4P HT"
EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.plist"

ARCHIVE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --archive-only) ARCHIVE_ONLY=1 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# UTC so the number never goes backwards across a DST change.
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "BUILD_NUMBER must be numeric, got '$BUILD_NUMBER'" >&2
  exit 2
fi

OUT_DIR="$IOS_DIR/build/testflight/$BUILD_NUMBER"
ARCHIVE="$OUT_DIR/KV4P HT.xcarchive"
mkdir -p "$OUT_DIR"

echo "==> Archiving build $BUILD_NUMBER"
# Passing CURRENT_PROJECT_VERSION on the command line overrides it for every
# target in the build, so the app and the widget extension always match.
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

# App Store Connect rejects uploads whose extensions' CFBundleVersion differs
# from the host app's, so check before spending time on an upload.
APP="$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -name '*.app' | head -n 1)"
mismatch=0
while IFS= read -r -d '' bundle; do
  v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle/Info.plist")"
  echo "    $(basename "$bundle"): $v"
  [[ "$v" == "$BUILD_NUMBER" ]] || mismatch=1
done < <(find "$APP" "$APP/PlugIns" -maxdepth 1 \( -name '*.app' -o -name '*.appex' \) -print0 2>/dev/null)
if (( mismatch )); then
  echo "CFBundleVersion mismatch in archive; expected $BUILD_NUMBER" >&2
  exit 1
fi

if (( ARCHIVE_ONLY )); then
  echo "==> Archive only; skipping upload. Archive: $ARCHIVE"
  exit 0
fi

echo "==> Exporting and uploading to App Store Connect"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$OUT_DIR/export" \
  -allowProvisioningUpdates

echo "==> Uploaded build $BUILD_NUMBER"
