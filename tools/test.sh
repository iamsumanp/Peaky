#!/bin/zsh
# Runs the test suite (Tests/PeakyTests).  Usage: tools/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ARGS=()
# With only the Command Line Tools (no Xcode), Swift Testing lives outside the default search paths and its
# Foundation overlay is missing, so point at it and skip the overlay.
if [[ $(xcode-select -p) == *CommandLineTools* ]]; then
  F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
  ARGS=(-Xswiftc -F$F -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
        -Xlinker -F$F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L)
fi
swift test $ARGS 2>&1 | grep -E "✔|✘|error:|passed|failed|Expectation" || true
