#!/bin/sh
# Builds the release with the runtime from build-runtime.sh and packs it as
# lasso-<version>-<target>.tar.gz, with a report of every native file's
# library dependencies next to it. Needs cargo: native libraries are built from
# source here, because prebuilt ones can require a newer C library than the
# runtime does.
#
# Usage: package.sh <runtime-prefix> <target> <out-dir>
set -eu

prefix=$1
target=$2
out=$(mkdir -p "$3" && cd "$3" && pwd -P)
root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd -P)
elixir_version=1.18.4
elixir_sha256=5be18f35e329f7c5914a80dd9f323d7bbb144616df1ed16f6f0862a1900b4bb5

if [ ! -x "$prefix/elixir/bin/elixir" ]; then
  curl --fail --silent --show-error --location --retry 3 -o "$prefix/elixir.zip" \
    "https://github.com/elixir-lang/elixir/releases/download/v$elixir_version/elixir-otp-27.zip"
  if command -v sha256sum >/dev/null; then sum=sha256sum; else sum="shasum -a 256"; fi
  echo "$elixir_sha256  $prefix/elixir.zip" | $sum -c - >/dev/null
  mkdir -p "$prefix/elixir"
  unzip -q "$prefix/elixir.zip" -d "$prefix/elixir"
  rm "$prefix/elixir.zip"
fi

export PATH="$prefix/otp/bin:$prefix/elixir/bin:$PATH" MIX_ENV=prod LANG=C.UTF-8 LC_ALL=C.UTF-8
export RUSTLER_BUILD=1 MACOSX_DEPLOYMENT_TARGET=12.0
cd "$root"
mix local.hex --force --if-missing >/dev/null
mix local.rebar --force --if-missing >/dev/null
mix deps.get --only prod >/dev/null
mix compile >/dev/null
mix assets.setup >/dev/null
mix assets.deploy >/dev/null
mix release --overwrite >/dev/null

release=_build/prod/rel/lasso
version=$(cut -d' ' -f2 "$release/releases/start_erl.data")

# OTP builds with debug info and ships an OpenSSL test engine; neither runs in
# production. macOS keeps debug info out of the binaries already, and
# stripping there would also invalidate their ad hoc signatures.
rm -f "$release"/lib/crypto-*/priv/lib/otp_test_engine.so
if [ "$(uname -s)" = Linux ]; then
  find "$release" -type f \( -name '*.so' -o -perm -u+x \) -exec sh -c \
    'readelf -h "$1" >/dev/null 2>&1 && strip --strip-debug "$1"' _ {} \;
fi
name="lasso-$version-$target"
tar -C "$(dirname "$release")" -czf "$out/$name.tar.gz" lasso

{
  echo "# $name native files and their dynamic libraries"
  find "$release" -type f \( -name '*.so' -o -perm -u+x \) | sort | while read -r file; do
    case "$(uname -s)" in
      Darwin)
        otool -hv "$file" 2>/dev/null | grep -q MH_MAGIC || continue
        libs=$(otool -l "$file" | awk '/cmd LC_LOAD(_WEAK)?_DYLIB/ {getline; getline; print $2}' | tr '\n' ' ')
        minos=$(otool -l "$file" | awk '/minos/ {print $2; exit}')
        echo "${file#"$release"/}: macos>=$minos $libs"
        ;;
      Linux)
        readelf -h "$file" >/dev/null 2>&1 || continue
        libs=$(readelf -d "$file" | awk '/NEEDED/ {gsub(/[\[\]]/, "", $5); print $5}' | tr '\n' ' ')
        glibc=$(objdump -T "$file" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -n 1)
        echo "${file#"$release"/}: ${glibc:-no versioned glibc symbols} $libs"
        ;;
    esac
  done
} >"$out/$name.linkage.txt"

echo "$out/$name.tar.gz"
