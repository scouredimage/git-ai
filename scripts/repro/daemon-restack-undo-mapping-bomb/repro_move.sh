#!/usr/bin/env bash
#
# Reproduces the git-ai daemon memory blowup on a "restack undo" — moving a
# branch ref from a rebased tip back to its pre-rebase tip via
# `git reset --keep <old-tip>` (exactly what Graphite runs when undoing /
# aborting a restack). NOTE: `reset --hard` does NOT reproduce this — the
# daemon's ResetKind::Hard arm only deletes the working log; the non-fast-
# forward rewrite path fires for the non-hard reset kinds (daemon.rs Reset
# handling).
#
# This fires DESPITE the streaming diff-tree fix ("Fix high memory usage on
# large rebases"): the raw patch text is no longer buffered, but the daemon
# still materializes one parsed DiffTreeResult per mapping, and the mapping
# count is unbounded (see README.md in this directory):
#
#   parse_range_diff_output (src/authorship/rewrite.rs) maps EVERY unmatched
#   `<` commit in the range-diff to a commit of the new range. For a restack
#   undo, the old range (merge-base..rebased-tip) contains every trunk commit
#   since the branch forked — thousands on a busy monorepo — and on a fleet
#   where every commit has an authorship note, each one becomes a
#   (trunk_commit, stack_commit) full-root-tree diff pair. Each pair's diff
#   REVERSES the whole trunk delta, so its '+' lines are the pre-fork content
#   of every line the trunk modified, and the parsed per-pair structures
#   (added_lines_by_file: one u32 per '+' line) accumulate:
#
#     daemon RSS  ~=  (trunk commits since fork) x (lines modified on trunk) x ~12B
#
# This script builds a fully synthetic repo, drives a real rebase + reset
# through an ISOLATED per-run daemon (same wiring as the integration-test
# harness; nothing installed system-wide), samples daemon RSS during rewrite
# processing, and prints the peak alongside ground-truth mapping count and
# per-pair diff size.
#
# Usage:
#   ./repro.sh                 # default scale (several-hundred-MB peak, a few minutes)
#   SCALE=small ./repro.sh     # quick sanity run (~2 min)
#   SCALE=large ./repro.sh     # multi-GB peak (long runtime)
#   TRUNK_COMMITS=600 BASE_FILES=80 LINES_PER_FILE=1000 ./repro.sh   # custom
#
# Knobs (env vars):
#   STACK_COMMITS    feature-branch commits with real AI authorship notes
#   TRUNK_COMMITS    commits on main after the fork; EVERY one gets an
#                    authorship note (models an org-wide notes fleet) and each
#                    becomes one bogus mapping = one full-root-tree diff pair
#   BASE_FILES       pre-fork files that the first trunk commit rewrites
#   LINES_PER_FILE   lines per pre-fork file; every line is modified on trunk,
#                    so per-pair '+' lines = BASE_FILES * LINES_PER_FILE
#   PROCESS_TIMEOUT_SECS  how long to wait for the daemon to finish (default 1800)
#   KEEP=1           keep the temp workdir + daemon logs
#   GIT_AI_BIN       path to a git-ai binary (default: <repo>/target/debug/git-ai)
#
# Expected mappings            ~= TRUNK_COMMITS (+ STACK_COMMITS real ones)
# Expected per-pair '+' lines  ~= BASE_FILES * LINES_PER_FILE
# Expected daemon RSS delta    ~= mappings * plus_lines * ~12B
set -euo pipefail

# ---------------------------------------------------------------------------
# Knobs
# ---------------------------------------------------------------------------
SCALE="${SCALE:-default}"
case "$SCALE" in
  small)
    STACK_COMMITS="${STACK_COMMITS:-4}"
    TRUNK_COMMITS="${TRUNK_COMMITS:-150}"
    BASE_FILES="${BASE_FILES:-25}"
    LINES_PER_FILE="${LINES_PER_FILE:-400}"
    ;;
  default)
    STACK_COMMITS="${STACK_COMMITS:-4}"
    TRUNK_COMMITS="${TRUNK_COMMITS:-600}"
    BASE_FILES="${BASE_FILES:-80}"
    LINES_PER_FILE="${LINES_PER_FILE:-1000}"
    ;;
  large)
    STACK_COMMITS="${STACK_COMMITS:-4}"
    TRUNK_COMMITS="${TRUNK_COMMITS:-1200}"
    BASE_FILES="${BASE_FILES:-100}"
    LINES_PER_FILE="${LINES_PER_FILE:-1500}"
    ;;
  *) echo "Unknown SCALE=$SCALE (small|default|large)"; exit 1 ;;
esac
PROCESS_TIMEOUT_SECS="${PROCESS_TIMEOUT_SECS:-1800}"
KEEP="${KEEP:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GIT_AI_BIN="${GIT_AI_BIN:-$REPO_ROOT/target/debug/git-ai}"

if [[ ! -x "$GIT_AI_BIN" ]]; then
  echo "error: git-ai binary not found at $GIT_AI_BIN — run 'task build' first (or set GIT_AI_BIN)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Sanitize PATH: drop any dir whose `git` is actually a git-ai wrapper, so the
# repro never talks to a system-installed git-ai (mirrors the test harness).
# ---------------------------------------------------------------------------
sanitize_path() {
  local out="" dir gitp
  local IFS=':'
  for dir in $PATH; do
    gitp="$dir/git"
    if [[ -f "$gitp" || -L "$gitp" ]]; then
      if [[ -L "$gitp" ]] && readlink "$gitp" | grep -q "git-ai"; then continue; fi
      if grep -q "git-ai" "$gitp" 2>/dev/null; then continue; fi
      local canon
      canon="$(cd "$(dirname "$gitp")" 2>/dev/null && pwd -P)/$(basename "$gitp")" || canon="$gitp"
      if [[ "$canon" == *git-ai* ]]; then continue; fi
    fi
    out="${out:+$out:}$dir"
  done
  printf '%s' "$out"
}
SAFE_PATH="$(sanitize_path)"

# ---------------------------------------------------------------------------
# Isolated workspace: repo + fake HOME + per-run daemon sockets
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/git-ai-bomb.XXXXXX")"
HOME_DIR="$WORK/home"
REPO="$WORK/repo"
SOCK_DIR="$WORK/s"
CONTROL_SOCK="$SOCK_DIR/c.sock"
TRACE_SOCK="$SOCK_DIR/t.sock"
TEST_DB="$WORK/git-ai-test-db"
RSS_LOG="$WORK/rss.log"
DAEMON_LOG="$WORK/daemon.stderr.log"
mkdir -p "$HOME_DIR/.git-ai" "$REPO" "$SOCK_DIR"

if (( ${#TRACE_SOCK} >= 100 )); then
  echo "error: socket path too long for AF_UNIX: $TRACE_SOCK" >&2
  exit 1
fi

cat > "$HOME_DIR/.gitconfig" <<'EOF'
[user]
	name = Repro User
	email = repro@example.com
[init]
	defaultBranch = main
[gc]
	auto = 0
[advice]
	detachedHead = false
EOF
# Keep the isolated git-ai fully offline / defaults (local git_notes backend).
cat > "$HOME_DIR/.git-ai/config.json" <<'EOF'
{
  "telemetry_oss": "off",
  "disable_version_checks": true,
  "disable_auto_updates": true
}
EOF

COMMON_ENV=(
  "PATH=$SAFE_PATH"
  "HOME=$HOME_DIR"
  "GIT_CONFIG_GLOBAL=$HOME_DIR/.gitconfig"
  "GIT_CONFIG_NOSYSTEM=1"
  "XDG_CONFIG_HOME=$HOME_DIR/.config"
)
DAEMON_ENV=(
  "GIT_AI_DAEMON_HOME=$HOME_DIR"
  "GIT_AI_DAEMON_CONTROL_SOCKET=$CONTROL_SOCK"
  "GIT_AI_DAEMON_TRACE_SOCKET=$TRACE_SOCK"
  "GIT_AI_TEST_DB_PATH=$TEST_DB"
  "GITAI_TEST_DB_PATH=$TEST_DB"
)

# Real git wired to the per-run daemon via trace2 (exactly how production learns
# about git commands — git-ai does NOT wrap git).
tgit() {
  env "${COMMON_ENV[@]}" \
    "GIT_TRACE2_EVENT=af_unix:stream:$TRACE_SOCK" \
    "GIT_TRACE2_EVENT_NESTING=10" \
    git -C "$REPO" "$@"
}
# git without trace2 (setup plumbing we don't want the daemon to see/process).
qgit() {
  env "${COMMON_ENV[@]}" git -C "$REPO" "$@"
}
gai() {
  (cd "$REPO" && env "${COMMON_ENV[@]}" "${DAEMON_ENV[@]}" "$GIT_AI_BIN" "$@")
}

DAEMON_PID=""
SAMPLER_PID=""
cleanup() {
  [[ -n "$SAMPLER_PID" ]] && kill "$SAMPLER_PID" 2>/dev/null || true
  if [[ -n "$DAEMON_PID" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill "$DAEMON_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$DAEMON_PID" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$DAEMON_PID" 2>/dev/null || true
  fi
  if [[ "$KEEP" == "1" ]]; then
    echo "[repro] KEEP=1 — workdir preserved at: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

log() { printf '[repro] %s\n' "$*"; }

PLUS_LINES_PER_PAIR=$(( BASE_FILES * LINES_PER_FILE ))
log "workdir: $WORK"
log "scale: SCALE=$SCALE STACK_COMMITS=$STACK_COMMITS TRUNK_COMMITS=$TRUNK_COMMITS BASE_FILES=$BASE_FILES LINES_PER_FILE=$LINES_PER_FILE"
log "expected: ~$TRUNK_COMMITS bogus mappings x ~$PLUS_LINES_PER_PAIR '+' lines/pair -> parsed structures ~$(( TRUNK_COMMITS * PLUS_LINES_PER_PAIR * 12 / 1048576 )) MB"

# ---------------------------------------------------------------------------
# Start the isolated daemon (GIT_AI_DEBUG=1 so the daemon log records
# "shift_authorship_notes: N mappings" — direct proof of the mapping bomb).
# ---------------------------------------------------------------------------
env "${COMMON_ENV[@]}" "${DAEMON_ENV[@]}" "GIT_AI_DEBUG=1" "$GIT_AI_BIN" bg run >/dev/null 2>>"$DAEMON_LOG" &
DAEMON_PID=$!
log "daemon pid: $DAEMON_PID"
for i in $(seq 1 100); do
  [[ -S "$TRACE_SOCK" && -S "$CONTROL_SOCK" ]] && break
  kill -0 "$DAEMON_PID" 2>/dev/null || { echo "daemon died at startup; log tail:"; tail -20 "$DAEMON_LOG"; exit 1; }
  sleep 0.1
done
[[ -S "$TRACE_SOCK" ]] || { echo "daemon sockets never appeared"; exit 1; }
log "daemon sockets ready"

# ---------------------------------------------------------------------------
# Build the synthetic repo
# ---------------------------------------------------------------------------
gen_file() { # path lines salt
  awk -v n="$2" -v salt="$3" 'BEGIN {
    for (i = 1; i <= n; i++)
      printf "line %06d of %s :: 0123456789abcdefghijklmnopqrstuvwxyz-payload-%06d\n", i, salt, i * 7
  }' > "$1"
}

qgit init -q -b main .

# Seed commit: the pre-fork content the trunk will later rewrite. The restack
# undo diffs (trunk commit -> original stack commit), which RESTORES this
# content — that reversal is the '+' payload parsed into memory per pair.
mkdir -p "$REPO/src"
for i in $(seq 1 "$BASE_FILES"); do
  gen_file "$REPO/src/module_$(printf '%03d' "$i").txt" "$LINES_PER_FILE" "module_$i"
done
echo "seed" > "$REPO/README.md"
qgit add -A
qgit commit -qm "seed"
FORK_POINT="$(qgit rev-parse HEAD)"
log "seed commit done ($BASE_FILES files x $LINES_PER_FILE lines)"

# Feature branch: STACK_COMMITS commits with real AI authorship notes
# (mock_ai checkpoint before commit => daemon writes an authorship note).
qgit checkout -qb feature
for i in $(seq 1 "$STACK_COMMITS"); do
  f="feature_$(printf '%03d' "$i").txt"
  gen_file "$REPO/$f" 40 "feature_$i"
  gai checkpoint mock_ai "$f" >/dev/null
  tgit add "$f"
  tgit commit -qm "AI feature $i"
done
ORIG_TIP="$(qgit rev-parse feature)"
log "created $STACK_COMMITS feature commits (waiting for authorship notes...)"

ORIG_COMMITS_FILE="$WORK/orig_commits.txt"
qgit rev-list --reverse "$FORK_POINT..feature" > "$ORIG_COMMITS_FILE"

notes_hit_count() { # file-with-shas
  local list
  list="$(qgit notes --ref=ai list 2>/dev/null | awk '{print $2}')" || true
  [[ -z "$list" ]] && { echo 0; return; }
  grep -cFf <(printf '%s\n' "$list") "$1" || true
}

deadline=$(( $(date +%s) + 300 ))
while :; do
  n="$(notes_hit_count "$ORIG_COMMITS_FILE")"
  (( n >= STACK_COMMITS )) && break
  if (( $(date +%s) > deadline )); then
    echo "error: only $n/$STACK_COMMITS feature commits got authorship notes in 300s" >&2
    echo "daemon log tail:"; tail -30 "$DAEMON_LOG"
    exit 1
  fi
  sleep 1
done
log "all $STACK_COMMITS feature commits have authorship notes (refs/notes/ai)"


# ---------------------------------------------------------------------------
# VARIANT: drops-AFTER-match shape (gt move / undo discarding commits that sit
# ON TOP of matched ones). Exercises the UNBOUNDED post-match fabrication at
# rewrite.rs:1109 (`previous_new_sha`), which MAX_PENDING_DROPPED_COMMITS does
# not cover.
#
#   feature       = S1..S4 (AI notes)  + T1..TN big commits on top (notes)
#   feature-prime = S1'..S4' (rewritten siblings of S: same content, new SHAs)
#   trigger       = traced `git reset --keep feature-prime` on feature
#
#   range-diff  base..feature  vs  base..feature-prime:
#     S1..S4  -> '=' matches (sets previous_new_sha)
#     T1..TN  -> '<' drops AFTER a match -> one fabricated mapping each, no cap
# ---------------------------------------------------------------------------

qgit checkout -qb feature-prime "$FORK_POINT"
while read -r sha; do
  qgit cherry-pick --allow-empty "$sha" >/dev/null 2>&1
  qgit commit --amend -qm "$(qgit log -1 --format=%s "$sha") [moved]"
done < <(qgit rev-list --reverse "$FORK_POINT..feature")
PRIME_TIP="$(qgit rev-parse feature-prime)"
log "created feature-prime (rewritten stack siblings)"

NOTE_BLOB="$(qgit notes --ref=ai list | head -1 | awk '{print $1}')"
[[ -n "$NOTE_BLOB" ]] || { echo "error: no authorship note blob found" >&2; exit 1; }
while read -r sha; do
  qgit notes --ref=ai add -f -C "$NOTE_BLOB" "$sha" 2>/dev/null
done < <(qgit rev-list "$FORK_POINT..feature-prime")

qgit checkout -q feature
for i in $(seq 1 "$TRUNK_COMMITS"); do
  for j in $(seq 1 "$BASE_FILES"); do
    gen_file "$REPO/base_$(printf '%03d' "$j").txt" "$LINES_PER_FILE" "ontop_${i}_${j}"
  done
  qgit add -A
  qgit commit -qm "on-top $i"
done
while read -r sha; do
  qgit notes --ref=ai add -f -C "$NOTE_BLOB" "$sha" 2>/dev/null
done < <(qgit rev-list "$FORK_POINT..feature")
log "piled $TRUNK_COMMITS big commits on top of feature (all noted)"

NOTES_REF_BEFORE="$(qgit rev-parse refs/notes/ai)"

(
  while kill -0 "$DAEMON_PID" 2>/dev/null; do
    ps -axo pid=,ppid=,rss= | awk -v d="$DAEMON_PID" -v t="$(date +%s)" '
      $1 == d { drss = $3 } $2 == d { crss += $3 }
      END { printf "%s %d %d\n", t, drss, crss }' >> "$RSS_LOG"
    sleep 0.2
  done
) &
SAMPLER_PID=$!
BASELINE_KB="$(ps -o rss= -p "$DAEMON_PID" | tr -d ' ')"
log "daemon baseline RSS: $(( BASELINE_KB / 1024 )) MB"

log "running: git reset --keep $PRIME_TIP (traced -> daemon)"
RESET_START=$(date +%s)
tgit reset --keep "$PRIME_TIP" >/dev/null
RESET_END=$(date +%s)
log "git reset finished in $(( RESET_END - RESET_START ))s; daemon processes rewrite asynchronously"

deadline=$(( $(date +%s) + 600 ))
while :; do
  now_ref="$(qgit rev-parse refs/notes/ai)"
  [[ "$now_ref" != "$NOTES_REF_BEFORE" ]] && { DONE_AT=$(date +%s); break; }
  if (( $(date +%s) > deadline )); then DONE_AT=$(date +%s); log "timeout waiting for notes rewrite (600s)"; break; fi
  sleep 1
done

sleep 3
kill "$SAMPLER_PID" 2>/dev/null || true

PEAK_KB="$(awk 'BEGIN{m=0}{if($2>m)m=$2}END{print m}' "$RSS_LOG")"
PEAK_CHILD_KB="$(awk 'BEGIN{m=0}{if($3>m)m=$3}END{print m}' "$RSS_LOG")"
echo
echo "================================ RESULTS ================================"
echo "shape:                  S=$STACK_COMMITS matched + T=$TRUNK_COMMITS dropped-AFTER-match"
echo "knobs:                  BASE_FILES=$BASE_FILES LINES_PER_FILE=$LINES_PER_FILE"
echo "daemon RSS baseline:    $(( BASELINE_KB / 1024 )) MB"
echo "daemon RSS peak:        $(( PEAK_KB / 1024 )) MB  (delta +$(( (PEAK_KB - BASELINE_KB) / 1024 )) MB)"
echo "peak child git RSS:     $(( PEAK_CHILD_KB / 1024 )) MB"
echo "rewrite processing:     $(( DONE_AT - RESET_END ))s (reset exit -> notes write/timeout)"
echo "========================================================================="
