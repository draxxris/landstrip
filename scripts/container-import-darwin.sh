#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) Jarkko Sakkinen 2026
#
# Import the darwin release outputs exported by scripts/container-export-darwin.sh
# and stage them for packaging, so `make package` builds only the remaining
# platforms:
#
#   ./scripts/container-import-darwin.sh dist/landstrip-darwin-0.20.11.tar
#   PLATFORMS="linux-x64 linux-arm64 win32-x64 win32-arm64 darwin-arm64 darwin-x64" \
#     make package
#
#   CONTAINER       container runtime to drive (default: docker)
#   PREBUILT_ROOT   staging directory (default: packages/landstrip/target/prebuilt)

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)" \
  || { printf 'not inside a Git repository\n' >&2; exit 1; }
cd "$repo_root"

# shellcheck source=sha256.sh
source "$script_dir/sha256.sh"

CONTAINER="${CONTAINER:-docker}"
NODE="${NODE:-node}"
PREBUILT_ROOT="${PREBUILT_ROOT:-packages/landstrip/target/prebuilt}"
IMAGE_REPOSITORY=landstrip-darwin-artifacts

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

confirm() {
  local reply

  printf '%s [y/N] ' "$1" >&2
  read -r reply || return 1
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

# A missing sidecar is worth a warning, not a hard stop: the artifact itself is
# what the packaging step consumes.
check_sha256() {
  local file="$1" name="${1##*/}" recorded

  if [[ ! -f "$file.sha256" ]]; then
    printf 'warning: %s has no sha256 sidecar\n' "$name" >&2
    confirm "continue without verifying $name?" || die "aborted"
    return 0
  fi
  read -r recorded _ <"$file.sha256" || die "unreadable: $name.sha256"
  [[ "$(sha256_digest "$file")" == "$recorded" ]] \
    || die "$name does not match its sidecar"
}

# Archives exported before the export step stopped recording macOS xattrs
# carry com.apple.* attributes that GNU tar and bsdtar cannot restore here.
extract_archive() {
  local archive="$1" target="$2"

  if tar --help 2>&1 | grep -q -- '--no-xattrs'; then
    tar --no-xattrs -C "$target" -xf "$archive"
  else
    tar -C "$target" -xf "$archive"
  fi
}

(( $# == 1 )) || die "usage: $0 <archive.tar>"
archive="$1"

[[ -f "$archive" ]] || die "missing archive: $archive"
case "$CONTAINER" in
  docker|podman) ;;
  *) die "CONTAINER must be docker or podman, not $CONTAINER" ;;
esac
for command in "$CONTAINER" git; do
  require_command "$command"
done

check_sha256 "$archive"

workdir="$(mktemp -d)"
container_id=
cleanup() {
  local status=$?

  if [[ -n "$container_id" ]]; then
    "$CONTAINER" rm -f "$container_id" >/dev/null 2>&1 || true
  fi
  rm -rf "$workdir"
  return "$status"
}
trap cleanup EXIT

extract_archive "$archive" "$workdir" || die "cannot unpack $archive"
manifest="$workdir/manifest"
[[ -f "$manifest" ]] || die "archive has no manifest"
manifest_version="$(sed -n 's/^version //p' "$manifest")"
manifest_commit="$(sed -n 's/^commit //p' "$manifest")"
manifest_platforms="$(sed -n 's/^platforms //p' "$manifest")"
[[ -n "$manifest_version" && -n "$manifest_commit" && -n "$manifest_platforms" ]] \
  || die "archive manifest is incomplete"

require_command "$NODE"
version="$("$NODE" -p "require('./packages/landstrip-cli/package.json').version")"
head_commit="$(git rev-parse HEAD)"
[[ "$manifest_version" == "$version" ]] \
  || die "archive carries $manifest_version, this tree is $version"
[[ "$manifest_commit" == "$head_commit" ]] \
  || die "archive was exported from $manifest_commit; check out that commit first"

for platform in $manifest_platforms; do
  [[ -f "$workdir/npm/$platform/bin/landstrip" ]] \
    || die "archive is missing the $platform binary"
done
for artifact in "$workdir"/artifacts/*.tar.gz; do
  [[ -f "$artifact" ]] || die "archive carries no darwin release tarball"
  check_sha256 "$artifact"
done

image="$IMAGE_REPOSITORY:$version"
"$CONTAINER" import \
  --change "LABEL org.landstrip.version=$version" \
  --change "LABEL org.landstrip.commit=$head_commit" \
  "$archive" "$image" >/dev/null || die "image import failed"

container_id="$("$CONTAINER" create "$image")" || die "image create failed"
rm -rf "$PREBUILT_ROOT"
mkdir -p "$PREBUILT_ROOT"
for path in npm artifacts manifest; do
  "$CONTAINER" cp "$container_id:/$path" "$PREBUILT_ROOT/" \
    || die "image copy failed: $path"
done
"$CONTAINER" rm -f "$container_id" >/dev/null || die "container removal failed"
container_id=

# package.sh stages a prebuilt platform only with receipts, so rebuild the
# ones the archive did not carry from what the manifest already vouches for.
for artifact in "$PREBUILT_ROOT"/artifacts/*.tar.gz; do
  [[ -f "$artifact" ]] || continue
  if [[ ! -f "$artifact.sha256" ]]; then
    printf '%s  %s\n' "$(sha256_digest "$artifact")" "${artifact##*/}" \
      >"$artifact.sha256"
    printf 'wrote %s.sha256\n' "${artifact##*/}"
  fi
  [[ -f "$artifact.commit" ]] \
    || printf '%s\n' "$head_commit" >"$artifact.commit"
done

printf 'imported %s\n' "$image"
printf 'staged %s in %s\n' "$manifest_platforms" "$PREBUILT_ROOT"
printf 'package the remaining platforms with:\n'
printf '  PLATFORMS="linux-x64 linux-arm64 win32-x64 win32-arm64 %s" \\\n' \
  "$manifest_platforms"
printf '  PREBUILT_ROOT="%s" make package\n' \
  "$(cd "$PREBUILT_ROOT" && pwd)"
