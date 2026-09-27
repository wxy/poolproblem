#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
case "${TMPDIR-}" in /*) ;; *) echo 'TMPDIR must be absolute' >&2; exit 2;; esac
work=$(mktemp -d "${TMPDIR%/}/poolproblem-pnpm-journal.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home/store" "$work/module-cache"
find "$repo/Sources/DiskReservoirCore" -name '*.swift' -print > "$work/sources"
SWIFT_MODULECACHE_PATH="$work/module-cache" CLANG_MODULE_CACHE_PATH="$work/module-cache" swiftc -parse-as-library -o "$work/journal-e2e" $(cat "$work/sources") "$repo/docs/verification/pnpm-owner-recipe/JournalE2E.swift"
HOME="$work/home" FIXTURE_EXECUTABLE="$repo/docs/verification/pnpm-owner-recipe/fixture.sh" "$work/journal-e2e" > "$repo/docs/verification/pnpm-owner-recipe/journal-last-run.log" 2>&1
cat "$repo/docs/verification/pnpm-owner-recipe/journal-last-run.log"
