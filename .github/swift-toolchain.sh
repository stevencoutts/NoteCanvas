#!/bin/bash
# Package.swift is swift-tools-version 6.0, compiled in Swift 5 language mode.
# The macOS 26 runner's stable Xcode (26.6, Swift 6.3) can build that.
# If the selected compiler is older than Swift 6, install Swift 6.4 instead of
# lowering the tools version.
set -euo pipefail

if [ -d /Applications/Xcode_26.6.app ]; then
  sudo xcode-select -s /Applications/Xcode_26.6.app
fi

swift --version
major=$(swift --version | sed -n 's/.*Swift version \([0-9][0-9]*\)\..*/\1/p' | head -1)
if [ "${major:-0}" -ge 6 ]; then
  exit 0
fi

echo "Selected Swift is older than 6. Installing Swift 6.4.0."
workdir=$(mktemp -d)
curl -fsSL -o "$workdir/swiftly.pkg" https://download.swift.org/swiftly/darwin/swiftly.pkg
installer -pkg "$workdir/swiftly.pkg" -target CurrentUserHomeDirectory
"$HOME/.swiftly/bin/swiftly" init --assume-yes --quiet-shell-followup --skip-install
# shellcheck disable=SC1091
. "${SWIFTLY_HOME_DIR:-$HOME/.swiftly}/env.sh"
swiftly install --assume-yes --use 6.4.0
hash -r
swift --version
major=$(swift --version | sed -n 's/.*Swift version \([0-9][0-9]*\)\..*/\1/p' | head -1)
test "${major:-0}" -ge 6
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "${SWIFTLY_BIN_DIR:-$HOME/.swiftly/bin}" >> "$GITHUB_PATH"
fi
