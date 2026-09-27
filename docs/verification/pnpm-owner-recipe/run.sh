#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
case "${TMPDIR-}" in /*) ;; *) echo 'TMPDIR must be an absolute system temporary directory' >&2; exit 2;; esac
work=$(mktemp -d "${TMPDIR%/}/poolproblem-pnpm-owner.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home" "$work/artifacts"
find "$repo/Sources/DiskReservoirCore" -name '*.swift' -print > "$work/sources"
mkdir -p "$work/module-cache"
SWIFT_MODULECACHE_PATH="$work/module-cache" CLANG_MODULE_CACHE_PATH="$work/module-cache" swiftc -parse-as-library -o "$work/owner-e2e" $(cat "$work/sources") "$repo/docs/verification/pnpm-owner-recipe/OwnerCommandE2E.swift"
cc -Wall -Wextra -o "$work/timeout-fixture" "$repo/docs/verification/pnpm-owner-recipe/timeout-fixture.c"
HOME="$work/home" TIMEOUT_FIXTURE_EXECUTABLE="$work/timeout-fixture" FIXTURE_EXECUTABLE="$repo/docs/verification/pnpm-owner-recipe/fixture.sh" "$work/owner-e2e" > "$repo/docs/verification/pnpm-owner-recipe/last-run.log" 2>&1
cat "$repo/docs/verification/pnpm-owner-recipe/last-run.log"
