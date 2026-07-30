#!/usr/bin/env bash
#
# Reproduces git-ai daemon saturation under AGENT-CREW COMMIT STORMS.
#
# Production incident shape (2026-07-30, gt/git-ai fleet): AI agent crews
# maintain local, remoteless git repos as versioned scratchpads
# (~/.claude/crew, <session>/scratchpad/*) and commit at machine speed —
# sub-second spacing, hundreds of commits per hour, several repos in
# parallel. Every commit is traced to the daemon and triggers checkpoint /
# attribution processing. Under sustained storm the daemon's CONTROL SOCKET
# stops answering ("daemon control connection failed" — 501 occurrences over
# a 2h window in the incident telemetry), which stalls the git hooks of
# every OTHER repo on the machine ("blocking all work"), while daemon RSS
# grows. The daemon never crashes — it drowns.
#
# This script builds N synthetic remoteless scratch repos, drives parallel
# high-frequency traced commits into them via an ISOLATED per-run daemon
# (same wiring as the integration harness; nothing touches your real
# git-ai), and measures:
#   - daemon RSS over time (plus spawned git children),
#   - control-plane responsiveness: latency of a traced empty `git commit`
#     probe issued every PROBE_INTERVAL from a SEPARATE quiet repo (the
#     "victim" standing in for the engineer's real repo),
#   - probe failures/timeouts and daemon-log "control connection failed"
#     counts (the exact production signature),
#   - commits issued vs write-ops the daemon managed to log (backlog).
#
# Usage:
#   ./repro.sh                # default scale (~4 min)
#   SCALE=small ./repro.sh    # quick sanity (~90s)
#   SCALE=large ./repro.sh    # sustained storm (~15 min)
#   N_REPOS=5 COMMIT_INTERVAL=0.05 DURATION_SECS=600 ./repro.sh
#
# Knobs:
#   N_REPOS          parallel scratchpad repos with dedicated writers
#   COMMIT_INTERVAL  sleep between commits per writer (seconds, fractional)
#   DURATION_SECS    how long the storm runs
#   LINES_PER_COMMIT appended lines per commit (payload size)
#   PROBE_INTERVAL   seconds between control-plane probes
#   PROBE_TIMEOUT    per-probe timeout before counting a failure
#   KEEP=1           keep workdir + logs
#   GIT_AI_BIN       path to git-ai binary (default: <repo>/target/debug/git-ai)
set -euo pipefail

SCALE="${SCALE:-default}"
case "$SCALE" in
  small)   N_REPOS="${N_REPOS:-2}";  COMMIT_INTERVAL="${COMMIT_INTERVAL:-0.3}";  DURATION_SECS="${DURATION_SECS:-90}";;
  default) N_REPOS="${N_REPOS:-3}";  COMMIT_INTERVAL="${COMMIT_INTERVAL:-0.15}"; DURATION_SECS="${DURATION_SECS:-240}";;
  large)   N_REPOS="${N_REPOS:-5}";  COMMIT_INTERVAL="${COMMIT_INTERVAL:-0.05}"; DURATION_SECS="${DURATION_SECS:-900}";;
  *) echo "Unknown SCALE=$SCALE (small|default|large)"; exit 1;;
esac
LINES_PER_COMMIT="${LINES_PER_COMMIT:-40}"
PROBE_INTERVAL="${PROBE_INTERVAL:-3}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-10}"
KEEP="${KEEP:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GIT_AI_BIN="${GIT_AI_BIN:-$REPO_ROOT/target/debug/git-ai}"
[[ -x "$GIT_AI_BIN" ]] || { echo "error: git-ai binary not found at $GIT_AI_BIN — build first (cargo build --bin git-ai)"; exit 1; }

# --- sanitize PATH: never talk to a system-installed git-ai (mirrors the
# --- daemon-restack-undo-mapping-bomb repro) ---------------------------------
sanitize_path() {
  local out="" dir gitp
  local IFS=':'
  for dir in $PATH; do
    gitp="$dir/git"
    if [[ -f "$gitp" || -L "$gitp" ]]; then
      if [[ -L "$gitp" ]] && readlink "$gitp" | grep -q "git-ai"; then continue; fi
      if grep -q "git-ai" "$gitp" 2>/dev/null; then continue; fi
    fi
    out="${out:+$out:}$dir"
  done
  printf '%s' "$out"
}
SAFE_PATH="$(sanitize_path)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/git-ai-storm.XXXXXX")"
HOME_DIR="$WORK/home"; SOCK_DIR="$WORK/s"
CONTROL_SOCK="$SOCK_DIR/c.sock"; TRACE_SOCK="$SOCK_DIR/t.sock"
DAEMON_LOG="$WORK/daemon.stderr.log"
RSS_LOG="$WORK/rss.log"; PROBE_LOG="$WORK/probe.log"
mkdir -p "$HOME_DIR/.git-ai" "$SOCK_DIR"
(( ${#TRACE_SOCK} < 100 )) || { echo "socket path too long"; exit 1; }

cat > "$HOME_DIR/.gitconfig" <<'EOF'
[user]
	name = Storm Repro
	email = storm@example.com
[init]
	defaultBranch = main
[gc]
	auto = 0
EOF
cat > "$HOME_DIR/.git-ai/config.json" <<'EOF'
{ "telemetry_oss": "off", "disable_version_checks": true, "disable_auto_updates": true }
EOF

COMMON_ENV=( "PATH=$SAFE_PATH" "HOME=$HOME_DIR" "GIT_CONFIG_GLOBAL=$HOME_DIR/.gitconfig" "GIT_CONFIG_NOSYSTEM=1" )
DAEMON_ENV=( "GIT_AI_DAEMON_HOME=$HOME_DIR" "GIT_AI_DAEMON_CONTROL_SOCKET=$CONTROL_SOCK" "GIT_AI_DAEMON_TRACE_SOCKET=$TRACE_SOCK" )

# nesting=0 matches what git-ai installs in production (trace2.eventNesting=0)
tgit() { local repo=$1; shift; env "${COMMON_ENV[@]}" "GIT_TRACE2_EVENT=af_unix:stream:$TRACE_SOCK" "GIT_TRACE2_EVENT_NESTING=0" git -C "$repo" "$@"; }
qgit() { local repo=$1; shift; env "${COMMON_ENV[@]}" git -C "$repo" "$@"; }
gai()  { local repo=$1; shift; (cd "$repo" && env "${COMMON_ENV[@]}" "${DAEMON_ENV[@]}" "$GIT_AI_BIN" "$@"); }

DAEMON_PID=""; SAMPLER_PID=""; PROBER_PID=""; WRITER_PIDS=()
cleanup() {
  for p in "${WRITER_PIDS[@]:-}" "$PROBER_PID" "$SAMPLER_PID"; do [[ -n "${p:-}" ]] && kill "$p" 2>/dev/null || true; done
  if [[ -n "$DAEMON_PID" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill "$DAEMON_PID" 2>/dev/null || true; sleep 1; kill -9 "$DAEMON_PID" 2>/dev/null || true
  fi
  [[ "$KEEP" == "1" ]] && echo "[repro] KEEP=1 — workdir preserved at: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT
log() { printf '[repro] %s\n' "$*"; }

log "workdir: $WORK"
log "scale: SCALE=$SCALE N_REPOS=$N_REPOS COMMIT_INTERVAL=${COMMIT_INTERVAL}s DURATION=${DURATION_SECS}s LINES_PER_COMMIT=$LINES_PER_COMMIT"

# --- daemon ------------------------------------------------------------------
env "${COMMON_ENV[@]}" "${DAEMON_ENV[@]}" "GIT_AI_DEBUG=1" "$GIT_AI_BIN" bg run >/dev/null 2>>"$DAEMON_LOG" &
DAEMON_PID=$!
for _ in $(seq 1 100); do
  [[ -S "$TRACE_SOCK" && -S "$CONTROL_SOCK" ]] && break
  kill -0 "$DAEMON_PID" 2>/dev/null || { echo "daemon died at startup"; tail -20 "$DAEMON_LOG"; exit 1; }
  sleep 0.1
done
log "daemon pid: $DAEMON_PID"

# --- repos: N storm scratchpads (remoteless) + 1 quiet victim ----------------
for i in $(seq 1 "$N_REPOS"); do
  R="$WORK/scratchpad-$i"; mkdir -p "$R"
  qgit "$R" init -q .
  echo "seed" > "$R/notes.md"; qgit "$R" add -A; qgit "$R" commit -qm seed
done
VICTIM="$WORK/victim"; mkdir -p "$VICTIM"
qgit "$VICTIM" init -q .
echo "seed" > "$VICTIM/work.txt"; qgit "$VICTIM" add -A; qgit "$VICTIM" commit -qm seed
log "created $N_REPOS storm repos + 1 victim repo (all remoteless)"

# --- RSS sampler (daemon + direct children) ----------------------------------
(
  while kill -0 "$DAEMON_PID" 2>/dev/null; do
    ps -axo pid=,ppid=,rss= | awk -v d="$DAEMON_PID" -v t="$(date +%s)" '
      $1 == d { drss = $3 } $2 == d { crss += $3 }
      END { printf "%s %d %d\n", t, drss, crss }' >> "$RSS_LOG"
    sleep 1
  done
) & SAMPLER_PID=$!
BASELINE_KB="$(ps -o rss= -p "$DAEMON_PID" | tr -d ' ')"

# --- control-plane prober: checkpoint in the quiet victim repo ---------------
# Stand-in for "an engineer's normal git/git-ai operation on an unrelated
# repo". Latency + failures here == the production "blocking all work".
# perl for sub-second timestamps: ubiquitous, no version-manager shims that
# can stall inside command substitutions (pyenv shims do, badly)
now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time'; }
(
  while :; do
    t0=$(now)
    if timeout "$PROBE_TIMEOUT" env "${COMMON_ENV[@]}" \
        "GIT_TRACE2_EVENT=af_unix:stream:$TRACE_SOCK" "GIT_TRACE2_EVENT_NESTING=0" \
        git -C "$VICTIM" commit -q --allow-empty -m probe >/dev/null 2>&1; then
      status=ok
    else
      status=FAIL
    fi
    t1=$(now)
    echo "$t0 $t1 $status" >> "$PROBE_LOG"
    sleep "$PROBE_INTERVAL"
  done
) & PROBER_PID=$!

# --- pre-storm baseline: probe latency against an idle daemon ----------------
BASELINE_SECS="${BASELINE_SECS:-20}"
log "measuring ${BASELINE_SECS}s probe baseline before the storm ..."
sleep "$BASELINE_SECS"

# --- the storm ----------------------------------------------------------------
writer() {
  local repo=$1 idx=$2 n=0 j
  local deadline=$(( SECONDS + DURATION_SECS ))
  while (( SECONDS < deadline )); do
    for j in $(seq 1 "$LINES_PER_COMMIT"); do
      echo "agent $idx step $n line $j :: payload-payload-payload" >> "$repo/notes.md"
    done
    tgit "$repo" add -A >/dev/null 2>&1 || true
    tgit "$repo" commit -qm "agent step $n" >/dev/null 2>&1 || true
    n=$((n+1))
    sleep "$COMMIT_INTERVAL"
  done
  echo "$n" > "$repo/.commits_issued"
}
log "starting $N_REPOS parallel writers for ${DURATION_SECS}s ..."
STORM_START=$(date +%s)
for i in $(seq 1 "$N_REPOS"); do
  writer "$WORK/scratchpad-$i" "$i" & WRITER_PIDS+=($!)
done
wait "${WRITER_PIDS[@]}"
WRITER_PIDS=()
STORM_END=$(date +%s)
log "storm finished; letting the daemon drain for 30s"
sleep 30
kill "$PROBER_PID" 2>/dev/null || true; wait "$PROBER_PID" 2>/dev/null || true; PROBER_PID=""
kill "$SAMPLER_PID" 2>/dev/null || true; wait "$SAMPLER_PID" 2>/dev/null || true; SAMPLER_PID=""

# --- results ------------------------------------------------------------------
# The daemon logs to files under its daemon home, not stderr.
FILE_LOGS=( "$HOME_DIR"/.git-ai/internal/daemon/logs/*.log )
[[ -f "${FILE_LOGS[0]}" ]] && DAEMON_LOG="${FILE_LOGS[0]}"
ISSUED=0
for i in $(seq 1 "$N_REPOS"); do
  ISSUED=$(( ISSUED + $(cat "$WORK/scratchpad-$i/.commits_issued" 2>/dev/null || echo 0) ))
done
# split write-ops by repo: probe commits in the victim are write ops too
LOGGED_OPS="$(grep 'git write op completed' "$DAEMON_LOG" 2>/dev/null | grep -c scratchpad || true)"
VICTIM_OPS="$(grep 'git write op completed' "$DAEMON_LOG" 2>/dev/null | grep -c victim || true)"
# On current main (observed on macOS), the daemon rejects every control
# connection with EINVAL ("failed setting daemon control receive timeout:
# Invalid argument") — its own 30s health check trips it constantly. Count
# that artifact separately so it can't masquerade as a saturation signal.
CTRL_FAILS_EINVAL="$(grep -i 'control connection failed' "$DAEMON_LOG" 2>/dev/null | grep -c 'Invalid argument' || true)"
CTRL_FAILS="$(grep -i 'control connection failed' "$DAEMON_LOG" 2>/dev/null | grep -cv 'Invalid argument' || true)"
ERRORS="$(grep 'ERROR' "$DAEMON_LOG" 2>/dev/null | grep -cv 'Invalid argument' || true)"
PEAK_KB="$(awk 'BEGIN{m=0}{if($2>m)m=$2}END{print m}' "$RSS_LOG")"
PEAK_CHILD_KB="$(awk 'BEGIN{m=0}{if($3>m)m=$3}END{print m}' "$RSS_LOG")"
PROBES=$(wc -l < "$PROBE_LOG" | tr -d ' ')
PROBE_FAILS=$(grep -c FAIL "$PROBE_LOG" || true)
probe_stats() { # $1=lo epoch, $2=hi epoch (probe counted if it STARTED in [lo,hi))
  awk -v lo="$1" -v hi="$2" '$1>=lo && $1<hi && $3=="ok"{d=$2-$1; s+=d; n++; if(d>mx)mx=d}
    $1>=lo && $1<hi && $3=="FAIL"{f++}
    END{if(n)printf "avg %.2fs max %.2fs over %d ok (%d FAIL)", s/n, mx, n, f+0;
        else printf "no ok-probes (%d FAIL)", f+0}' "$PROBE_LOG"
}
BASELINE_STATS="$(probe_stats 0 "$STORM_START")"
STORM_STATS="$(probe_stats "$STORM_START" 9999999999)"

echo
echo "================================ RESULTS ================================"
echo "storm:                 $N_REPOS repos x ${COMMIT_INTERVAL}s interval x ${DURATION_SECS}s = $ISSUED commits issued ($(( ISSUED * 60 / (STORM_END - STORM_START) ))/min)"
echo "daemon write-ops seen: ${LOGGED_OPS:-0} storm + ${VICTIM_OPS:-0} victim   (storm backlog = issued - seen; drain window 30s)"
echo "control probe:         $PROBES probes, $PROBE_FAILS failures/timeouts total"
echo "  idle baseline:       $BASELINE_STATS"
echo "  during storm+drain:  $STORM_STATS"
echo "daemon log:            ${CTRL_FAILS:-0} 'control connection failed', ${ERRORS:-0} ERROR lines (excl. macOS EINVAL artifact: ${CTRL_FAILS_EINVAL:-0})"
echo "daemon RSS:            baseline $(( BASELINE_KB / 1024 )) MB -> peak $(( PEAK_KB / 1024 )) MB (delta +$(( (PEAK_KB - BASELINE_KB) / 1024 )) MB)"
echo "peak child git RSS:    $(( PEAK_CHILD_KB / 1024 )) MB"
echo "========================================================================="
echo "saturation signals: write-op backlog growth (issued far exceeds seen),"
echo "daemon RSS monotonic growth while the storm runs, 'trace ingest queue"
echo "is full' ERRORs (events dropped => attribution lost), probe latency"
echo "growth/failures. Incident telemetry being reproduced: 501 control"
echo "failures over 2h, ~250 commits/hour into crew scratchpads, RSS growth,"
echo "no crash. NOTE: on macOS the control-failure count is masked by the"
echo "EINVAL artifact above — rely on backlog/RSS/ingest-full instead."
