#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(sed -n 's/^CHDTOOL_VERSION="\([^"]*\)"/\1/p' "$REPO_ROOT/chdtool.sh")"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
dist_dir="$FIX/dist"

(cd "$REPO_ROOT" && DIST_DIR="$dist_dir" SOURCE_DATE_EPOCH=0 bash scripts/package-release.sh "$version")

archive_base="chdtool-v$version"
[[ -s "$dist_dir/$archive_base.tar.gz" ]] || { echo "FAIL: tar archive missing" >&2; exit 1; }
[[ -s "$dist_dir/$archive_base.zip" ]] || { echo "FAIL: zip archive missing" >&2; exit 1; }
[[ -s "$dist_dir/chdtool" && -s "$dist_dir/SHA256SUMS" ]] || { echo "FAIL: standalone script or checksums missing" >&2; exit 1; }
(cd "$dist_dir" && sha256sum --check SHA256SUMS >/dev/null)
first_hashes="$(cd "$dist_dir" && sha256sum chdtool "$archive_base.tar.gz" "$archive_base.zip")"

(cd "$REPO_ROOT" && DIST_DIR="$dist_dir" SOURCE_DATE_EPOCH=0 bash scripts/package-release.sh "$version" >/dev/null)
second_hashes="$(cd "$dist_dir" && sha256sum chdtool "$archive_base.tar.gz" "$archive_base.zip")"
[[ "$first_hashes" == "$second_hashes" ]] || { echo "FAIL: repeated packaging was not reproducible" >&2; exit 1; }

echo "PASS: release assets are complete, validated, and checksummed"
