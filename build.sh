#!/bin/bash
# rebuild + reinstall: bash build.sh
cd "$(dirname "$0")"
swiftc -O -o AgentAwake main.swift -framework AppKit
mkdir -p ~/Applications/AgentAwake.app/Contents/MacOS
cp AgentAwake ~/Applications/AgentAwake.app/Contents/MacOS/
echo "installed — open ~/Applications/AgentAwake.app"
