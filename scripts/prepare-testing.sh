#!/usr/bin/env bash
# Makes swift-testing loadable when only Command Line Tools are installed.
#
# CLT ships Testing.framework and lib_TestingInterop.dylib, but not where dyld
# looks, and DYLD_FRAMEWORK_PATH is stripped from the SIP-protected
# swiftpm-testing-helper that loads the test bundle. Staging both onto an rpath
# the bundle already searches fixes the load.
#
# The framework must land *inside* the .xctest bundle rather than in
# PackageFrameworks: the latter is also a compiler framework search path, and a
# copy there shadows the real one in a way that breaks macro plugin resolution,
# so @Test and #expect stop compiling.
#
# Run this after `swift build --build-tests` and before `swift test`. It is
# harmless when a full Xcode is selected.
set -euo pipefail

CONFIGURATION="${1:-Debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCTS="$ROOT/.build/out/Products/$CONFIGURATION"

DEVELOPER_DIR="$(xcode-select -p)"
FRAMEWORK="$DEVELOPER_DIR/Library/Developer/Frameworks/Testing.framework"
INTEROP="$DEVELOPER_DIR/Library/Developer/usr/lib/lib_TestingInterop.dylib"

if [[ ! -d "$FRAMEWORK" ]]; then
  echo "prepare-testing: no Testing.framework under $DEVELOPER_DIR; nothing to stage."
  exit 0
fi

shopt -s nullglob
bundles=("$PRODUCTS"/*.xctest)
if [[ ${#bundles[@]} -eq 0 ]]; then
  echo "prepare-testing: no .xctest bundle in $PRODUCTS; run 'swift build --build-tests' first." >&2
  exit 1
fi

for bundle in "${bundles[@]}"; do
  destination="$bundle/Contents/MacOS"
  mkdir -p "$destination"
  rm -rf "$destination/Testing.framework"
  cp -R "$FRAMEWORK" "$destination/"
  [[ -f "$INTEROP" ]] && cp -f "$INTEROP" "$destination/"
  echo "prepare-testing: staged swift-testing runtime into $(basename "$bundle")"
done

# The bundle also resolves @rpath against the products directory.
[[ -f "$INTEROP" ]] && cp -f "$INTEROP" "$PRODUCTS/"
exit 0
