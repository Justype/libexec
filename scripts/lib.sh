# Shared helpers. Sourced by the other scripts.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/versions.env"
WORK=${WORK:-$ROOT/work}
DL=$WORK/dl SRC=$WORK/src OUT=$WORK/out
JOBS=${JOBS:-$(nproc)}

# ARCH names the archive (x86_64, aarch64). GOARCH names the Go download (amd64, arm64).
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  GOARCH=amd64 ;;
  aarch64) GOARCH=arm64 ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
mkdir -p "$DL" "$SRC" "$OUT"

fetch() {   # fetch <file> <url> <sha256>
  local file=$1 url=$2 want=$3
  [ -f "$DL/$file" ] || curl -fsSL -o "$DL/$file" "$url"
  local got; got=$(sha256sum "$DL/$file" | cut -d' ' -f1)
  [ "$got" = "$want" ] || { echo "sha256 mismatch for $file: $got" >&2; exit 1; }
}

# spec_version <name>: the version Apptainer's spec pins for a helper (squashfuse, e2fsprogs, ...).
spec_version() {
  sed -n "s/^%global ${1}_version //p" "$SRC/apptainer-$APPTAINER_VERSION/dist/rpm/apptainer.spec.in" | head -1
}
