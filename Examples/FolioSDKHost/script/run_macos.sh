#!/bin/sh
set -eu

case "${1:-}" in
  ""|--prepare-only) ;;
  *) echo "Usage: $0 [--prepare-only]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [--prepare-only]" >&2
  exit 2
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_directory=$(CDPATH= cd -- "$script_directory/.." && pwd)
repository_directory=$(CDPATH= cd -- "$package_directory/../.." && pwd)
example_build_directory=${FOLIO_EXAMPLE_BUILD_DIR:-${TMPDIR:-/tmp}/FolioSDKHost-build}

case "$example_build_directory" in
  /*) ;;
  *) echo "FOLIO_EXAMPLE_BUILD_DIR must be an absolute path outside the repository." >&2; exit 2 ;;
esac
case "$example_build_directory/" in
  */../*|*/./*) echo "Build path must not contain dot components." >&2; exit 2 ;;
esac
# Resolve the nearest existing ancestor before mkdir, so a rejected source-tree
# destination does not leave a new directory behind, including through symlinks.
existing_ancestor=$example_build_directory
while [ ! -d "$existing_ancestor" ]; do
  existing_ancestor=$(dirname -- "$existing_ancestor")
done
existing_ancestor=$(CDPATH= cd -- "$existing_ancestor" && pwd -P)
case "$existing_ancestor/" in
  "$repository_directory/"*) echo "Build products must be outside the repository." >&2; exit 2 ;;
esac
mkdir -p "$example_build_directory"
example_build_directory=$(CDPATH= cd -- "$example_build_directory" && pwd -P)
case "$example_build_directory/" in
  "$repository_directory/"*) echo "Build products must be outside the repository." >&2; exit 2 ;;
esac

DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export DEVELOPER_DIR
xcrun swift build --package-path "$package_directory" --scratch-path "$example_build_directory" --product FolioSDKHost >&2
binary_directory=$(xcrun swift build --package-path "$package_directory" --scratch-path "$example_build_directory" --show-bin-path)

# Each invocation prepares a new app. Existing apps and libraries are never
# replaced or removed; the user may keep the generated app after this run.
app_directory=$(mktemp -d "${TMPDIR:-/tmp}/folio-sdk-host-app.XXXXXXXX")
app_path="$app_directory/FolioSDKHost.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_directory/FolioSDKHost" "$app_path/Contents/MacOS/FolioSDKHost"

# SwiftPM's Bundle.module searches Bundle.main.resourceURL when linked into an
# app. Preserve every resource bundle as generated; do not guess resource paths
# in Swift or inject development-only resource environment variables.
for resource_bundle in "$binary_directory"/*.bundle; do
  [ -d "$resource_bundle" ] || continue
  cp -R "$resource_bundle" "$app_path/Contents/Resources/"
done

cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.FolioSDKHost</string>
  <key>CFBundleName</key><string>FolioSDKHost</string>
  <key>CFBundleDisplayName</key><string>연구 자료함</string>
  <key>CFBundleExecutable</key><string>FolioSDKHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

printf '%s\n' "$app_path"
if [ "${1:-}" != --prepare-only ]; then
  open -n "$app_path"
fi
