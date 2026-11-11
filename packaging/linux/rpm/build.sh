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
  x64) RPMARCH=x86_64 ;;
  arm64) RPMARCH=aarch64 ;;
  arm32) RPMARCH=armv7hl ;;
  x86|i386) RPMARCH=i386 ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
[[ "$VERSION" =~ ^[0-9][A-Za-z0-9.+~]*$ ]] || { echo "Invalid version: $VERSION" >&2; exit 1; }
[ -f "$BINARY_PATH" ] || { echo "Local binary not found: $BINARY_PATH" >&2; exit 1; }
[ -f "$ICON_PATH" ] || { echo "Icon not found: $ICON_PATH" >&2; exit 1; }

BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/openrsat-rpm.XXXXXXXX")
trap 'rm -rf -- "$BUILD_DIR"' EXIT
mkdir -p "$BUILD_DIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
install -m 755 -- "$BINARY_PATH" "$BUILD_DIR/SOURCES/OpenRSAT"
install -m 644 -- "$ICON_PATH" "$BUILD_DIR/SOURCES/OpenRSAT.png"
install -m 644 -- "$SCRIPT_DIR/../OpenRSAT.desktop" "$BUILD_DIR/SOURCES/OpenRSAT.desktop"
install -m 644 -- "$REPO_DIR"/languages/OpenRSAT.*.po "$BUILD_DIR/SOURCES/"
# Windows checkouts may use CRLF; rpmbuild embeds %install in a shell script.
sed 's/\r$//' "$SCRIPT_DIR/OpenRSAT.spec" > "$BUILD_DIR/SPECS/OpenRSAT.spec"

rpmbuild -bb --buildroot "$BUILD_DIR/root" --define "_topdir $BUILD_DIR" \
  --define "_version $VERSION" --define "_rpmarch $RPMARCH" \
  --target "$RPMARCH" "$BUILD_DIR/SPECS/OpenRSAT.spec"
cp -- "$BUILD_DIR"/RPMS/*/*.rpm .
