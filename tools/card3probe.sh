#!/bin/bash
# Sample one card every 30 s and label each compute app ours / foreign.
#
#   ./card3probe.sh <card index> [seconds]
#
# The box is a shared *account*, so a username does not tell you whose
# process it is - the command line does. Anything running out of the
# package tree is ours, anything else is not.
set -u
cd "$(dirname "$0")" || exit 1

IDX=${1:?usage: card3probe.sh <card index> [seconds]}
EVERY=${2:-30}

# Walk up from here to find the package, so this works from the repo
# checkout or from beside the package itself.
pkg=""
d=$PWD
while [ "$d" != / ]; do
  if [ -d "$d/PILOT_final" ]; then pkg="$d/PILOT_final"; break; fi
  d=$(dirname "$d")
done
[ -n "$pkg" ] && echo "# ours = anything under $(basename "$pkg")/" || echo "# no package found; nothing will be labelled OURS"

UUID=$(nvidia-smi --query-gpu=uuid --format=csv,noheader -i "$IDX" | tr -d ' ') \
  || { echo "no such card: $IDX" >&2; exit 1; }
echo "# card $IDX = $UUID, sampling every ${EVERY}s"

while true; do
  printf "%s mem/util: %s |" "$(date -u +%H:%M:%S)" \
    "$(nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader -i "$IDX")"
  nvidia-smi --query-compute-apps=pid,gpu_uuid,used_memory --format=csv,noheader \
    | grep "$UUID" | while IFS=, read -r p _ m; do
        pid=$(echo "$p" | tr -d ' ')
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-60)
        if   [ -z "$cmd" ];                             then own=GONE
        elif [ -n "$pkg" ] && [ "${cmd#*$pkg}" != "$cmd" ]; then own=OURS
        else own='***FOREIGN***'
        fi
        printf ' [%s %s %s | %s]' "$pid" "$(echo "$m" | tr -d ' ')" "$own" "$cmd"
      done
  echo
  sleep "$EVERY"
done
