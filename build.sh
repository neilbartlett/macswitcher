#!/bin/bash

# Build script for Window Switcher

echo "🔨 Building Window Switcher..."

# Compile the Swift daemon
echo "Compiling WindowDaemon..."
swiftc -o windowdaemon WindowDaemon.swift

if [ $? -eq 0 ]; then
    echo "✅ WindowDaemon compiled successfully"
else
    echo "❌ Failed to compile WindowDaemon"
    exit 1
fi

# Make the shell script executable
echo "Setting up wswitch script..."
chmod +x wswitch

echo "✅ Build complete!"
echo
echo "Usage:"
echo "  ./wswitch                    # Interactive window switcher"
echo "  ./wswitch search <query>     # Search for windows"
echo "  ./wswitch list               # List recent windows"
echo
echo "First run will prompt for accessibility permissions."
echo "Make sure to enable them in System Preferences > Security & Privacy > Privacy > Accessibility"

