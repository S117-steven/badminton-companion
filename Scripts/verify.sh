#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
verify_root=$(mktemp -d "${TMPDIR:-/tmp}/badminton-motion-verify.XXXXXX")

cd "$project_root"

python3 -m unittest discover -s Scripts/tests -v

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
  -scheme BadmintonProductiOS \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$verify_root/product-ios-derived" \
  -clonedSourcePackagesDirPath "$verify_root/product-ios-packages" \
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

SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
CLANG_MODULE_CACHE_PATH="$module_cache" \
xcodebuild \
  -quiet \
  -project BadmintonMotion.xcodeproj \
  -scheme BadmintonProductWatch \
  -configuration Debug \
  -sdk watchsimulator \
  -derivedDataPath "$verify_root/product-watch-derived" \
  -clonedSourcePackagesDirPath "$verify_root/product-watch-packages" \
  CODE_SIGNING_ALLOWED=NO \
  build

embedded_watch_info="$verify_root/product-ios-derived/Build/Products/Debug-iphonesimulator/Badminton.app/Watch/BadmintonWatch.app/Info.plist"
if [ ! -f "$embedded_watch_info" ]; then
  echo "Product iOS app does not embed its Watch companion app." >&2
  exit 1
fi

companion_identifier=$(
  plutil -extract WKCompanionAppBundleIdentifier raw -o - "$embedded_watch_info"
)
if [ "$companion_identifier" != "com.example.badmintonmotion" ]; then
  echo "Product Watch app points at the wrong iOS companion identifier." >&2
  exit 1
fi

product_watch_info="$verify_root/product-watch-derived/Build/Products/Debug-watchsimulator/BadmintonWatch.app/Info.plist"
background_mode=$(plutil -extract WKBackgroundModes.0 raw -o - "$product_watch_info")
if [ "$background_mode" != "workout-processing" ]; then
  echo "Product Watch app is missing workout-processing background mode." >&2
  exit 1
fi

health_read_usage=$(plutil -extract NSHealthShareUsageDescription raw -o - "$product_watch_info")
health_write_usage=$(plutil -extract NSHealthUpdateUsageDescription raw -o - "$product_watch_info")
if [ -z "$health_read_usage" ] || [ -z "$health_write_usage" ]; then
  echo "Product Watch app is missing a HealthKit usage description." >&2
  exit 1
fi

healthkit_entitlement=$(
  plutil -extract 'com\.apple\.developer\.healthkit' raw -o - \
    "$project_root/Config/BadmintonWatch.entitlements"
)
if [ "$healthkit_entitlement" != "true" ]; then
  echo "Product Watch app is missing the HealthKit entitlement." >&2
  exit 1
fi

echo "Verification succeeded. Build artifacts: $verify_root"
