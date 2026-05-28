#!/bin/bash

# Exit on error
set -e

# ANSI escape codes for beautiful output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Clicky Command-Line Build & Run Helper ===${NC}"

# 1. Check if Xcode is installed and active
DEVELOPER_DIR=$(xcode-select -p 2>/dev/null || echo "")

if [ -z "$DEVELOPER_DIR" ]; then
    echo -e "${RED}❌ Xcode Command Line Tools are not configured/installed.${NC}"
    echo -e "Please install the command line tools using: ${YELLOW}xcode-select --install${NC}"
    exit 1
fi

# Check if we have the full Xcode or just the CommandLineTools
if [[ "$DEVELOPER_DIR" == *CommandLineTools* ]]; then
    echo -e "${YELLOW}⚠️  Active developer directory is set to Command Line Tools: $DEVELOPER_DIR${NC}"
    echo -e "SwiftUI / AppKit macOS GUI apps require the full Xcode SDK to compile."
    echo -e "Please check if Xcode is installed under /Applications/Xcode.app"
    echo -e "If it is installed, set the active directory with:"
    echo -e "  ${BLUE}sudo xcode-select -s /Applications/Xcode.app/Contents/Developer${NC}"
    
    # Try to check if Xcode.app exists anywhere standard
    if [ -d "/Applications/Xcode.app" ]; then
        echo -e "\n${GREEN}Found Xcode at /Applications/Xcode.app! Let's try running with Xcode's compiler direct path...${NC}"
        XCODEBUILD_PATH="/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
    else
        echo -e "\n${RED}❌ Xcode application was not found in /Applications/Xcode.app${NC}"
        echo -e "To compile this macOS application, you must install the full Xcode (from the App Store or developer.apple.com)."
        exit 1
    fi
else
    XCODEBUILD_PATH="xcodebuild"
fi

# 2. Build the project in Debug mode
echo -e "${BLUE}📦 Resolving package dependencies and compiling the app...${NC}"
rm -rf build

if ! "$XCODEBUILD_PATH" -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Debug -derivedDataPath build; then
    echo -e "${RED}❌ Build failed!${NC}"
    exit 1
fi

# 3. Launch the app
APP_PATH="build/Build/Products/Debug/leanring-buddy.app"

if [ -d "$APP_PATH" ]; then
    echo -e "${GREEN}✅ Build successful!${NC}"
    
    # Codesign the app bundle ad-hoc with entitlements to prevent TCC permission issues
    echo -e "${BLUE}🔑 Codesigning app bundle...${NC}"
    codesign --force --deep --sign - --entitlements leanring-buddy/leanring-buddy.entitlements "$APP_PATH"
    
    echo -e "${BLUE}🚀 Launching Clicky in the menu bar...${NC}"
    
    # Open the app bundle
    open "$APP_PATH"
    
    echo -e "${GREEN}🎉 Clicky is now running! Look for the Clicky icon in your macOS menu bar.${NC}"
    echo -e "${YELLOW}Note: Since the app runs in the status bar (no dock icon/main window), it lives entirely in the menu bar.${NC}"
else
    echo -e "${RED}❌ Built app binary not found at $APP_PATH${NC}"
    exit 1
fi
