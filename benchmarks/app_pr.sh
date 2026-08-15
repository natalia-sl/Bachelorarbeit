#!/usr/bin/env bash
# app_pr.sh -- GAP PageRank.
#
# Invoked by run-bench-variant.sh, which passes GRAPH / SCALE / DEGREE /
# TRIALS / OUT through an explicit env block and parses 'Average Time' from
# stdout. Everything is an env var with a default, so the harness controls the
# configuration and the CSV row matches what actually ran.
#
# Two modes, same as app_bfs_cc.sh:
#   GRAPH set + file exists -> load it (-f); peak == steady state
#   GRAPH unset/missing     -> generate in-process (-u/-k); peak is ~2x steady
#
# Roughly, per process:
#   steady state    ~ 8 * 2^SCALE * DEGREE bytes  (CSR: 2*k neighbours * 4 B)
#   generation peak ~ 2x that                     (edge list alive with CSR)
# At SCALE=27 DEGREE=20 that is ~22.5 GB steady, ~45 GB peak. Unlike bfs_cc
# only ONE process runs here, so in-process generation is fine on a ~100 GB
# machine and pre-generating a .sg file mostly just wastes ~22 GB of disk.
#
# PageRank note: pr sweeps the whole vertex set every iteration, so the access
# pattern is near-uniform rather than skewed. That makes it a useful adversary
# for a percentile-based promotion threshold - there is no hot decile to find -
# and a good contrast with the zipfian YCSB workload.
set -uo pipefail

GRAPH="${GRAPH:-}"
SCALE="${SCALE:-27}"
DEGREE="${DEGREE:-20}"
TRIALS="${TRIALS:-16}"
ITERS="${ITERS:-20}"        # pr -i: max iterations per trial
TOL="${TOL:-1e-4}"          # pr -t: convergence tolerance
OUT="${OUT:-.}"

mkdir -p "$OUT"

[[ -x ./gapbs/pr ]] || { echo "ERROR: ./gapbs/pr not found or not executable" >&2; exit 1; }

if [[ -n "$GRAPH" && -f "$GRAPH" ]]; then
    echo "Starting PageRank on $GRAPH ($TRIALS trials, max $ITERS iterations)..."
    GRAPH_ARGS=(-f "$GRAPH")
else
    [[ -n "$GRAPH" ]] && echo "NOTE: GRAPH='$GRAPH' not found, generating in-process instead"
    peak_gb=$(awk -v s="$SCALE" -v k="$DEGREE" 'BEGIN{printf "%.0f", 2*16*(2^s)*k/2^30/2}')
    mem_gb=$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo)
    echo "Starting PageRank, generating -u $SCALE -k $DEGREE ($TRIALS trials, max $ITERS iterations)..."
    echo "         in-process generation peaks at ~${peak_gb} GB against ${mem_gb} GB of RAM."
    if [[ $peak_gb -gt $((mem_gb * 70 / 100)) ]]; then
        echo "ERROR: projected peak ~${peak_gb} GB exceeds 70% of ${mem_gb} GB with swap off." >&2
        echo "       That does not deadlock, it thrashes in direct reclaim and looks like a hang." >&2
        echo "       Lower DEGREE (peak is ~2*DEGREE GB), or pre-generate a .sg file:" >&2
        echo "         ./gapbs/converter -u $SCALE -k $DEGREE -b graphs/u${SCALE}k${DEGREE}.sg" >&2
        echo "       Set FORCE=1 to run anyway." >&2
        [[ "${FORCE:-0}" == "1" ]] || exit 1
    fi
    GRAPH_ARGS=(-u "$SCALE" -k "$DEGREE")
fi

# Run in the background so the build phase can be detected while pr is still
# going, then replay the log to stdout at the end - the harness greps
# 'Average Time' from stdout, so the output contract is unchanged.
./gapbs/pr "${GRAPH_ARGS[@]}" -n "$TRIALS" -i "$ITERS" -t "$TOL" > "$OUT/pr.log" 2>&1 &
PR_PID=$!

# --- phase marker -----------------------------------------------------------
# The CSR build is pure first-touch allocation; the trials are the workload
# actually being measured. The harness wraps the whole app in vmstat/perf, so
# without this snapshot its counters are dominated by construction. Writing
# $OUT/vmstat.after_load makes the harness report run-phase-only deltas too.
(
    for ((i = 0; i < 3600; i++)); do
        grep -qE "Build Time|Trial Time" "$OUT/pr.log" 2>/dev/null && break
        kill -0 "$PR_PID" 2>/dev/null || break
        sleep 1
    done
    grep -E '^(pgpromote_success|pgpromote_candidate|numa_pages_migrated|pgdemote_kswapd|pgdemote_direct|numa_hint_faults|numa_hint_faults_local|numa_pte_updates)' \
        /proc/vmstat > "$OUT/vmstat.after_load"
) &
PHASE_PID=$!

wait "$PR_PID"; rc=$?
wait "$PHASE_PID" 2>/dev/null || true

cat "$OUT/pr.log"

if [[ $rc -ne 0 ]]; then
    echo "ERROR: pr exited $rc" >&2
    exit "$rc"
fi
grep -q "Average Time" "$OUT/pr.log" || { echo "ERROR: no PR timing in output" >&2; exit 1; }
