#!/bin/zsh
# Runs SwiftLint. Extra arguments are passed through (e.g. --fix).
#
# With only the Command Line Tools installed, SwiftLint can't locate SourceKit
# on its own, so point it at the active toolchain.
set -euo pipefail
cd "${0:A:h}/.."

developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == *CommandLineTools* && -z "${TOOLCHAIN_DIR:-}" ]]; then
    export TOOLCHAIN_DIR="$developer_dir"
fi
exec swiftlint --strict "$@"
