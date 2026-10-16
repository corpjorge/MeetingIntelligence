#!/bin/zsh
# Runs the full test suite (Swift Testing).
#
# Root cause of a toolchain flake (Command Line Tools 27 + Swift 6.4): the build
# system sometimes omits `-external-plugin-path …/host/plugins/testing` for test
# targets, failing with "plugin for module 'TestingMacros' not found". With only
# CLT installed we always pass the Swift Testing macro plugin path explicitly.
set -uo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
EXTRA=()
DEV_DIR="$(xcode-select -p 2>/dev/null)"
TESTING_PLUGINS="$DEV_DIR/usr/lib/swift/host/plugins/testing"
if [[ "$DEV_DIR" == *CommandLineTools* && -d "$TESTING_PLUGINS" ]]; then
  EXTRA=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS")
fi
OUT="$("$ROOT/scripts/swiftw" build --build-tests "${EXTRA[@]}" 2>&1)"; STATUS=$?
if (( STATUS != 0 )); then
  print -r -- "$OUT" | sed -E $'s/\x1b\\[[0-9;]*m//g' | grep -E "error:" | grep -v "^ *|" | head -40
  exit $STATUS
fi
"$ROOT/scripts/swiftw" test --skip-build "${EXTRA[@]}" "$@" 2>&1 | grep -v "^\[Profiling\]" \
  | sed -E $'s/\x1b\\[[0-9;]*m//g' | grep -E "✔ Suite|✘|recorded an issue|Test run|skipped"
exit ${pipestatus[1]}
