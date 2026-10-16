#!/bin/bash
# Turn the tree in $PREFIX into libexec-<version>-linux-<arch>.tar.gz. Run in the build image after build.sh.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TREE=$OUT/tree
rm -rf "$TREE"; mkdir -p "$OUT"
cp -a "$PREFIX" "$TREE"

# Nothing here is used at run time: headers and pkg-config files for building against libfuse,
# the fstab mount helper, man pages and shell completions. Dropping them saves most of the inodes.
rm -rf "$TREE/include" "$TREE/share" "$TREE/sbin" "$TREE/lib/pkgconfig" "$TREE/lib/libfuse3.so"

# Libraries outside glibc that a binary needs are copied into lib/, and every ELF file finds lib/ relative to itself.
glibc='linux-vdso|ld-linux|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libresolv\.so|libutil\.so|libnsl\.so|libnss_|libcrypt\.so'
find "$TREE" -type f \( -perm -u+x -o -name '*.so*' \) | while read -r f; do
  file -b "$f" | grep -q '^ELF' || continue
  LD_LIBRARY_PATH="$TREE/lib" ldd "$f" 2>/dev/null | awk '/=> \// {print $3}' | grep -vE "$glibc" | while read -r lib; do
    case "$lib" in "$TREE"/*) ;; *) cp -n "$lib" "$TREE/lib/" ;; esac
  done || true
  strip --strip-unneeded "$f" 2>/dev/null || true
  rel=$(realpath --relative-to="$(dirname "$f")" "$TREE/lib")
  patchelf --set-rpath "\$ORIGIN/$rel" "$f" 2>/dev/null || true
done

# Each component's license files, and where its source came from. A library copied from the image
# brings the license directory of the package that owns it.
LIC=$TREE/LICENSES; mkdir -p "$LIC"
copy_licenses() {   # copy_licenses <name> <source dir>
  mkdir -p "$LIC/$1"
  find "$2" -maxdepth 1 -type f \( -iname 'COPYING*' -o -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'NOTICE*' \) -exec cp {} "$LIC/$1/" \;
}
for dir in "$SRC"/apptainer-* "$SRC"/fuse-* "$SRC"/fakeroot-* "$SRC"/e2fsprogs-* "$SRC/apptainer-$APPTAINER_VERSION"/{squashfs-tools,squashfuse,fuse-overlayfs}-*/; do
  if [ -d "$dir" ]; then copy_licenses "$(basename "$dir")" "$dir"; fi
done
for lib in "$TREE"/lib/*.so*; do
  if [ ! -f "$lib" ] || [ -L "$lib" ]; then continue; fi
  pkg=$(rpm -qf "/usr/lib64/$(basename "$lib")" 2>/dev/null) || continue
  mkdir -p "$LIC/$pkg"; cp -r /usr/share/licenses/"${pkg%%-[0-9]*}"/. "$LIC/$pkg/" 2>/dev/null || true
done
{
  echo "Sources of the components in this bundle. Each was built from the tarball below."
  echo "apptainer-$APPTAINER_VERSION  https://github.com/apptainer/apptainer/releases/download/v$APPTAINER_VERSION/  sha256 $APPTAINER_SHA256"
  echo "libfuse-$LIBFUSE_VERSION  https://github.com/libfuse/libfuse/releases/download/fuse-$LIBFUSE_VERSION/  sha256 $LIBFUSE_SHA256"
  echo "fakeroot-$FAKEROOT_VERSION  http://deb.debian.org/debian/pool/main/f/fakeroot/  sha256 $FAKEROOT_SHA256"
  for f in "$DL"/deps/*.tar.gz "$DL"/e2fsprogs-*.tar.xz; do
    if [ -f "$f" ]; then echo "$(basename "$f")  sha256 $(sha256sum "$f" | cut -d' ' -f1)"; fi
  done
} > "$LIC/SOURCES.txt"

# The manifest lists every file, so an update can replace exactly what the previous bundle installed.
python3 - "$TREE" "$APPTAINER_VERSION" <<'PY'
import hashlib, json, os, sys
tree, version = sys.argv[1], sys.argv[2]
files = {}
for root, _, names in os.walk(tree):
    for n in names:
        p = os.path.join(root, n)
        rel = os.path.relpath(p, tree)
        if rel == "MANIFEST.json":
            continue
        if os.path.islink(p):
            files[rel] = {"link": os.readlink(p)}
        else:
            with open(p, "rb") as f:
                files[rel] = {"sha256": hashlib.sha256(f.read()).hexdigest()}
json.dump({"apptainer": version, "files": dict(sorted(files.items()))}, open(os.path.join(tree, "MANIFEST.json"), "w"), indent=1)
PY

name=libexec-$APPTAINER_VERSION-linux-$ARCH
tar -C "$TREE" -czf "$OUT/$name.tar.gz" --transform "s,^\./,," .
( cd "$OUT" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256" )
echo "packed $OUT/$name.tar.gz"
