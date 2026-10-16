#!/bin/bash
# Build Apptainer and its tools into $PREFIX. Run inside the build image (docker/build.Dockerfile).
# The prefix is compiled into Apptainer, so the tree stays at $PREFIX until scripts/pack.sh copies it.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- sources
fetch "apptainer-$APPTAINER_VERSION.tar.gz" \
  "https://github.com/apptainer/apptainer/releases/download/v$APPTAINER_VERSION/apptainer-$APPTAINER_VERSION.tar.gz" "$APPTAINER_SHA256"
fetch "fuse-$LIBFUSE_VERSION.tar.gz" \
  "https://github.com/libfuse/libfuse/releases/download/fuse-$LIBFUSE_VERSION/fuse-$LIBFUSE_VERSION.tar.gz" "$LIBFUSE_SHA256"
fetch "fakeroot_$FAKEROOT_VERSION.orig.tar.gz" \
  "http://deb.debian.org/debian/pool/main/f/fakeroot/fakeroot_$FAKEROOT_VERSION.orig.tar.gz" "$FAKEROOT_SHA256"
go_sha_var=GO_SHA256_linux_$GOARCH
fetch "go$GO_VERSION.linux-$GOARCH.tar.gz" "https://go.dev/dl/go$GO_VERSION.linux-$GOARCH.tar.gz" "${!go_sha_var}"

for t in "apptainer-$APPTAINER_VERSION" "fuse-$LIBFUSE_VERSION" "fakeroot-$FAKEROOT_VERSION"; do rm -rf "${SRC:?}/$t"; done
tar -xzf "$DL/apptainer-$APPTAINER_VERSION.tar.gz" -C "$SRC"
tar -xzf "$DL/fuse-$LIBFUSE_VERSION.tar.gz" -C "$SRC"
tar -xzf "$DL/fakeroot_$FAKEROOT_VERSION.orig.tar.gz" -C "$SRC"
[ -x "$WORK/go/bin/go" ] || tar -xzf "$DL/go$GO_VERSION.linux-$GOARCH.tar.gz" -C "$WORK"
# GOROOT and GOTOOLCHAIN are set so a Go the environment already points at cannot be mixed with this one.
export GOROOT="$WORK/go" GOTOOLCHAIN=local PATH="$WORK/go/bin:$PATH"

want_go=$(sed -n 's/^go //p' "$SRC/apptainer-$APPTAINER_VERSION/go.mod" | head -1)
echo "Apptainer $APPTAINER_VERSION wants Go $want_go; building with $(go version)"

# The helper versions come from the spec of this Apptainer version.
E2FSPROGS_VERSION=$(spec_version e2fsprogs)
[ -n "$E2FSPROGS_VERSION" ] || { echo "no e2fsprogs version in the Apptainer spec" >&2; exit 1; }
echo "helpers pinned by Apptainer: squashfuse $(spec_version squashfuse), e2fsprogs $E2FSPROGS_VERSION," \
     "fuse-overlayfs $(spec_version fuse_overlayfs), squashfs-tools $(spec_version squashfs_tools)"

rm -rf "$PREFIX"; mkdir -p "$PREFIX"
# Run-time library paths are set on the finished binaries by pack.sh, not here: make would expand $ORIGIN.
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" LD_LIBRARY_PATH="$PREFIX/lib"

# --- libfuse 3 (library only; fusermount3 is built too and stays non-setuid)
( cd "$SRC/fuse-$LIBFUSE_VERSION"
  meson setup build --prefix="$PREFIX" --libdir=lib -Dexamples=false -Dtests=false -Duseroot=false -Dudevrulesdir="$PREFIX/etc/udev"
  ninja -C build install )

# --- Apptainer (non-setuid, tool directory under $PREFIX/lib/apptainer)
( cd "$SRC/apptainer-$APPTAINER_VERSION"
  # --without-suid is explicit because mconfig otherwise tests user namespaces on the build host,
  # and a container on a CI runner does not have them.
  ./mconfig -p "$PREFIX" --libexecdir="$PREFIX/lib" --without-network --without-suid
  make -C builddir -j"$JOBS"
  make -C builddir install

  # squashfs-tools, squashfuse and fuse-overlayfs as Apptainer builds them. e2fsprogs and the
  # tools only Apptainer's optional features use are skipped; e2fsprogs is built below.
  mkdir -p "$DL/deps"
  ./scripts/download-dependencies "$DL/deps"
  rm -f "$DL"/deps/e2fsprogs[_-]* "$DL"/deps/gocryptfs[_-]* "$DL"/deps/PRoot[_-]* "$DL"/deps/archivemount[_-]*
  ./scripts/compile-dependencies "$DL/deps"
  ./scripts/install-dependencies "$PREFIX/lib" )

# --- e2fsprogs: fuse2fs and the tools condatainer calls
sums=$(curl -fsSL "https://www.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$E2FSPROGS_VERSION/sha256sums.asc")
E2FS_SHA=$(echo "$sums" | sed -n "s/^\([0-9a-f]\{64\}\)  e2fsprogs-$E2FSPROGS_VERSION.tar.xz\$/\1/p")
fetch "e2fsprogs-$E2FSPROGS_VERSION.tar.xz" \
  "https://www.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$E2FSPROGS_VERSION/e2fsprogs-$E2FSPROGS_VERSION.tar.xz" "$E2FS_SHA"
rm -rf "$SRC/e2fsprogs-$E2FSPROGS_VERSION"; tar -xJf "$DL/e2fsprogs-$E2FSPROGS_VERSION.tar.xz" -C "$SRC"
( cd "$SRC/e2fsprogs-$E2FSPROGS_VERSION"
  ./configure --enable-fuse2fs --enable-libuuid --enable-libblkid --disable-nls --disable-fsck --disable-uuidd
  make -j"$JOBS"
  install -m 0755 misc/fuse2fs misc/mke2fs misc/tune2fs e2fsck/e2fsck debugfs/debugfs resize/resize2fs "$PREFIX/bin/" )
rm -f "$PREFIX/lib/apptainer/bin/fuse2fs"
ln -s ../../../bin/fuse2fs "$PREFIX/lib/apptainer/bin/fuse2fs"

# --- fakeroot, in the names Apptainer looks for
( cd "$SRC/fakeroot-$FAKEROOT_VERSION"
  # A recent libcap's sys/capability.h no longer pulls in the kernel's capability types, which fakeroot uses.
  CFLAGS="-O2 -include linux/capability.h" ./configure --prefix="$PREFIX/lib/apptainer" --with-ipc=sysv --program-suffix=-sysv --disable-static
  make -j"$JOBS"
  make install
  # The launcher finds its files from its own location, and the library has the name Apptainer asks for.
  sed -i -e 's|^FAKEROOT_PREFIX=/.*|FAKEROOT_BINDIR=$(cd "$(dirname "$(readlink -f "$0")")" \&\& pwd)|' \
         -e 's|^FAKEROOT_BINDIR=/.*|FAKEROOT_PREFIX=${FAKEROOT_BINDIR%/*}|' \
         -e "s|^PATHS=$PREFIX/lib/apptainer/lib:|PATHS=\${FAKEROOT_PREFIX}/lib:|" \
         "$PREFIX/lib/apptainer/bin/fakeroot-sysv"
  ( cd "$PREFIX/lib/apptainer/lib" && ln -sf "$(ls libfakeroot-*.so | head -1)" libfakeroot-sysv.so )
  rm -rf "$PREFIX/lib/apptainer/share" "$PREFIX"/lib/apptainer/lib/*.la )

# --- tools condatainer resolves itself
ln -sf ../lib/apptainer/bin/mksquashfs "$PREFIX/bin/mksquashfs"
ln -sf ../lib/apptainer/bin/unsquashfs "$PREFIX/bin/unsquashfs"
mkdir -p "$PREFIX/var/apptainer/mnt/session"; chmod 0755 "$PREFIX/var/apptainer/mnt/session"

echo "built into $PREFIX"
