#!/bin/bash
# Build an unsigned device IPA for re-signing by SideStore/AltStore/Sideloadly.
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_PATH="$PROJECT_ROOT/build/iRAM-Plus.ipa"

usage() {
    cat <<'EOF'
Usage: ./build-ipa.sh [--output /path/to/App.ipa]

Builds the Release configuration for physical iOS devices and packages an
unsigned IPA. Import the IPA into a sideloading tool to sign and install it.
Requires macOS, full Xcode, and internet access for uncached dependencies.

Options:
  --output PATH  Output IPA path (default: build/iRAM-Plus.ipa)
  -h, --help     Show this help

Environment:
  DEVELOPER_DIR       Optional Xcode Developer directory
  DERIVED_DATA_PATH  Build cache (default: build/DerivedData)
  PACKAGE_CACHE_PATH Swift package cache (default: build/SourcePackages)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            [[ $# -ge 2 && -n "$2" ]] || { echo 'Error: --output requires a path.' >&2; exit 2; }
            OUTPUT_PATH="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$(uname -s)" == Darwin ]] || { echo 'Error: this script requires macOS and Xcode.' >&2; exit 1; }
[[ "$OUTPUT_PATH" == *.ipa ]] || { echo 'Error: output path must end in .ipa.' >&2; exit 2; }
xcrun --sdk iphoneos --show-sdk-path >/dev/null || {
    echo 'Select full Xcode using DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer.' >&2
    exit 1
}

mkdir -p -- "$(dirname -- "$OUTPUT_PATH")" "$PROJECT_ROOT/build"
OUTPUT_PATH="$(cd -- "$(dirname -- "$OUTPUT_PATH")" && pwd)/$(basename -- "$OUTPUT_PATH")"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PROJECT_ROOT/build/DerivedData}"
PACKAGE_CACHE_PATH="${PACKAGE_CACHE_PATH:-$PROJECT_ROOT/build/SourcePackages}"
BUILD_WORK_DIR="$(mktemp -d "$PROJECT_ROOT/build/ipa.XXXXXX")"
trap 'rm -rf -- "$BUILD_WORK_DIR"' EXIT

xcodebuild -version
printf '\nBuilding Release for iOS devices...\n'
xcodebuild archive \
    -project "$PROJECT_ROOT/iRAM-Plus.xcodeproj" \
    -scheme iRAM-Plus \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$BUILD_WORK_DIR/iRAM-Plus.xcarchive" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -clonedSourcePackagesDirPath "$PACKAGE_CACHE_PATH" \
    -skipPackageUpdates \
    -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    DEVELOPMENT_TEAM= \
    | tee "$PROJECT_ROOT/build/build-ipa.log"

APP_PATH="$BUILD_WORK_DIR/iRAM-Plus.xcarchive/Products/Applications/iRAM-Plus.app"
[[ -d "$APP_PATH" ]] || { echo 'Error: archive does not contain iRAM-Plus.app.' >&2; exit 1; }
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Info.plist")"
[[ -f "$APP_PATH/$APP_EXECUTABLE" ]] || { echo 'Error: app executable is missing.' >&2; exit 1; }
xcrun lipo "$APP_PATH/$APP_EXECUTABLE" -verify_arch arm64

mkdir -p "$BUILD_WORK_DIR/Payload"
/usr/bin/ditto "$APP_PATH" "$BUILD_WORK_DIR/Payload/iRAM-Plus.app"
/usr/bin/ditto -c -k --norsrc --keepParent "$BUILD_WORK_DIR/Payload" "$BUILD_WORK_DIR/iRAM-Plus.ipa"
/usr/bin/unzip -tq "$BUILD_WORK_DIR/iRAM-Plus.ipa"
mv -f -- "$BUILD_WORK_DIR/iRAM-Plus.ipa" "$OUTPUT_PATH"
printf '\nCreated: %s\nImport this unsigned IPA into your sideloading tool to sign and install it.\n' "$OUTPUT_PATH"
