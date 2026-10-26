#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) Jarkko Sakkinen 2026
#
# Export the darwin release outputs as a container image archive, so a Linux
# host can package every platform without a macOS toolchain:
#
#   macOS:  ./scripts/container-export-darwin.sh
#   Linux:  ./scripts/container-import-darwin.sh dist/landstrip-darwin-<version>.tar
#
# The archive is a root filesystem holding what `make package` publishes for
# darwin-arm64 and darwin-x64: the ad-hoc signed binary in the npm package tree
# and the release tarball with its receipts. Importing it creates a container
# image with those files, and the importing host stages them with PREBUILT_ROOT.
# No container runtime is needed here, only on the importing host.
#
#   PLATFORMS  darwin platforms to export (default: darwin-arm64 darwin-x64)

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)" \
  || { printf 'not inside a Git repository\n' >&2; exit 1; }
cd "$repo_root"

# shellcheck source=sha256.sh
source "$script_dir/sha256.sh"

NODE="${NODE:-node}"
PLATFORMS="${PLATFORMS:-darwin-arm64 darwin-x64}"

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

[[ "$(uname -s)" == Darwin ]] \
  || die "run this script on macOS: darwin release outputs need its signing step"
for command in "$NODE" git tar; do
  require_command "$command"
done

workdir="$(mktemp -d)"
cleanup() {
  local status=$?

  rm -rf "$workdir"
  return "$status"
}
trap cleanup EXIT

printf '==> packaging %s on this host\n' "$PLATFORMS"
# shellcheck disable=SC2086
NODE="$NODE" PACKAGE_STRICT=1 \
  "$script_dir/../packages/landstrip/scripts/package.sh" $PLATFORMS

version="$("$NODE" -p "require('./packages/landstrip-cli/package.json').version")"
head_commit="$(git rev-parse HEAD)"
rootfs="$workdir/rootfs"
mkdir -p "$rootfs/artifacts"

for platform in $PLATFORMS; do
  binary="npm/$platform/bin/landstrip"
  artifact="artifacts/landstrip-$version-$platform.tar.gz"

  for path in "$binary" "$artifact" "$artifact.sha256" "$artifact.commit"; do
    [[ -f "$path" ]] || die "missing release output: $path"
  done
  mkdir -p "$rootfs/npm/$platform/bin"
  cp "$binary" "$rootfs/npm/$platform/bin/landstrip"
  cp "$artifact" "$artifact.sha256" "$artifact.commit" "$rootfs/artifacts/"
done

printf 'version %s\ncommit %s\nplatforms %s\n' \
  "$version" "$head_commit" "$PLATFORMS" >"$rootfs/manifest"

archive="dist/landstrip-darwin-$version.tar"
mkdir -p dist
# macOS tar records com.apple.* xattrs and AppleDouble forks by default, which
# Linux tar implementations refuse to restore. Ship plain files only.
tar --no-xattrs --no-mac-metadata -C "$rootfs" -cf "$archive" .
write_sha256_sidecar "$archive"

printf 'exported %s\n' "$archive"
printf 'sha256   %s\n' "$(sha256_digest "$archive")"
printf 'run scripts/container-import-darwin.sh %s on the packaging host\n' \
  "$archive"
