#!/bin/bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Usage: $0 <VERSION> <ARCH:x64,arm64,arm32,x86> <ICON_PATH> <BINARY_PATH>" >&2
  exit 1
fi

VERSION=$1
ARCH=$2
ICON_PATH=$3
BINARY_PATH=$4
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/../../.." && pwd)

case "$ARCH" in
  x64) DEBARCH=amd64 ;;
  arm64) DEBARCH=arm64 ;;
  arm32) DEBARCH=armhf ;;
  x86|i386) DEBARCH=i386 ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
[[ "$VERSION" =~ ^[0-9][A-Za-z0-9.+~]*$ ]] || { echo "Invalid version: $VERSION" >&2; exit 1; }
[ -f "$BINARY_PATH" ] || { echo "Local binary not found: $BINARY_PATH" >&2; exit 1; }
[ -f "$ICON_PATH" ] || { echo "Icon not found: $ICON_PATH" >&2; exit 1; }

BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/openrsat-deb.XXXXXXXX")
trap 'rm -rf -- "$BUILD_DIR"' EXIT
mkdir -p "$BUILD_DIR/DEBIAN" "$BUILD_DIR/opt/openrsat" \
  "$BUILD_DIR/usr/share/applications" "$BUILD_DIR/usr/share/openrsat/locale"

sed -e "s/VERSION/$VERSION/" -e "s/^Architecture:.*/Architecture: $DEBARCH/" \
  "$SCRIPT_DIR/control" > "$BUILD_DIR/DEBIAN/control"
# Keep maintainer scripts executable when packaging a Windows checkout in WSL.
sed 's/\r$//' "$SCRIPT_DIR/postinst" > "$BUILD_DIR/DEBIAN/postinst"
chmod 755 "$BUILD_DIR/DEBIAN/postinst"
install -m 755 -- "$BINARY_PATH" "$BUILD_DIR/opt/openrsat/OpenRSAT"
install -m 644 -- "$ICON_PATH" "$BUILD_DIR/opt/openrsat/OpenRSAT.png"
install -m 644 -- "$SCRIPT_DIR/../OpenRSAT.desktop" "$BUILD_DIR/usr/share/applications/"
install -m 644 -- "$REPO_DIR"/languages/OpenRSAT.*.po "$BUILD_DIR/usr/share/openrsat/locale/"

dpkg-deb --root-owner-group --build "$BUILD_DIR" "OpenRSAT-${VERSION}-${DEBARCH}.deb"
