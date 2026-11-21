#!/bin/sh
# Wraps a standalone archive into one executable file: a POSIX shell header that
# unpacks the archive on first run into a per-user cache directory, then runs
# bin/lasso from there with the same arguments.
#
# Usage: single-file.sh <lasso-VERSION-TARGET.tar.gz> <out-dir>
set -eu

archive=$1
name=$(basename "$archive" .tar.gz)
out="$2/$name.run"
if command -v sha256sum >/dev/null; then sum=sha256sum; else sum="shasum -a 256"; fi
digest=$($sum "$archive" | cut -c1-16)

cat >"$out" <<EOF
#!/bin/sh
# $name as one file. The first run unpacks it into
# \$LASSO_EXTRACT_DIR (default: the user cache directory), later runs start at once.
set -eu
case "\$(uname -s)" in
  Darwin) cache="\$HOME/Library/Caches/lasso" ;;
  *) cache="\${XDG_CACHE_HOME:-\$HOME/.cache}/lasso" ;;
esac
dir="\${LASSO_EXTRACT_DIR:-\$cache}/$name-$digest"
if [ ! -x "\$dir/lasso/bin/lasso" ]; then
  mkdir -p "\$(dirname "\$dir")"
  tmp=\$(mktemp -d "\$dir.XXXXXX")
  tail -n +@SKIP@ "\$0" | tar -xzf - -C "\$tmp"
  if [ -d "\$dir" ]; then rm -rf "\$tmp"; else mv "\$tmp" "\$dir"; fi
fi
exec "\$dir/lasso/bin/lasso" "\$@"
EOF

skip=$(($(wc -l <"$out") + 1))
sed "s/@SKIP@/$skip/" "$out" >"$out.tmp" && mv "$out.tmp" "$out"
cat "$archive" >>"$out"
chmod 755 "$out"
echo "$out"
