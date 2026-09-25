#!/bin/bash
set -euo pipefail
export TZ=UTC

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zoteroquicklookmac-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

VERSION="$(/usr/bin/plutil -extract version raw "$ROOT_DIR/manifest.json")"
case "$VERSION" in
    ''|*[!a-zA-Z0-9.+_-]*)
        echo "Invalid package version: $VERSION" >&2
        exit 1
        ;;
esac

SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(/usr/bin/xcrun --find swiftc)"
LIPO="$(/usr/bin/xcrun --find lipo)"
STAGING_DIR="$BUILD_DIR/package"
mkdir -p "$STAGING_DIR" "$BUILD_DIR/swift-cache" "$BUILD_DIR/clang-cache"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-cache"

for HELPER in contactsheet pdfpreview; do
    for ARCH in arm64 x86_64; do
        "$SWIFTC" -O -sdk "$SDK_PATH" \
            -target "${ARCH}-apple-macosx12.0" \
            -module-cache-path "$BUILD_DIR/swift-cache" \
            -module-name "$HELPER" \
            -o "$BUILD_DIR/$HELPER-$ARCH" "$ROOT_DIR/$HELPER.swift"
    done
    "$LIPO" -create "$BUILD_DIR/$HELPER-arm64" "$BUILD_DIR/$HELPER-x86_64" \
        -output "$STAGING_DIR/$HELPER"
    chmod 755 "$STAGING_DIR/$HELPER"
done

for SOURCE in manifest.json bootstrap.js quicklook.js prefs.js; do
    cp "$ROOT_DIR/$SOURCE" "$STAGING_DIR/$SOURCE"
    chmod 644 "$STAGING_DIR/$SOURCE"
done

# Normalize archive metadata and use an explicit file list for repeatable packages.
touch -t 202001010000 "$STAGING_DIR"/*
PACKAGE_NAME="zoteroquicklookmac-$VERSION.xpi"
(
    cd "$STAGING_DIR"
    /usr/bin/zip -X -q "$BUILD_DIR/$PACKAGE_NAME" \
        manifest.json bootstrap.js quicklook.js prefs.js contactsheet pdfpreview
)

# Publish outputs only after both helpers and the complete archive build successfully.
cp "$STAGING_DIR/contactsheet" "$ROOT_DIR/contactsheet"
cp "$STAGING_DIR/pdfpreview" "$ROOT_DIR/pdfpreview"
mv "$BUILD_DIR/$PACKAGE_NAME" "$ROOT_DIR/$PACKAGE_NAME"
echo "Built $ROOT_DIR/$PACKAGE_NAME"
