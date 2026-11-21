#!/bin/sh
# Builds the Erlang/OTP runtime that standalone archives ship: OpenSSL linked
# statically into the crypto NIF, no terminal library, and (on Linux) the C++
# runtime linked into beam.smp, so the archive needs only the C library.
#
# Usage: build-runtime.sh <prefix>
# Installs OpenSSL into <prefix>/openssl and OTP into <prefix>/otp.
set -eu

prefix=$1
otp_version=28.0.4
otp_sha256=687c0abece0a12d58517c1892bf45df6d5db23d1b6098d59bdb0c77bbc4e88e8
openssl_version=3.5.9
openssl_sha256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a

case "$(uname -s)" in
  Darwin)
    jobs=$(sysctl -n hw.ncpu)
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
    openssl_target=darwin64-$(uname -m)-cc
    otp_ldflags=""
    ;;
  Linux)
    jobs=$(nproc)
    openssl_target=linux-$(uname -m)
    otp_ldflags="-static-libstdc++ -static-libgcc"
    ;;
  *)
    echo "unsupported build host: $(uname -s)" >&2
    exit 1
    ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/lasso-runtime.XXXXXX")
trap 'rm -rf "$work"' EXIT

fetch() {
  curl --fail --silent --show-error --location --retry 3 -o "$work/$2" "$1"
  if command -v sha256sum >/dev/null; then sum=sha256sum; else sum="shasum -a 256"; fi
  echo "$3  $work/$2" | $sum -c - >/dev/null
}

fetch "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz" \
  openssl.tar.gz "$openssl_sha256"
tar -xzf "$work/openssl.tar.gz" -C "$work"
(
  cd "$work/openssl-$openssl_version"
  ./Configure "$openssl_target" no-shared no-tests no-docs -fPIC \
    --prefix="$prefix/openssl" --libdir=lib --openssldir="$prefix/openssl/ssl"
  make -j"$jobs" build_libs >/dev/null
  make install_dev >/dev/null
)

fetch "https://github.com/erlang/otp/releases/download/OTP-$otp_version/otp_src_$otp_version.tar.gz" \
  otp.tar.gz "$otp_sha256"
tar -xzf "$work/otp.tar.gz" -C "$work"
(
  cd "$work/otp_src_$otp_version"
  LDFLAGS="$otp_ldflags" ./configure --prefix="$prefix/otp" \
    --with-ssl="$prefix/openssl" --disable-dynamic-ssl-lib \
    --without-termcap --without-wx --without-odbc --without-javac --without-jinterface \
    --without-debugger --without-observer --without-et --without-megaco --without-ssh \
    --enable-builtin-zlib >/dev/null
  make -j"$jobs" >/dev/null
  make install >/dev/null
)

"$prefix/otp/bin/erl" -noshell -eval \
  'io:format("OTP ~s, ~s~n", [erlang:system_info(otp_release), element(3, hd(crypto:info_lib()))]), halt().'
