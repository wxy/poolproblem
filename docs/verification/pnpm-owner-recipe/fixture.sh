#!/bin/sh
set -eu
case "${1-} ${2-}" in
  'store path')
    case "${FIXTURE_MODE-}" in
      invalid) printf '%s\n' / ;;
      changed) if [ -f "$HOME/probed" ]; then printf '%s\n' "$HOME/other-store"; else : > "$HOME/probed"; printf '%s\n' "$HOME/store"; fi ;;
      *) printf '%s\n' "$HOME/store" ;;
    esac ;;
  'store prune')
    printf '%s\n' prune >> "$HOME/invocations"
    if [ "${FIXTURE_MODE-}" = failure ]; then exit 17; fi
    rm -f "$HOME/store/unreferenced-package"
    printf '%s\n' 'Removed unreferenced package' ;;
  *) exit 91 ;;
esac
