#!/usr/bin/env bash
# One-time setup for contributors: generates the Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen generate

echo "Generated BuzzClient.xcodeproj — open it, or run: make build"
echo "For device builds, copy Config/Local.xcconfig.example to Config/Local.xcconfig and set your team ID."
