#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname "$script_dir")
configuration=${CONFIGURATION:-release}
app_name="SnapMon"
build_dir="$project_dir/build"
bundle_dir="$project_dir/build/$app_name.app"
info_plist="$project_dir/Config/Info.plist"
icon_source="$project_dir/Resources/snapmon.icon"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    export DEVELOPER_DIR
fi

swift_bin=$(xcrun --find swift)
if ! actool_bin=$(xcrun --find actool 2>/dev/null); then
    printf '%s\n' "Xcode 26 or later is required to compile $icon_source." >&2
    exit 1
fi

bundle_identifier=$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")
minimum_deployment_target=$(plutil -extract LSMinimumSystemVersion raw -o - "$info_plist")
module_cache_dir="$project_dir/.build/module-cache"
mkdir -p "$module_cache_dir"
CLANG_MODULE_CACHE_PATH="$module_cache_dir/clang"
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache_dir/swiftpm"
export CLANG_MODULE_CACHE_PATH SWIFTPM_MODULECACHE_OVERRIDE

cd "$project_dir"
"$swift_bin" build --disable-sandbox -c "$configuration" --product SnapMon
bin_dir=$("$swift_bin" build --disable-sandbox -c "$configuration" --show-bin-path)

mkdir -p "$build_dir"
staging_dir=$(mktemp -d "$build_dir/.snapmon-build.XXXXXX")
staging_bundle="$staging_dir/$app_name.app"
contents_dir="$staging_bundle/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
icon_info_plist="$staging_dir/assetcatalog-generated-info.plist"
previous_bundle="$staging_dir/previous.app"

cleanup() {
    rm -rf "$staging_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$macos_dir" "$resources_dir"
"$actool_bin" \
    --compile "$resources_dir" \
    --output-format human-readable-text \
    --notices \
    --warnings \
    --output-partial-info-plist "$icon_info_plist" \
    --app-icon snapmon \
    --standalone-icon-behavior all \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target "$minimum_deployment_target" \
    --bundle-identifier "$bundle_identifier" \
    "$icon_source"

cp "$bin_dir/SnapMon" "$macos_dir/SnapMon"
cp "$info_plist" "$contents_dir/Info.plist"

icon_file=$(plutil -extract CFBundleIconFile raw -o - "$icon_info_plist")
icon_name=$(plutil -extract CFBundleIconName raw -o - "$icon_info_plist")
plutil -insert CFBundleIconFile -string "$icon_file" "$contents_dir/Info.plist"
plutil -insert CFBundleIconName -string "$icon_name" "$contents_dir/Info.plist"

codesign \
    --force \
    --sign - \
    --entitlements "$project_dir/Config/SnapMon.entitlements" \
    "$staging_bundle"

if [ -e "$bundle_dir" ]; then
    mv "$bundle_dir" "$previous_bundle"
fi

if ! mv "$staging_bundle" "$bundle_dir"; then
    if [ -e "$previous_bundle" ]; then
        mv "$previous_bundle" "$bundle_dir"
    fi
    exit 1
fi

printf '%s\n' "$bundle_dir"
