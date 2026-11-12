#!/bin/bash
set -euo pipefail
umask 022

repo_dir=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sources="$repo_dir/Sources"
resources="$repo_dir/Resources"
dist="$repo_dir/dist"
info="$resources/Info.plist"

for input in "$sources/ServerFiles.swift" "$sources/ServerFilesPreview.command" \
    "$sources/preview_server.py" "$info" "$resources/ServerFiles.icns"; do
    if [[ ! -f "$input" || ! -r "$input" ]]; then
        printf 'Missing build input: %s\n' "$input" >&2
        exit 1
    fi
done

if ! /usr/bin/xcrun --find swiftc >/dev/null; then
    printf 'Install the Xcode Command Line Tools to build Server Files.\n' >&2
    exit 1
fi

/usr/bin/plutil -lint "$info"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
minimum_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info")
sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
zip_name="Server-Files-${version}-macOS-universal.zip"

mkdir -p "$dist"
# Sign away from synced directories, which can add Finder metadata to the bundle.
staging=$(mktemp -d /private/tmp/server-files-build.XXXXXX)
trap 'rm -rf "$staging"' EXIT
app="$staging/Server Files.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"

for arch in arm64 x86_64; do
    /usr/bin/xcrun --sdk macosx swiftc \
        -target "${arch}-apple-macos${minimum_macos}" -sdk "$sdk" \
        -module-cache-path "$staging/cache-$arch" -file-prefix-map "$repo_dir=." \
        -parse-as-library -O \
        "$sources/ServerFiles.swift" -o "$staging/ServerFiles-$arch"
done

/usr/bin/xcrun --sdk macosx lipo -create \
    "$staging/ServerFiles-arm64" "$staging/ServerFiles-x86_64" \
    -output "$contents/MacOS/ServerFiles"
/usr/bin/xcrun --sdk macosx lipo "$contents/MacOS/ServerFiles" -verify_arch arm64 x86_64

/bin/cp -X "$info" "$contents/Info.plist"
/bin/cp -X "$resources/ServerFiles.icns" "$sources/ServerFilesPreview.command" \
    "$sources/preview_server.py" "$contents/Resources/"
chmod 755 "$contents/MacOS/ServerFiles" "$contents/Resources/ServerFilesPreview.command"
chmod 644 "$contents/Info.plist" "$contents/Resources/ServerFiles.icns" "$contents/Resources/preview_server.py"

/usr/bin/codesign --force --sign - --timestamp=none "$app"
/usr/bin/codesign --verify --strict --all-architectures "$app"
/usr/bin/ditto -c -k --norsrc --keepParent "$app" "$staging/$zip_name"
(
    cd "$staging"
    /usr/bin/shasum -a 256 "$zip_name" > SHA256SUMS
)

rm -rf "$dist/Server Files.app"
mv "$app" "$dist/Server Files.app"
mv -f "$staging/$zip_name" "$staging/SHA256SUMS" "$dist/"
printf 'Built %s\n' "$dist/Server Files.app" "$dist/$zip_name" "$dist/SHA256SUMS"
