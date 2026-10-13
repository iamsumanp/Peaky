#!/bin/zsh
# Preview a Peaky state: expand | shelf | collapse | volume | brightness | charging | airpods
swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(.init(\"io.github.iamsumanp.peaky.debug\"), object: \"$1\", deliverImmediately: true)"
