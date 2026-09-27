#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
case "${TMPDIR-}" in /*) ;; *) echo 'TMPDIR must be absolute' >&2; exit 2;; esac
work=$(mktemp -d "${TMPDIR%/}/poolproblem-pnpm-readonly-probe.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/module-cache"
rg --files "$repo/Sources/DiskReservoirCore" -g '*.swift' > "$work/sources"
SWIFT_MODULECACHE_PATH="$work/module-cache" CLANG_MODULE_CACHE_PATH="$work/module-cache" \
  swiftc -parse-as-library -suppress-warnings -o "$work/probe" $(cat "$work/sources") \
  "$repo/docs/verification/pnpm-owner-recipe/ReadOnlyRealProbe.swift"
"$work/probe"
