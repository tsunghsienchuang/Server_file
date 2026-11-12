#!/bin/bash
set -euo pipefail
umask 022

repo_dir=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sources="$repo_dir/Sources"
dist="$repo_dir/dist"
go_bin=${GO_BIN:-go}

if ! command -v "$go_bin" >/dev/null; then
    printf 'Install Go to build Server Files for Windows.\n' >&2
    exit 1
fi

version=$(python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["CFBundleShortVersionString"])' \
    "$repo_dir/Resources/Info.plist")
staging=$(mktemp -d "${TMPDIR:-/tmp}/server-files-windows.XXXXXX")
trap 'rm -rf "$staging"' EXIT
mkdir -p "$dist" "$staging/source"
cp "$sources/windows/"*.go "$sources/windows/go.mod" "$sources/preview_server.py" "$staging/source/"

(
    cd "$staging/source"
    export CGO_ENABLED=0 GOTOOLCHAIN=local
    if [[ "${1:-}" == --test ]]; then
        "$go_bin" test ./...
        exit
    fi
    for target in amd64:x64 arm64:arm64; do
        arch=${target%:*}
        label=${target#*:}
        zip_name="Server-Files-${version}-Windows-${label}.zip"
        GOOS=windows GOARCH="$arch" "$go_bin" build -trimpath -ldflags="-s -w -buildid= -X main.version=$version" \
            -o "$staging/ServerFiles.exe" .
        python3 -m zipfile -c "$staging/$zip_name" "$staging/ServerFiles.exe"
        mv -f "$staging/$zip_name" "$dist/$zip_name"
        printf 'Built %s\n' "$dist/$zip_name"
    done
)

if [[ "${1:-}" != --test ]]; then
    python3 - "$dist" "$version" <<'PY'
import hashlib
from pathlib import Path
import sys

dist, version = Path(sys.argv[1]), sys.argv[2]
prefix = f"Server-Files-{version}-"
paths = [dist / f"{prefix}{platform}.zip" for platform in (
    "macOS-universal", "Windows-x64", "Windows-arm64",
)]
checksums = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
                    for path in paths if path.is_file())
(dist / "SHA256SUMS").write_text(checksums, encoding="ascii", newline="\n")
PY
fi
