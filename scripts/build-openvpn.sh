#!/bin/sh
# Builds the VPN engine the app carries: OpenVPN 2.7.8, with OpenSSL 3.5, LZ4 and LZO linked in
# statically, for arm64 and x86_64, into .build/openvpn/ (openvpn, dns-updown, licences).
# assemble-app.sh puts them in the app when they are there; without them the app has no VPN.
# The sources are downloaded once into .build/openvpn-src and checked against the SHA-256 sums
# below (OpenVPN's tarball is also signed: openvpn-2.7.8.tar.gz.asc, key F554A3687412CFFEBDEFE0A312F5F7B42F2B01E7).
#   scripts/build-openvpn.sh
#
# OpenVPN runs as root, so nothing it loads may come from a folder a user can write:
# - OpenVPN is built with the helper's install folder as its script folder, so the only script
#   it runs (dns-updown, which sets DNS) is the root-owned copy installed beside it;
# - OpenSSL's own folders (openssl.cnf, modules, engines) point into that root-owned folder too,
#   where nothing is installed, and OpenSSL is built without loading code at run time.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/openvpn"
SRC="$ROOT/.build/openvpn-src"
# VPNPaths.installDir in Sources/VPNCore/VPNPaths.swift.
INSTALL_DIR="/Library/PrivilegedHelperTools/info.ankeshshiv.notch.vpn"
MIN_MACOS="15.0"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

OPENVPN=2.7.8
OPENVPN_SHA=c070d1d2440b5a6fca6c2c68645c98cd492116ac36ef4f0946177115532c8e36
OPENSSL=3.5.9
OPENSSL_SHA=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
LZ4=1.10.0
LZ4_SHA=537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b
LZO=2.10
LZO_SHA=c0f892943208266f9b6543b3ae308fab6284c5c90e627931446fb49b4221a072

mkdir -p "$SRC" "$OUT"

fetch() {
  file="$SRC/$1"
  if [ ! -f "$file" ]; then
    echo "Downloading $1"
    curl -fsSL -o "$file.part" "$2"
    mv "$file.part" "$file"
  fi
  if ! echo "$3  $file" | shasum -a 256 -c - >/dev/null 2>&1; then
    echo "$1 does not match its SHA-256; deleted, run again to download it again." >&2
    rm -f "$file"
    exit 1
  fi
}

fetch "openvpn-$OPENVPN.tar.gz" "https://github.com/OpenVPN/openvpn/releases/download/v$OPENVPN/openvpn-$OPENVPN.tar.gz" "$OPENVPN_SHA"
fetch "openssl-$OPENSSL.tar.gz" "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL/openssl-$OPENSSL.tar.gz" "$OPENSSL_SHA"
fetch "lz4-$LZ4.tar.gz" "https://github.com/lz4/lz4/releases/download/v$LZ4/lz4-$LZ4.tar.gz" "$LZ4_SHA"
fetch "lzo-$LZO.tar.gz" "https://www.oberhumer.com/opensource/lzo/download/lzo-$LZO.tar.gz" "$LZO_SHA"

build_arch() {
  arch="$1"
  case "$arch" in
    arm64) host=aarch64-apple-darwin ;;
    x86_64) host=x86_64-apple-darwin ;;
  esac
  work="$SRC/build-$arch"
  prefix="$work/prefix"
  rm -rf "$work"
  mkdir -p "$prefix/lib" "$prefix/include"
  cc="clang -arch $arch -mmacosx-version-min=$MIN_MACOS"

  echo "[$arch] OpenSSL $OPENSSL"
  tar xzf "$SRC/openssl-$OPENSSL.tar.gz" -C "$work"
  (
    cd "$work/openssl-$OPENSSL"
    ./Configure "darwin64-$arch-cc" no-shared no-dso no-engine no-module no-tests no-docs no-apps \
      --prefix="$prefix" --libdir=lib --openssldir="$INSTALL_DIR/ssl" "-mmacosx-version-min=$MIN_MACOS" >/dev/null
    make -j"$JOBS" build_libs >/dev/null
    make install_dev >/dev/null
  )

  echo "[$arch] LZ4 $LZ4"
  tar xzf "$SRC/lz4-$LZ4.tar.gz" -C "$work"
  make -C "$work/lz4-$LZ4/lib" -j"$JOBS" liblz4.a CC="$cc" CFLAGS="-O2" >/dev/null
  cp "$work/lz4-$LZ4/lib/liblz4.a" "$prefix/lib/"
  cp "$work/lz4-$LZ4/lib/lz4.h" "$work/lz4-$LZ4/lib/lz4hc.h" "$work/lz4-$LZ4/lib/lz4frame.h" "$prefix/include/"

  echo "[$arch] LZO $LZO"
  tar xzf "$SRC/lzo-$LZO.tar.gz" -C "$work"
  (
    cd "$work/lzo-$LZO"
    ./configure --host="$host" --prefix="$prefix" --disable-shared --enable-static CC="$cc" >/dev/null
    make -j"$JOBS" >/dev/null
    make install >/dev/null
  )

  echo "[$arch] OpenVPN $OPENVPN"
  tar xzf "$SRC/openvpn-$OPENVPN.tar.gz" -C "$work"
  (
    cd "$work/openvpn-$OPENVPN"
    SCRIPTDIR="$INSTALL_DIR" ./configure --host="$host" \
      --disable-plugins --disable-plugin-auth-pam --disable-plugin-down-root --disable-unit-tests \
      --disable-port-share --without-openssl-engine \
      CC="$cc" \
      OPENSSL_CFLAGS="-I$prefix/include" OPENSSL_LIBS="$prefix/lib/libssl.a $prefix/lib/libcrypto.a" \
      LZ4_CFLAGS="-I$prefix/include" LZ4_LIBS="$prefix/lib/liblz4.a" \
      LZO_CFLAGS="-I$prefix/include" LZO_LIBS="$prefix/lib/liblzo2.a" >/dev/null
    make -j"$JOBS" >/dev/null
  )
  cp "$work/openvpn-$OPENVPN/src/openvpn/openvpn" "$work/openvpn"
}

build_arch arm64
build_arch x86_64

rm -rf "$OUT"
mkdir -p "$OUT/licenses"
lipo -create "$SRC/build-arm64/openvpn" "$SRC/build-x86_64/openvpn" -output "$OUT/openvpn"
strip -x "$OUT/openvpn"
# OpenVPN's own macOS DNS script (BSD-2-Clause), as `make install` would put it in SCRIPTDIR.
cp "$SRC/build-arm64/openvpn-$OPENVPN/distro/dns-scripts/macos-dns-updown.sh" "$OUT/dns-updown"
chmod 755 "$OUT/openvpn" "$OUT/dns-updown"

# Shipping OpenVPN (GPLv2) means shipping its licence and saying where its source is.
cp "$SRC/build-arm64/openvpn-$OPENVPN/COPYING" "$OUT/licenses/OpenVPN-COPYING.txt"
cp "$SRC/build-arm64/openvpn-$OPENVPN/COPYRIGHT.GPL" "$OUT/licenses/OpenVPN-COPYRIGHT.GPL.txt"
cp "$SRC/build-arm64/openssl-$OPENSSL/LICENSE.txt" "$OUT/licenses/OpenSSL-LICENSE.txt"
cp "$SRC/build-arm64/lz4-$LZ4/lib/LICENSE" "$OUT/licenses/LZ4-LICENSE.txt"
cp "$SRC/build-arm64/lzo-$LZO/COPYING" "$OUT/licenses/LZO-COPYING.txt"
cat > "$OUT/licenses/SOURCES.txt" <<TXT
AI Notch's VPN engine is built from these unmodified releases by scripts/build-openvpn.sh in
https://github.com/ankeshshankar/ai-notch:

OpenVPN $OPENVPN (GPLv2)      https://github.com/OpenVPN/openvpn/releases/download/v$OPENVPN/openvpn-$OPENVPN.tar.gz
OpenSSL $OPENSSL (Apache 2.0) https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL/openssl-$OPENSSL.tar.gz
LZ4 $LZ4 (BSD-2-Clause)       https://github.com/lz4/lz4/releases/download/v$LZ4/lz4-$LZ4.tar.gz
LZO $LZO (GPLv2)              https://www.oberhumer.com/opensource/lzo/download/lzo-$LZO.tar.gz
TXT

"$OUT/openvpn" --version | head -1
echo "Built $OUT"
