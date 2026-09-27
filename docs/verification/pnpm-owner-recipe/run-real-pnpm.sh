#!/bin/sh
set -eu

case "${TMPDIR-}" in /*) ;; *) echo 'TMPDIR must be an absolute system temporary directory' >&2; exit 2 ;; esac
pnpm_bin=$(command -v pnpm)
case "$pnpm_bin" in /*) ;; *) echo 'pnpm must resolve to an absolute executable path' >&2; exit 2 ;; esac

work=$(mktemp -d "${TMPDIR%/}/poolproblem-real-pnpm.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home" "$work/config" "$work/data" "$work/cache" "$work/pnpm"

run_pnpm() {
    env -i HOME="$work/home" TMPDIR="$work" \
        XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" XDG_CACHE_HOME="$work/cache" \
        PNPM_HOME="$work/pnpm" npm_config_userconfig="$work/home/.npmrc" \
        PATH="$(dirname "$pnpm_bin"):/usr/bin:/bin" "$pnpm_bin" "$@"
}

store=$(cd "$work/home" && run_pnpm store path)
case "$store" in
    "$work"/*) ;;
    *) echo "Refusing prune: pnpm store is outside isolated fixture: $store" >&2; exit 3 ;;
esac

echo "pnpm executable: $pnpm_bin"
echo "isolated store: $store"
mkdir -p "$store"
echo "store size before prune: $(du -sk "$store" | cut -f1) KiB"
(cd "$work/home" && run_pnpm store prune)
echo "store size after prune: $(du -sk "$store" | cut -f1) KiB"
echo 'PASS real pnpm prune completed on the isolated temporary store'
