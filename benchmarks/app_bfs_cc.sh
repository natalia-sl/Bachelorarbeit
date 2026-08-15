#!/usr/bin/env bash
# app_bfs_cc.sh -- BFS and CC concurrently on the same graph.
#
# Two modes:
#   GRAPH set + file exists -> both load it (-f); peak == steady state
#   GRAPH unset/missing     -> each generates its own (-u/-k); peak is ~2x
#                              steady state, and TWO processes do it at once
#
# Per process, roughly:
#   steady state ~ 8 * 2^SCALE * DEGREE bytes   (CSR: 2*k neighbours * 4 B)
#   generation peak ~ 2x that                  (edge list alive alongside CSR)
# At SCALE=27 DEGREE=20 that is ~22.5 GB steady, ~43 GB peak -- times two
# processes is ~86 GB, which on a ~96 GB machine is an OOM waiting to happen.
# If you must generate in-process, drop DEGREE to ~14.
set -uo pipefail

GRAPH="${GRAPH:-}"
SCALE="${SCALE:-27}"
DEGREE="${DEGREE:-20}"
TRIALS="${TRIALS:-16}"
OUT="${OUT:-.}"

mkdir -p "$OUT"

for b in bfs cc; do
    [[ -x "./gapbs/$b" ]] || { echo "ERROR: ./gapbs/$b not found or not executable" >&2; exit 1; }
done

GENERATING=0
if [[ -n "$GRAPH" && -f "$GRAPH" ]]; then
    echo "Starting BFS and CC in parallel on $GRAPH ($TRIALS trials each)..."
    GRAPH_ARGS=(-f "$GRAPH")
else
    GENERATING=1
    [[ -n "$GRAPH" ]] && echo "NOTE: GRAPH='$GRAPH' not found, generating in-process instead"
    peak_gb=$(awk -v s="$SCALE" -v k="$DEGREE" 'BEGIN{printf "%.0f", 2*16*(2^s)*k/2^30/2}')
    total_gb=$((peak_gb * 2))
    mem_gb=$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo)
    echo "Starting BFS and CC in parallel, each generating -u $SCALE -k $DEGREE ($TRIALS trials)..."
    echo "WARNING: in-process generation peaks at ~${peak_gb} GB per process"
    echo "         (~${total_gb} GB for both) against ${mem_gb} GB of RAM."
    # With staggering the ceiling is peak+steady, not peak+peak.
    if [[ "${STAGGER:-1}" == "1" ]]; then
        need_gb=$((peak_gb + peak_gb / 2))
        echo "         Staggered start caps the combined peak at ~${need_gb} GB."
    else
        need_gb=$total_gb
    fi
    if [[ $need_gb -gt $((mem_gb * 70 / 100)) ]]; then
        echo "ERROR: projected peak ~${need_gb} GB exceeds 70% of ${mem_gb} GB with swap off." >&2
        echo "       That does not deadlock, it thrashes in direct reclaim and looks like a hang." >&2
        echo "       Lower DEGREE (peak is ~2*DEGREE GB per process), or use a .sg file." >&2
        echo "       Set FORCE=1 to run anyway." >&2
        [[ "${FORCE:-0}" == "1" ]] || exit 1
    fi
    GRAPH_ARGS=(-u "$SCALE" -k "$DEGREE")
fi

./gapbs/bfs "${GRAPH_ARGS[@]}" -n "$TRIALS" > "$OUT/bfs.log" 2>&1 &
BFS_PID=$!

# When generating in-process, launching both at once means BOTH hit their
# ~2*k GB construction peak simultaneously (~80 GB at k=20). Waiting for BFS
# to finish building first caps the combined peak at peak+steady (~60 GB),
# and both are still resident together for the trials, which is the phase
# being measured. Set STAGGER=0 to launch simultaneously.
if [[ $GENERATING -eq 1 && "${STAGGER:-1}" == "1" ]]; then
    echo "Staggering: waiting for BFS to finish building before starting CC..."
    for ((i = 0; i < 1800; i++)); do
        grep -qE "Build Time|Trial Time" "$OUT/bfs.log" 2>/dev/null && break
        kill -0 "$BFS_PID" 2>/dev/null || break
        sleep 1
    done
    echo "BFS build done (or exited) after ${i}s; starting CC"
fi

./gapbs/cc  "${GRAPH_ARGS[@]}" -n "$TRIALS" > "$OUT/cc.log"  2>&1 &
CC_PID=$!

# --- phase marker -----------------------------------------------------------
# GAP builds the CSR before running any trial, and that build is pure
# first-touch allocation - the same problem the YCSB load phase has. The
# harness wraps the WHOLE app in vmstat/perf, so without this its deltas are
# dominated by construction rather than by the graph traversals being measured.
# Snapshot the counters once both processes report 'Build Time'; the harness
# picks up $OUT/vmstat.after_load and reports run-phase-only deltas from it.
(
    for ((i = 0; i < 3600; i++)); do
        bfs_built=0; cc_built=0
        grep -qE "Build Time|Trial Time" "$OUT/bfs.log" 2>/dev/null && bfs_built=1
        grep -qE "Build Time|Trial Time" "$OUT/cc.log"  2>/dev/null && cc_built=1
        [[ $bfs_built -eq 1 && $cc_built -eq 1 ]] && break
        # Stop waiting if either process died, otherwise this spins for an hour
        # after a crash and the snapshot never lands.
        kill -0 "$BFS_PID" 2>/dev/null || break
        kill -0 "$CC_PID"  2>/dev/null || break
        sleep 1
    done
    grep -E '^(pgpromote_success|pgpromote_candidate|numa_pages_migrated|pgdemote_kswapd|pgdemote_direct|numa_hint_faults|numa_hint_faults_local|numa_pte_updates)' \
        /proc/vmstat > "$OUT/vmstat.after_load"
    echo "[PHASE] builds_done $(date +%s)"
) &
PHASE_PID=$!

# Without this the script returns immediately, the harness records a runtime
# of ~0, and the benchmarks keep running into the next rep.
wait "$BFS_PID"; BFS_RC=$?
wait "$CC_PID";  CC_RC=$?
wait "$PHASE_PID" 2>/dev/null || true

# Prefixed output only after both finish, so the streams cannot interleave
# mid-line in the harness log (which greps '^[BFS]' / '^[CC]').
sed 's/^/[BFS] /' "$OUT/bfs.log"
sed 's/^/[CC] /'  "$OUT/cc.log"

if [[ $BFS_RC -ne 0 || $CC_RC -ne 0 ]]; then
    echo "ERROR: bfs exited $BFS_RC, cc exited $CC_RC" >&2
    exit 1
fi

grep -q "Average Time" "$OUT/bfs.log" || { echo "ERROR: no BFS timing" >&2; exit 1; }
grep -q "Average Time" "$OUT/cc.log"  || { echo "ERROR: no CC timing"  >&2; exit 1; }
