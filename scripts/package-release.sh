#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

version="${1:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "Usage: $0 <release-version>" >&2
  exit 1
}

script_version="$(sed -n 's/^CHDTOOL_VERSION="\([^"]*\)"/\1/p' chdtool.sh)"
[[ "$script_version" == "$version" ]] || {
  echo "Release version $version does not match chdtool.sh version $script_version" >&2
  exit 1
}

for command in tar gzip zip unzip sha256sum; do
  command -v "$command" >/dev/null 2>&1 || { echo "Missing packaging command: $command" >&2; exit 1; }
done

archive_base="chdtool-v$version"
dist_dir="${DIST_DIR:-$REPO_ROOT/dist}"
[[ "$dist_dir" == /* ]] || dist_dir="$REPO_ROOT/$dist_dir"
[[ "$dist_dir" != "/" && "$dist_dir" != "$REPO_ROOT" ]] || {
  echo "Refusing unsafe distribution directory: $dist_dir" >&2
  exit 1
}
stage_root="$(mktemp -d)"
trap 'rm -rf "$stage_root"' EXIT
stage_dir="$stage_root/$archive_base"
mkdir -p "$stage_dir"

install -m 0755 chdtool.sh "$stage_dir/chdtool"
install -m 0644 README.md LICENSE.md CHANGELOG.md "$stage_dir/"

# Use the tagged commit timestamp when available, with a stable fallback for
# source archives or local packaging outside a Git checkout.
source_date_epoch="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || printf '0')}"
find "$stage_dir" -exec touch -d "@$source_date_epoch" {} +

rm -rf -- "$dist_dir"
mkdir -p "$dist_dir"

tar --sort=name --mtime="@$source_date_epoch" --owner=0 --group=0 --numeric-owner \
  -C "$stage_root" -cf - "$archive_base" | gzip -n > "$dist_dir/$archive_base.tar.gz"

zip_path="$dist_dir/$archive_base.zip"
(
  cd "$stage_root"
  find "$archive_base" -type f -print | LC_ALL=C sort | zip -X -q "$zip_path" -@
)

install -m 0755 chdtool.sh "$dist_dir/chdtool"

expected="$(printf '%s\n' \
  "$archive_base/CHANGELOG.md" \
  "$archive_base/LICENSE.md" \
  "$archive_base/README.md" \
  "$archive_base/chdtool")"
tar_contents="$(tar -tzf "$dist_dir/$archive_base.tar.gz" | sed '/\/$/d' | LC_ALL=C sort)"
zip_contents="$(unzip -Z1 "$dist_dir/$archive_base.zip" | sed '/\/$/d' | LC_ALL=C sort)"
[[ "$tar_contents" == "$expected" ]] || { echo "Unexpected tar archive contents" >&2; exit 1; }
[[ "$zip_contents" == "$expected" ]] || { echo "Unexpected zip archive contents" >&2; exit 1; }

(
  cd "$dist_dir"
  sha256sum chdtool "$archive_base.tar.gz" "$archive_base.zip" > SHA256SUMS
  sha256sum --check SHA256SUMS
)

printf 'Created validated release assets in %s\n' "$dist_dir"
