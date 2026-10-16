# CondaTainer libexe Build

Builds the Apptainer bundle that [CondaTainer](https://github.com/condatainer/condatainer) installs into its `libexec` directory.

The bundle is Apptainer plus the tools Apptainer and CondaTainer need. It is built on AlmaLinux 8, so one archive runs on glibc 2.28 and newer. There is one archive per architecture: `x86_64` and `aarch64`.

| Tool | Version |
|---|---|
| `apptainer` | the release tag |
| `fuse2fs`, `mke2fs`, `e2fsck`, `tune2fs`, `debugfs`, `resize2fs` | e2fsprogs, as pinned by Apptainer |
| `squashfuse_ll`, `fuse-overlayfs`, `mksquashfs`, `unsquashfs` | as pinned by Apptainer |
| `fusermount3` | libfuse |
| `fakeroot-sysv`, `faked-sysv` | fakeroot |

Micromamba is not part of the bundle.

## Why

`fuse2fs` up to 1.47.2 ignores `O_TRUNC` when it runs on libfuse 3. A file rewritten shorter then keeps its old size and a stale tail. The bundle ships a `fuse2fs` without the bug, so the node's OS packages do not decide.

## Versions

- A release is the Apptainer version, for example `v1.5.4`. The release workflow creates the tag.
- `versions.env` holds the Apptainer version and what Apptainer does not pin: libfuse, fakeroot and Go.
- The other tool versions are read from `dist/rpm/apptainer.spec.in` of the Apptainer release being built.

## Build

```bash
docker build -f docker/build.Dockerfile -t libexec-build .
docker run --rm -v "$PWD:/work" -w /work libexec-build bash -c 'scripts/build.sh && scripts/pack.sh'
```

The archive is `work/out/libexec-<version>-linux-<arch>.tar.gz`, with a `.sha256` next to it. `<arch>` is the build machine's `uname -m`. Build on an arm64 machine for `aarch64`.

Test an unpacked tree on a machine with user namespaces and `/dev/fuse`:

```bash
mkdir tree && tar -xzf work/out/libexec-*.tar.gz -C tree
scripts/smoke.sh tree
```

`smoke.sh` starts every binary, checks the version floors, tests `--fakeroot`, checks that a file overwritten shorter keeps the new size, and repeats the tests on a copy at another path.

## Updating the tools

`.github/workflows/update.yml` runs weekly and needs no one to watch it.

1. `scripts/update-versions.sh` finds the newest Apptainer, libfuse and fakeroot, and the Go version the new Apptainer needs. It rewrites `versions.env` with the checksums.
2. If the Apptainer version is the same, the run ends. A newer libfuse or fakeroot alone is not released.
3. Otherwise it commits to a temporary `update/...` branch and builds and smoke-tests that commit on `x86_64` and `aarch64`.
4. When both pass, it fast-forwards `main` to that commit and publishes `v<version>` with both archives. The commit message, with the old and new versions and the tools the new Apptainer pins, is the release text.
5. The temporary branch is always deleted. A failed build leaves `main` unchanged, and GitHub reports the failed run. The next run retries.

The smoke test fails when the pinned e2fsprogs is older than 1.47.3.

`.github/workflows/release.yml` does the publishing. It adds the archives to the release when it exists and creates it otherwise. A manual run of `build` on `main` publishes the current version the same way.

## Archive layout

```text
bin/                  apptainer, fusermount3, fuse2fs and the other e2fsprogs tools, symlinks to mksquashfs and unsquashfs
lib/                  shared libraries
lib/apptainer/bin/    starter, squashfuse_ll, fuse-overlayfs, mksquashfs, unsquashfs, fakeroot-sysv, faked-sysv, a symlink to fuse2fs
etc/apptainer/        configuration
var/apptainer/mnt/session/   empty; Apptainer mounts onto it
MANIFEST.json         every file with its sha256
LICENSES/             license files per component, and SOURCES.txt with the source tarballs and their sha256
```

The archive can be unpacked at any path.
