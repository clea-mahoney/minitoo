#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/clauddy-lib.sh"

clauddy_load_config ~/.clauddy/config
clauddy_lock_acquire_or_die "reupload-faces.sh" "${CLAUDDY_LOCK_WAIT:-30}"

states=("$@")
if [ "${#states[@]}" -eq 0 ]; then
  states=(chilling working alerting)
fi

for state in "${states[@]}"; do
  case "$state" in
    chilling|working|alerting) ;;
    *) clauddy_die "unknown state '$state'. Expected: chilling, working, alerting." ;;
  esac
  echo "=== $state -> ClockId=$(clauddy_state_clock_id "$state") StyleId=$(clauddy_state_style_id "$state") ==="
  clauddy_reupload_face "$state"
done

for state in "${states[@]}"; do
  rm -f "$(clauddy_foreign_marker "$state")"
done

echo "REUPLOAD DONE"
