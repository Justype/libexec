#!/bin/bash
# Move versions.env to the newest releases of Apptainer, libfuse and fakeroot, with the checksums.
# The Go version follows the new Apptainer release's go.mod. The helper tools follow its spec.
#   scripts/update-versions.sh                  rewrites versions.env
#   OUT_ENV=/tmp/new.env scripts/update-versions.sh   writes the result elsewhere
# When anything changed, the pull request text is written to $PR_BODY (default work/pr-body.md).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/versions.env"
OUT_ENV=${OUT_ENV:-$ROOT/versions.env}
PR_BODY=${PR_BODY:-$ROOT/work/pr-body.md}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

api() { curl -fsSL ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} "$@"; }
latest_tag() { api "https://api.github.com/repos/$1/releases/latest" | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])'; }
sha_of() { curl -fsSL "$1" -o "$TMP/f" && sha256sum "$TMP/f" | cut -d' ' -f1; }

new_apptainer=$(latest_tag apptainer/apptainer); new_apptainer=${new_apptainer#v}
new_libfuse=$(latest_tag libfuse/libfuse); new_libfuse=${new_libfuse#fuse-}
new_fakeroot=$(curl -fsSL http://deb.debian.org/debian/pool/main/f/fakeroot/ \
  | grep -oE 'fakeroot_[0-9.]+\.orig\.tar\.gz' | sort -uV | tail -1 | sed -E 's/fakeroot_(.*)\.orig\.tar\.gz/\1/')

new_apptainer_sha=$APPTAINER_SHA256 new_libfuse_sha=$LIBFUSE_SHA256 new_fakeroot_sha=$FAKEROOT_SHA256
[ "$new_apptainer" = "$APPTAINER_VERSION" ] || new_apptainer_sha=$(sha_of "https://github.com/apptainer/apptainer/releases/download/v$new_apptainer/apptainer-$new_apptainer.tar.gz")
[ "$new_libfuse" = "$LIBFUSE_VERSION" ] || new_libfuse_sha=$(sha_of "https://github.com/libfuse/libfuse/releases/download/fuse-$new_libfuse/fuse-$new_libfuse.tar.gz")
[ "$new_fakeroot" = "$FAKEROOT_VERSION" ] || new_fakeroot_sha=$(sha_of "http://deb.debian.org/debian/pool/main/f/fakeroot/fakeroot_$new_fakeroot.orig.tar.gz")

# Go: the version go.mod of the new Apptainer asks for. A bare major.minor means the newest patch.
want_go=$(curl -fsSL "https://raw.githubusercontent.com/apptainer/apptainer/v$new_apptainer/go.mod" | sed -n 's/^go //p' | head -1)
curl -fsSL "https://go.dev/dl/?mode=json&include=all" > "$TMP/go.json"
new_go=$(python3 - "$want_go" "$TMP/go.json" <<'PY'
import json, sys
want, path = sys.argv[1], sys.argv[2]
rels = [r["version"][2:] for r in json.load(open(path)) if r["stable"]]
if want.count(".") >= 2:
    print(want)
else:
    same = [v for v in rels if v == want or v.startswith(want + ".")]
    key = lambda v: [int(x) for x in v.split(".")]
    print(max(same, key=key))
PY
)
go_sha() {   # go_sha <arch>
python3 - "$new_go" "$TMP/go.json" "$1" <<'PY'
import json, sys
v, path, arch = sys.argv[1], sys.argv[2], sys.argv[3]
for r in json.load(open(path)):
    if r["version"] == "go" + v:
        for f in r["files"]:
            if f["os"] == "linux" and f["arch"] == arch and f["kind"] == "archive":
                print(f["sha256"])
PY
}
new_go_sha_amd64=$(go_sha amd64); new_go_sha_arm64=$(go_sha arm64)
[ -n "$new_go_sha_amd64" ] && [ -n "$new_go_sha_arm64" ] || { echo "no linux checksum for Go $new_go" >&2; exit 1; }

sed -e "s|^APPTAINER_VERSION=.*|APPTAINER_VERSION=$new_apptainer|" -e "s|^APPTAINER_SHA256=.*|APPTAINER_SHA256=$new_apptainer_sha|" \
    -e "s|^LIBFUSE_VERSION=.*|LIBFUSE_VERSION=$new_libfuse|"       -e "s|^LIBFUSE_SHA256=.*|LIBFUSE_SHA256=$new_libfuse_sha|" \
    -e "s|^FAKEROOT_VERSION=.*|FAKEROOT_VERSION=$new_fakeroot|"    -e "s|^FAKEROOT_SHA256=.*|FAKEROOT_SHA256=$new_fakeroot_sha|" \
    -e "s|^GO_VERSION=.*|GO_VERSION=$new_go|"                       -e "s|^GO_SHA256_linux_amd64=.*|GO_SHA256_linux_amd64=$new_go_sha_amd64|" \
    -e "s|^GO_SHA256_linux_arm64=.*|GO_SHA256_linux_arm64=$new_go_sha_arm64|" \
    "$ROOT/versions.env" > "$TMP/new.env"

if cmp -s "$ROOT/versions.env" "$TMP/new.env"; then echo "up to date"; exit 0; fi
cp "$TMP/new.env" "$OUT_ENV"

# The helper tools Apptainer pins in the release being built.
spec=$(curl -fsSL "https://raw.githubusercontent.com/apptainer/apptainer/v$new_apptainer/dist/rpm/apptainer.spec.in")
pin() { sed -n "s/^%global $1_version //p" <<<"$spec" | head -1; }
e2fs=$(pin e2fsprogs)

mkdir -p "$(dirname "$PR_BODY")"
{
  echo "Moves \`versions.env\` to the newest releases."
  echo
  echo "| | was | now |"
  echo "|---|---|---|"
  echo "| Apptainer | $APPTAINER_VERSION | $new_apptainer |"
  echo "| libfuse | $LIBFUSE_VERSION | $new_libfuse |"
  echo "| fakeroot | $FAKEROOT_VERSION | $new_fakeroot |"
  echo "| Go | $GO_VERSION | $new_go |"
  echo
  echo "Helper tools pinned by Apptainer $new_apptainer: squashfuse $(pin squashfuse), e2fsprogs $e2fs, fuse-overlayfs $(pin fuse_overlayfs), squashfs-tools $(pin squashfs_tools)."
  if [ "$(printf '%s\n1.47.3\n' "$e2fs" | sort -V | head -1)" != 1.47.3 ]; then
    echo
    echo "**e2fsprogs $e2fs is older than 1.47.3, so its \`fuse2fs\` loses \`O_TRUNC\` on libfuse 3. The smoke test fails until Apptainer pins a newer one.**"
  fi
  echo
  echo "Checksums were computed from the downloaded sources. The \`build\` workflow builds and tests the result. After merging, tag the Apptainer version to publish."
} > "$PR_BODY"
echo "updated: Apptainer $APPTAINER_VERSION -> $new_apptainer, libfuse $LIBFUSE_VERSION -> $new_libfuse, fakeroot $FAKEROOT_VERSION -> $new_fakeroot, Go $GO_VERSION -> $new_go"
