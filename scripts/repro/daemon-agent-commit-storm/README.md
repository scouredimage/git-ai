# Repro: daemon saturation under agent-crew commit storms

Minimal, fully synthetic reproduction of a production incident (2026-07-30)
where the git-ai daemon became unresponsive — control socket refusing
connections for two hours, memory growing, every git command on the machine
stalling — under the commit load of AI **agent crews**.

## The production shape

AI agent orchestration ("crews") keeps coordination state in **local,
remoteless git repos** used as versioned scratchpads (`~/.claude/crew`,
`<claude-session-tmp>/scratchpad/*`). Agents commit every state change:
sub-second spacing, bursts of 10+ commits/minute, several repos in parallel,
~250 commits/hour sustained in the incident telemetry. Each commit is traced
to the daemon (trace2) and triggers checkpoint/attribution processing.

Two compounding factors:

1. **No gating**: `allow_repositories` matches remote URLs, so remoteless
   local repos bypass it entirely — the daemon does full attribution work on
   repos that can never produce attributable PRs (the incident telemetry
   even shows `/opt/homebrew` taps being processed).
2. **No backpressure**: under sustained load the control socket's accept
   path starves. Incident daemon log: 501 × `daemon control connection
   failed` over a 2h window. That converts "daemon busy" into "every git
   hook on the machine times out" — the user-visible "blocking all work".

The daemon never crashes; it drowns. A force-quit then destroys the
unshipped telemetry buffer, which is why fleet logs show the collapse only
by absence.

## What the script does

- Isolated per-run daemon (own HOME/sockets; mirrors the harness and the
  sibling `daemon-restack-undo-mapping-bomb` repro — your real git-ai is
  untouched).
- N remoteless scratch repos with parallel writers committing at
  `COMMIT_INTERVAL` for `DURATION_SECS`.
- A quiet **victim repo** issuing a traced empty `git commit` probe every
  few seconds — the stand-in for an engineer's normal work. Probe latency
  and failures are the user-facing damage metric.
- Samples daemon (and child-git) RSS once a second.
- Reports: commits issued vs write-ops the daemon logged (backlog), probe
  latency/failures, `control connection failed` counts, RSS curve peaks.

## Usage

```
cargo build --bin git-ai
./repro.sh                 # ~4 min
SCALE=small ./repro.sh     # ~90s sanity
SCALE=large ./repro.sh     # ~15 min sustained storm
N_REPOS=5 COMMIT_INTERVAL=0.05 DURATION_SECS=600 ./repro.sh
```

## Measured results (release build, macOS/arm64, current main)

Default scale — 3 repos, 0.15s interval, 240s:

```
storm:                 419 commits issued (104/min)
daemon write-ops seen: 15 storm + 7 victim     <- 3.6% processed; 404-op backlog
daemon log:            2 'trace ingest queue is full' ERRORs (events DROPPED)
daemon RSS:            baseline 11 MB -> peak 64 MB (~22 MB/min, monotonic
                       while the storm runs, partial recovery on drain)
control probe:         idle avg 0.75s -> storm avg 1.17s
```

The daemon processes roughly one write op per 5–6s while commits arrive
every ~1.5s. Three signals reproduce the incident shape directly:

1. **Backlog**: the daemon falls behind almost immediately and never
   catches up during the run.
2. **RSS growth, no crash**: memory tracks queue depth (~22 MB/min here;
   at the incident's sustained multi-hour rate this reaches GBs).
3. **`trace ingest queue is full`**: the overflow path drops events —
   which is silent attribution loss for whatever else the user commits
   during the storm.

At this scale probe latency only degrades ~50% with zero failures — the
full control-plane starvation in the incident took hours of sustained
load. Backlog/RSS/ingest-full are the early, fast-reproducing signals.

## Known measurement caveat on macOS

On current main the daemon rejects **every** control connection with
`failed setting daemon control receive timeout: Invalid argument (os
error 22)` (`handle_control_connection_actor` → `set_recv_timeout`), and
its own 30s socket health check trips this constantly. Fleet v1.6.17
daemon logs don't show it. Until that's fixed, the `control connection
failed` count on macOS is an artifact, not a saturation signal — the
script counts it separately.

## Fix directions this repro is meant to validate

1. **Gate remoteless/unknown repos**: apply `allow_repositories` (or an
   explicit exclude) to repos without a matching remote; make the storm
   repos invisible and the probe stays flat.
2. **Backpressure/coalescing**: debounce per-repo checkpoint work and keep
   the control-socket accept loop responsive under queue pressure (shed
   attribution work, never connectivity).
3. Client-side workaround (validated in the incident): per-repo
   `git config trace2.eventTarget ""` in scratch repos silences them
   without touching real repos.
