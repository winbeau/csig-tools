#!/bin/bash
# Hold / release our H200 cards around the onsite run.
#
#   ./reserve.sh status              what is on every card, and whose it is
#   ./reserve.sh free                indices of fully idle cards
#   ./reserve.sh start 0 1 2 5       one tmux window per card
#   ./reserve.sh drop 2              hand back a single card
#   ./reserve.sh stop                hand back all of them
#   ./reserve.sh run -- <cmd...>     stop, verify released, then run cmd
#
# The package is found by walking up from this script, so the checkout can
# sit anywhere beside or under it and nothing needs editing.
set -u
cd "$(dirname "$0")" || exit 1

SESSION=pilot-reserve
WORKER=reserve.py
VENV=envs/main/.venv/bin/python
GIB=${GIB:-110}
HOURS=${HOURS:-8}

die() { echo "reserve: $*" >&2; exit 1; }

TOOLS=$PWD
ROOT=""
d=$PWD
while [ "$d" != / ]; do
  if [ -x "$d/PILOT_final/$VENV" ]; then ROOT=$d; break; fi
  d=$(dirname "$d")
done
[ -n "$ROOT" ] || die "no package found above $TOOLS (expected PILOT_final/$VENV)"
PKG=$ROOT/PILOT_final
# Everything below is expressed relative to $ROOT and launched after a cd
# there, so `ps` and nvtop show a short command instead of a wall of path.
PY=PILOT_final/$VENV
HERE=${TOOLS#"$ROOT"/}

uuid_of() { nvidia-smi --query-gpu=uuid --format=csv,noheader -i "$1" | tr -d ' '; }
held_cards() { tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | sed -n 's/^gpu//p'; }

cmd_status() {
  apps=$(nvidia-smi --query-compute-apps=pid,gpu_uuid,used_memory --format=csv,noheader)
  echo "card  mem/total MiB      util  holder"
  nvidia-smi --query-gpu=index,uuid,memory.used,memory.total,utilization.gpu \
             --format=csv,noheader,nounits | while IFS=, read -r i u used tot util; do
    i=${i// }; u=${u// }; used=${used// }; tot=${tot// }; util=${util// }
    who="-"
    while IFS=, read -r pid guuid _; do
      [ "${guuid// }" = "$u" ] || continue
      pid=${pid// }
      cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
      case "$cmd" in
        *"$WORKER"*) who="reserved by us" ;;
        *"$PKG"*)    who="our pilot run" ;;
        *)           who="SOMEONE ELSE ($(ps -o user= -p "$pid" 2>/dev/null | tr -d ' '))" ;;
      esac
    done <<< "$apps"
    printf "%-5s %6s/%-6s %6s%%  %s\n" "$i" "$used" "$tot" "$util" "$who"
  done
}

cmd_free() {
  nvidia-smi --query-gpu=index,memory.used,utilization.gpu \
             --format=csv,noheader,nounits | while IFS=, read -r i used util; do
    [ "${used// }" -eq 0 ] && [ "${util// }" -eq 0 ] && printf "%s " "${i// }"
  done
  echo
}

cmd_start() {
  [ $# -gt 0 ] || die "usage: reserve.sh start <card index> [...]  (see: reserve.sh free)"
  tmux has-session -t "$SESSION" 2>/dev/null \
    || tmux new-session -d -s "$SESSION" -n keep 'sleep infinity'
  for i in "$@"; do
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i "$i" 2>/dev/null | tr -d ' ') \
      || { echo "card $i: no such card"; continue; }
    [ -n "$used" ] || { echo "card $i: no such card"; continue; }
    if [ "$used" -gt 100 ]; then
      echo "card $i: busy (${used} MiB) - skipped, check 'reserve.sh status'"; continue
    fi
    if tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "gpu$i"; then
      echo "card $i: already reserved"; continue
    fi
    # cd into the package root, then everything is a short relative path
    tmux new-window -d -t "$SESSION" -n "gpu$i" \
      "cd '$ROOT' && $PY $HERE/$WORKER --index $i --gib $GIB --max-hours $HOURS 2>&1 | tee -a $HERE/reserve.gpu$i.log"
    echo "card $i: reserved"
  done
  sleep 8; cmd_status
}

cmd_drop() {
  [ $# -gt 0 ] || die "usage: reserve.sh drop <card index> [...]"
  for i in "$@"; do
    tmux send-keys -t "$SESSION:gpu$i" C-c 2>/dev/null
    sleep 1
    tmux kill-window -t "$SESSION:gpu$i" 2>/dev/null \
      && echo "card $i: released" || echo "card $i: was not reserved"
  done
}

cmd_stop() {
  cards=$(held_cards)
  if [ -n "$cards" ]; then
    # shellcheck disable=SC2086
    cmd_drop $cards
    tmux kill-session -t "$SESSION" 2>/dev/null
    sleep 3
  else
    echo "nothing reserved"
  fi
  left=$(pgrep -fc "[r]eserve.py" 2>/dev/null || true)
  if [ "${left:-0}" -eq 0 ]; then
    echo "all released"
  else
    echo "WARNING: $left worker(s) still alive"; pgrep -af "[r]eserve.py"
  fi
}

cmd_run() {
  [ "${1:-}" = "--" ] && shift
  [ $# -gt 0 ] || die "usage: reserve.sh run -- <command...>"
  cmd_stop
  left=$(pgrep -fc "[r]eserve.py" 2>/dev/null || true)
  [ "${left:-0}" -eq 0 ] || die "reservations still alive, refusing to start the run"
  echo "reserve: handing over to: $*"
  exec "$@"
}

case "${1:-status}" in
  status) cmd_status ;;
  free)   cmd_free ;;
  start)  shift; cmd_start "$@" ;;
  drop)   shift; cmd_drop "$@" ;;
  stop)   cmd_stop ;;
  run)    shift; cmd_run "$@" ;;
  *)      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
