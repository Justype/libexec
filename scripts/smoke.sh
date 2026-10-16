#!/bin/bash
# Test an unpacked tree: scripts/smoke.sh <tree>
# Needs unprivileged user namespaces and /dev/fuse. The runtime tests pull AlmaLinux 8 (the oldest glibc the bundle supports) unless IMAGE is set.
set -euo pipefail
# A bind inherited from an outer container would mount paths the test images do not have.
unset APPTAINER_BIND SINGULARITY_BIND
TREE=$(cd "${1:?usage: smoke.sh <unpacked tree>}" && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Every binary starts (tune2fs and resize2fs print usage for -V), and no ELF file has a missing library.
check_binaries() {
  local t=$1 b flag out missing
  for b in apptainer:--version fuse2fs:--version mke2fs:-V e2fsck:-V tune2fs:-V debugfs:-V resize2fs:-V \
           mksquashfs:-version unsquashfs:-version fusermount3:-V; do
    flag=${b#*:}; b=${b%%:*}
    out=$("$t/bin/$b" "$flag" 2>&1 || true)
    grep -qE '[0-9]+\.[0-9]+|Usage' <<<"$out" || fail "$b $flag printed neither a version nor usage"
  done
  missing=$(find "$t" -type f \( -perm -u+x -o -name '*.so*' \) | while read -r f; do
    file -b "$f" | grep -q '^ELF' || continue
    ldd "$f" 2>&1 | grep -q 'not found' && echo "$f" || true
  done)
  [ -z "$missing" ] || fail "missing libraries for: $missing"
  return 0
}

# 2. Floors Apptainer and condatainer rely on.
check_floors() {
  local t=$1 v
  v=$("$t/bin/mksquashfs" -version 2>&1 | sed -n 's/.*version \([0-9]*\.[0-9]*\).*/\1/p' | head -1)
  [ "$(printf '%s\n4.4\n' "$v" | sort -V | head -1)" = 4.4 ] || fail "mksquashfs $v is older than 4.4"
  v=$("$t/bin/apptainer" --version | sed -n 's/.*version \([0-9]*\.[0-9]*\).*/\1/p')
  [ "$(printf '%s\n1.4\n' "$v" | sort -V | head -1)" = 1.4 ] || fail "apptainer $v is older than 1.4"
}

# 3. Fakeroot and the truncate regression, through the bundled Apptainer and its own tools.
check_runtime() {
  local t=$1 tmp img
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  export PATH="$t/bin:$PATH"
  img=${IMAGE:-$tmp/base.sif}
  [ -f "$img" ] || apptainer -q pull -F "$img" docker://almalinux:8-minimal >/dev/null

  # Root-mapped namespace alone, without the fakeroot command.
  [ "$(apptainer -q exec --fakeroot --ignore-fakeroot-command "$img" id -u)" = 0 ] || fail "--fakeroot did not give uid 0"

  # The bundled fakeroot: a %post that changes owners only succeeds when it is found and runs in the image.
  cat > "$tmp/post.def" <<DEF
Bootstrap: localimage
From: $img

%post
    touch /opt/f; mkdir /opt/d
    chown 1234:5678 /opt/f
    chown 0:42 /opt/d
    test "\$(stat -c %u:%g /opt/f)" = 1234:5678
    test "\$(stat -c %u:%g /opt/d)" = 0:42
DEF
  apptainer -q build -F --fakeroot "$tmp/post.sif" "$tmp/post.def" >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log" >&2; fail "build --fakeroot with a %post that runs chown failed"; }

  truncate -s 64M "$tmp/t.img"; mke2fs -q -t ext3 -F "$tmp/t.img"
  apptainer -q exec --fakeroot --ignore-fakeroot-command --overlay "$tmp/t.img" "$img" sh -c '
    head -c 62383 /dev/urandom > /sh; echo short > /sh
    head -c 62383 /dev/urandom > /cp; echo short > /tmp/s; cp /tmp/s /cp' >/dev/null
  local s
  for f in sh cp; do
    s=$(debugfs -R "stat /upper/$f" "$tmp/t.img" 2>/dev/null | sed -n 's/.*Size: \([0-9]*\).*/\1/p' | head -1)
    [ "$s" = 6 ] || fail "truncate lost for $f: on-disk size '$s', expected 6"
  done
}

echo "== binaries";    check_binaries "$TREE"
echo "== floors";      check_floors "$TREE"
echo "== runtime";     check_runtime "$TREE"
echo "== relocation"
moved=$(mktemp -d)/moved; cp -R -P "$TREE" "$moved"
check_runtime "$moved"
echo "smoke tests passed"
