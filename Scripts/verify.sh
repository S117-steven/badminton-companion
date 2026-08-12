#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
verify_root=$(mktemp -d "${TMPDIR:-/tmp}/badminton-motion-verify.XXXXXX")

cd "$project_root"

module_cache="$verify_root/module-cache"
mkdir -p "$module_cache"

SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
CLANG_MODULE_CACHE_PATH="$module_cache" \
swift test \
  --disable-sandbox \
  --package-path Packages/BadmintonCore \
  --scratch-path "$verify_root/swiftpm-build" \
  --cache-path "$verify_root/swiftpm-cache" \
  --config-path "$verify_root/swiftpm-config" \
  --security-path "$verify_root/swiftpm-security"

SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
CLANG_MODULE_CACHE_PATH="$module_cache" \
xcodebuild \
  -quiet \
  -project BadmintonMotion.xcodeproj \
  -scheme BadmintonResearchiOS \
  -configuration Debug \
  -sdk iphonesimulator \
  -derivedDataPath "$verify_root/ios-derived" \
  -clonedSourcePackagesDirPath "$verify_root/ios-packages" \
  CODE_SIGNING_ALLOWED=NO \
  build

SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
CLANG_MODULE_CACHE_PATH="$module_cache" \
xcodebuild \
  -quiet \
  -project BadmintonMotion.xcodeproj \
  -scheme BadmintonResearchWatch \
  -configuration Debug \
  -sdk watchsimulator \
  -derivedDataPath "$verify_root/watch-derived" \
  -clonedSourcePackagesDirPath "$verify_root/watch-packages" \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "Verification succeeded. Build artifacts: $verify_root"
