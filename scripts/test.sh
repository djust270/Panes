#!/bin/zsh
# Runs the test suite. Extra arguments are passed to `swift test`.
#
# With full Xcode this is just `swift test`. With only the Command Line Tools,
# Swift Testing lives outside the default search path and its Foundation
# cross-import overlay ships without module files, so we add the framework
# path and disable cross-import overlays.
#
# Performance tests: EXPLORER_PERF_TESTS=1 scripts/test.sh
set -euo pipefail
cd "${0:A:h}/.."

developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == *CommandLineTools* ]]; then
    frameworks="$developer_dir/Library/Developer/Frameworks"
    exec swift test \
        -Xswiftc -F -Xswiftc "$frameworks" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -F -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$frameworks" \
        "$@"
else
    exec swift test "$@"
fi
