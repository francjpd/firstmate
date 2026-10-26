Mode: agy / agy2 Stop-hook-owned turn-end signalling.

When this session owns supervision or supervises an agy/agy2 worker or agy2 secondmate and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Worker and secondmate turn ends are signalled through the `Stop` lifecycle hook in `.agents/hooks.json`.
   The hook command executes when the agent execution loop terminates, calling `bin/fm-busy-event.sh apply <state> <id> idle --gen <gen> --source agy-hook --event stop` to record an honest turn-end verdict.
   Hook commands run with current working directory set to `.agents/`, so all invoked script paths and state arguments are absolute.
3. Honest classification distinguishes proven state from inferred rendered tails.
   A recorded `idle agy-hook` event proves the turn has completed.
   Untrusted records or panes running without the hook fall back to rendered-tail inspection and report `unknown agy-regex` rather than inventing `idle`.
   Supervision never treats `unknown` alone as a stopped worker.
4. Steering messages are delivered via the worker's steering inbox (`state/<id>.inbox`).
   `bin/fm-send.sh` delivers typed text to the target pane with an agy2-tuned retry budget.
5. Workspace trust is pre-registered during spawn.
   For worktrees, `bin/fm-agy-trust.sh` pre-approves the worktree in the harness state store.
   For an agy2 secondmate, `bin/fm-agy-trust.sh --secondmate-home <home> <id>` pre-registers the isolated secondmate home in agy2's store without touching the captain's fleet config or keyring.
6. Teardown removes Firstmate-generated hooks cleanly.
   Teardown strips the `firstmate` block from `.agents/hooks.json`.
   If no other hooks remain, `.agents/hooks.json` is unlinked and empty `.agents/` directories are removed.
7. Autonomous primary session rewake via supervision watchdog daemon and doorbells.
   To eliminate dead supervision episodes when the watcher exits on actionable wakes, run the persistent supervisor watchdog daemon:
   `bin/fm-supervision-watchdog.sh start` (or `bin/fm-watchdog.sh start`).
   The watchdog daemon keeps `bin/fm-watch.sh` continuously armed and self-healing. When actionable wakes arrive, the watcher terminates and the watchdog daemon:
   a. Immediately rings the primary supervisor pane doorbell (e.g. `w44:p1` or tmux pane via `bin/fm-procevent-doorbell.sh` / terminal injection).
   b. Immediately re-arms a fresh watcher cycle so supervision never lapses.
   Check status with `bin/fm-supervision-watchdog.sh status` and stop with `bin/fm-supervision-watchdog.sh stop`.
