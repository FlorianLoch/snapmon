#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname "$script_dir")
configuration=${CONFIGURATION:-release}
app_name="Snapmaker Monitor"
bundle_dir="$project_dir/build/$app_name.app"
contents_dir="$bundle_dir/Contents"
macos_dir="$contents_dir/MacOS"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    export DEVELOPER_DIR
fi

swift_bin=$(xcrun --find swift)
module_cache_dir="$project_dir/.build/module-cache"
mkdir -p "$module_cache_dir"
CLANG_MODULE_CACHE_PATH="$module_cache_dir/clang"
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache_dir/swiftpm"
export CLANG_MODULE_CACHE_PATH SWIFTPM_MODULECACHE_OVERRIDE

cd "$project_dir"
"$swift_bin" build --disable-sandbox -c "$configuration" --product SnapmakerMonitor
bin_dir=$("$swift_bin" build --disable-sandbox -c "$configuration" --show-bin-path)

mkdir -p "$macos_dir"
cp "$bin_dir/SnapmakerMonitor" "$macos_dir/SnapmakerMonitor"
cp "$project_dir/Config/Info.plist" "$contents_dir/Info.plist"

codesign \
    --force \
    --sign - \
    --entitlements "$project_dir/Config/SnapmakerMonitor.entitlements" \
    "$bundle_dir"

printf '%s\n' "$bundle_dir"
