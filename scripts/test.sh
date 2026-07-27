#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname "$script_dir")

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
"$swift_bin" test --disable-sandbox
