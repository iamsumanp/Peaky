#!/bin/zsh
# Preview a Peaky state: expand | shelf | collapse | volume | brightness | charging | airpods
# Only works with a debug build: PEAKY_DEBUG=1 ./build.sh
swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(.init(\"io.github.iamsumanp.peaky.debug\"), object: \"$1\", deliverImmediately: true)"
