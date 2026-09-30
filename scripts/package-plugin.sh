#!/bin/sh
# Build an installable source archive without reusing stale archive entries.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_dir="$root/plugin/googlephotos.koplugin"
output_dir="$root/dist"

command -v zip >/dev/null 2>&1 || {
    printf '%s\n' 'zip is required to package the plugin.' >&2
    exit 1
}
for required in main.lua _meta.lua; do
    test -f "$source_dir/$required" || {
        printf 'Missing plugin entry point: %s\n' "$required" >&2
        exit 1
    }
done

mkdir -p "$output_dir"
stage=$(mktemp -d "$output_dir/.package.XXXXXXXX")
trap 'rm -f "$stage/googlephotos.koplugin.zip"; rmdir "$stage"' EXIT HUP INT TERM

# Only source and accompanying documentation belong in the installation zip.
# Runtime state, credentials, hidden files, and specs are never packaged.
(
    cd "$root/plugin"
    zip -q -r "$stage/googlephotos.koplugin.zip" googlephotos.koplugin \
        -i '*.lua' '*.md' '*/LICENSE' '*/LICENSE.txt' \
        -x '*/.*' '*/spec/*' '*/test/*' '*/tests/*'
)
mv "$stage/googlephotos.koplugin.zip" "$output_dir/googlephotos.koplugin.zip"
printf 'Plugin archive: %s\n' "$output_dir/googlephotos.koplugin.zip"
