#!/bin/bash
set -e

PNG_PATH="/Users/adityagupta/Desktop/KURSOR/clicky-main/echo/echo_app_icon.png"
ICONSET_DIR="/Users/adityagupta/Desktop/KURSOR/clicky-main/echo/AppIcon.iconset"
ICNS_PATH="/Users/adityagupta/Desktop/KURSOR/clicky-main/echo/AppIcon.icns"
APPICONSET_DIR="/Users/adityagupta/Desktop/KURSOR/clicky-main/echo/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$PNG_PATH" ]; then
    echo "❌ echo_app_icon.png not found in echo/ folder!"
    exit 1
fi

echo "📦 Creating macOS AppIcon.icns from custom cursor icon..."
mkdir -p "$ICONSET_DIR"

sips -z 16 16 "$PNG_PATH" --out "$ICONSET_DIR/icon_16x16.png"
sips -z 32 32 "$PNG_PATH" --out "$ICONSET_DIR/icon_16x16@2x.png"
sips -z 32 32 "$PNG_PATH" --out "$ICONSET_DIR/icon_32x32.png"
sips -z 64 64 "$PNG_PATH" --out "$ICONSET_DIR/icon_32x32@2x.png"
sips -z 128 128 "$PNG_PATH" --out "$ICONSET_DIR/icon_128x128.png"
sips -z 256 256 "$PNG_PATH" --out "$ICONSET_DIR/icon_128x128@2x.png"
sips -z 256 256 "$PNG_PATH" --out "$ICONSET_DIR/icon_256x256.png"
sips -z 512 512 "$PNG_PATH" --out "$ICONSET_DIR/icon_256x256@2x.png"
sips -z 512 512 "$PNG_PATH" --out "$ICONSET_DIR/icon_512x512.png"
sips -z 1024 1024 "$PNG_PATH" --out "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR"
rm -rf "$ICONSET_DIR"

echo "✅ AppIcon.icns compiled successfully at: $ICNS_PATH"

if [ -d "$APPICONSET_DIR" ]; then
    echo "📦 Overwriting Assets.xcassets AppIcon.appiconset PNGs..."
    sips -z 16 16 "$PNG_PATH" --out "$APPICONSET_DIR/16-mac.png"
    sips -z 32 32 "$PNG_PATH" --out "$APPICONSET_DIR/32-mac.png"
    sips -z 64 64 "$PNG_PATH" --out "$APPICONSET_DIR/64-mac.png"
    sips -z 128 128 "$PNG_PATH" --out "$APPICONSET_DIR/128-mac.png"
    sips -z 256 256 "$PNG_PATH" --out "$APPICONSET_DIR/256-mac.png"
    sips -z 512 512 "$PNG_PATH" --out "$APPICONSET_DIR/512-mac.png"
    sips -z 1024 1024 "$PNG_PATH" --out "$APPICONSET_DIR/1024-mac.png"
    echo "✅ AppIcon.appiconset PNG files updated successfully!"
else
    echo "⚠️  AppIcon.appiconset directory not found at $APPICONSET_DIR"
fi

