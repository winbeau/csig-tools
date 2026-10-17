# H200 operator tools

Small helpers used around the CSIG 2026 finals onsite run on the shared
H200 box. None of them touch the competition package, its configs or the
method — they only verify, observe, or hold cards.

| file | what it does |
|---|---|
| `verify_manifest.py` | Checks every file of a downloaded package against `MANIFEST.sha256` (size + sha256, 12 threads) and prints the manifest's own digest. |
| `reserve.sh` | Holds / releases our allocated cards around a run. One tmux window per card, so a single card can be handed back without touching the others. |
| `reserve.py` | The per-card worker `reserve.sh` launches. Holds ballast memory and runs a matmul loop; releases on SIGTERM and unconditionally after `--max-hours`. |
| `card3probe.sh` | `./card3probe.sh <card index> [seconds]` — samples one card and labels each compute app ours / foreign. The box is a shared *account*, so a username does not tell you whose process it is — the command line does. |

## reserve.sh

```
./reserve.sh status            what is on every card, and whose it is
./reserve.sh free              indices of fully idle cards
./reserve.sh start 0 1 2 5     reserve these cards
./reserve.sh drop 2            hand back one card
./reserve.sh stop              hand back all of them
./reserve.sh run -- <cmd...>   stop, verify released, then run cmd
```

`run` is the one to use when the real job starts: it refuses to launch if
any reservation is still alive, so a forgotten holder cannot end up
competing with the run for the same card.

Both scripts walk up from their own directory looking for `PILOT_final`,
and launch through the relative venv path
(`PILOT_final/envs/main/.venv/bin/python`). So the checkout can sit beside
the package or under it, and nothing needs editing — there are no absolute
paths or machine names anywhere in here.

Each reserved card gets its own tmux window in the `pilot-reserve` session:

```
tmux attach -t pilot-reserve     # watch them
tmux kill-window -t pilot-reserve:gpu2
```

## Notes

- Card indices shift across reboots; both these tools and the onsite run
  pin cards by UUID. `--index` is resolved to a UUID at startup.
- `reserve.sh` has an 8 h dead-man switch by default (`HOURS=` to change),
  so a reservation nobody remembers still frees itself.
- Reserving cards is visible to everyone else on the box. Tell the team
  which cards you are holding and why.
