#!/bin/bash

# Exit on error
set -e

echo "🔨 Building Echo from source..."

# Create directory structure for app bundle
APP_DIR="Echo.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy raw assets to Resources
echo "📦 Copying assets..."

# Copy mp3s, pngs, and icns icons
cp echo/*.mp3 "$RESOURCES_DIR/" || true
cp echo/*.png "$RESOURCES_DIR/" || true
cp echo/*.jpg "$RESOURCES_DIR/" || true
cp echo/*.icns "$RESOURCES_DIR/" || true

# Copy images from Assets.xcassets (flattening the directory structure)
find echo/Assets.xcassets -type f \( -name "*.png" -o -name "*.jpg" \) -exec cp {} "$RESOURCES_DIR/" \;

# Compile Swift files
echo "🚀 Compiling swift files..."
cd echo
swiftc -sdk "$(xcrun --show-sdk-path)" -module-cache-path ../module-cache -o "../$MACOS_DIR/Echo" \
    *.swift \
    -framework SwiftUI \
    -framework AppKit \
    -framework AVFoundation \
    -framework ScreenCaptureKit \
    -framework CoreGraphics \
    -framework Foundation \
    -framework Combine \
    -framework CoreServices

cd ..

# Create Info.plist
cat <<EOF > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Echo</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.echo.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Echo</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>VoiceTranscriptionProvider</key>
    <string>applespeech</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Echo needs microphone access to record your voice instructions.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Echo needs speech recognition permission to transcribe your voice instructions offline.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Echo needs screen recording permission to take screenshots of your screen.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Echo needs access to your Desktop folder to open and manage folders for you.</string>
</dict>
</plist>
EOF

# Copy .env file
if [ -f "echo/.env" ]; then
    cp "echo/.env" "$MACOS_DIR/.env"
fi

# Codesign the app bundle ad-hoc with entitlements
echo "🔑 Codesigning Echo.app..."
codesign --force --deep --sign - --entitlements echo/echo.entitlements "$APP_DIR"

echo "✅ Build Complete: Echo.app created successfully!"
echo "🚀 Run with: open Echo.app"

