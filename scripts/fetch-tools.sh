#!/bin/zsh
# Downloads ExifTool 13.59 (the version ExifCleaner 4.7 bundles), checks it against its published
# SHA-256 and unpacks the Perl script and its library in vendor/exiftool (not in the repository).
# build-app.sh copies it into Contents/Resources/exiftool; it runs on macOS's /usr/bin/perl.
#   scripts/fetch-tools.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="13.59"
SHA256="668ea3acececb7235fbd0f4900e72d5f12c9b07e5c778fd36cb1e9b5828fd65a"
DL="vendor/downloads"; mkdir -p "$DL"
TAR="$DL/Image-ExifTool-$VERSION.tar.gz"
if [[ ! -f "$TAR" ]]; then
    # exiftool.org keeps only the latest release; older ones live on SourceForge.
    curl -fsSL -o "$TAR" "https://exiftool.org/Image-ExifTool-$VERSION.tar.gz" ||
        curl -fsSL -o "$TAR" "https://downloads.sourceforge.net/project/exiftool/Image-ExifTool-$VERSION.tar.gz"
fi
got=$(shasum -a 256 "$TAR" | cut -d' ' -f1)
if [[ "$got" != "$SHA256" ]]; then echo "error: checksum mismatch for $TAR" >&2; rm -f "$TAR"; exit 1; fi

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
tar -xzf "$TAR" -C "$WORK"
rm -rf vendor/exiftool; mkdir -p vendor/exiftool
cp "$WORK/Image-ExifTool-$VERSION/exiftool" vendor/exiftool/
cp -R "$WORK/Image-ExifTool-$VERSION/lib" vendor/exiftool/
chmod +x vendor/exiftool/exiftool
xattr -cr vendor/exiftool
echo "ExifTool ready in vendor/exiftool: $(vendor/exiftool/exiftool -ver)"
