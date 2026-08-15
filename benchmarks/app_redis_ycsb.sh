#!/usr/bin/env bash
# app_redis_ycsb.sh -- Redis + YCSB workloada.
#
# Invoked by run-bench-variant.sh, which passes THREADS / JVM_HEAP / OUT via
# env and shuts down any leftover server before each rep.
set -uo pipefail

THREADS="${THREADS:-16}"
RECORDS="${RECORDS:-10000000}"
OPS="${OPS:-10000000}"
JVM_HEAP="${JVM_HEAP:-4g}"      # cap the client so the JVM doesn't eat node 0
OUT="${OUT:-.}"
WORKLOAD="${WORKLOAD:-workloada}"
REDIS_MEMPOLICY="${REDIS_MEMPOLICY:-local}"   # local | preferred | interleave
DBG=/sys/kernel/debug

mkdir -p "$OUT"

# --- locate YCSB ------------------------------------------------------------
# This script runs under sudo, where $HOME is /root and a relative ./YCSB
# depends on whatever directory the harness was launched from. Resolve the
# INVOKING user's home explicitly and try the plausible names.
real_home() {
    local u="${SUDO_USER:-$(id -un)}"
    getent passwd "$u" | cut -d: -f6
}
HOME_REAL="$(real_home)"

if [[ -z "${YCSB_DIR:-}" ]]; then
    for c in ./ycsb ./YCSB "$HOME_REAL/ycsb" "$HOME_REAL/YCSB" /opt/ycsb; do
        if [[ -d "$c/bin" ]]; then YCSB_DIR="$(cd "$c" && pwd)"; break; fi
    done
fi
if [[ -z "${YCSB_DIR:-}" || ! -d "$YCSB_DIR/bin" ]]; then
    echo "ERROR: no YCSB installation found." >&2
    echo "  looked in: ./ycsb ./YCSB $HOME_REAL/ycsb $HOME_REAL/YCSB /opt/ycsb" >&2
    echo "  set YCSB_DIR explicitly, or install with tiers_setup.sh" >&2
    exit 1
fi
echo "[YCSB] using $YCSB_DIR"

WORKLOAD_FILE="$YCSB_DIR/workloads/$WORKLOAD"
if [[ ! -f "$WORKLOAD_FILE" ]]; then
    echo "ERROR: workload file $WORKLOAD_FILE not found" >&2
    ls "$YCSB_DIR/workloads" 2>/dev/null >&2 || echo "  (no workloads directory)" >&2
    exit 1
fi

# --- pick a launcher --------------------------------------------------------
# The two launchers take JVM options DIFFERENTLY, and getting this wrong is
# silent-ish: bin/ycsb.sh forwards every argument after the first two straight
# to site.ycsb.Client, which does not know -jvm-args. Client then prints its
# usage text ending in "Unknown option -jvm-args", and the visible part of that
# text is "Required properties: workload: ...", which looks exactly like a
# missing workload file. It is not. ycsb.sh honours JAVA_OPTS instead.
#
# bin/ycsb (the Python launcher) is Python 2 ONLY - it does not even parse
# under Python 3 - so it is a fallback, not the default.
JVM_VIA_ENV=0
if [[ -x "$YCSB_DIR/bin/ycsb.sh" ]]; then
    YCSB_CMD=("$YCSB_DIR/bin/ycsb.sh")
    JVM_VIA_ENV=1
elif command -v python2 >/dev/null 2>&1 && [[ -f "$YCSB_DIR/bin/ycsb" ]]; then
    YCSB_CMD=(python2 "$YCSB_DIR/bin/ycsb")
else
    echo "ERROR: no usable YCSB launcher in $YCSB_DIR/bin" >&2
    echo "  bin/ycsb.sh is missing and python2 is not installed." >&2
    echo "  bin/ycsb is a Python 2 script and will NOT run under python3." >&2
    exit 1
fi

# Assemble the JVM heap argument for whichever launcher we picked.
JVM_ARGS=()
if [[ $JVM_VIA_ENV -eq 1 ]]; then
    export JAVA_OPTS="-Xmx$JVM_HEAP ${JAVA_OPTS:-}"
    echo "[YCSB] launcher: ${YCSB_CMD[*]}  (heap via JAVA_OPTS=$JAVA_OPTS)"
else
    JVM_ARGS=(-jvm-args "-Xmx$JVM_HEAP")
    echo "[YCSB] launcher: ${YCSB_CMD[*]}  (heap via -jvm-args)"
fi

# --- java sanity ------------------------------------------------------------
if ! command -v java >/dev/null 2>&1; then
    echo "ERROR: no java on PATH. sudo apt install -y openjdk-11-jre-headless" >&2
    exit 1
fi
java -version 2>&1 | head -1
JAVA_MAJOR="$(java -version 2>&1 | awk -F'"' '/version/{split($2,a,"."); print (a[1]=="1" ? a[2] : a[1]); exit}')"
if [[ -n "${JAVA_MAJOR:-}" && "$JAVA_MAJOR" -ge 17 ]]; then
    echo "NOTE: java $JAVA_MAJOR - YCSB 0.17.0 targets java 8/11 and some bindings"
    echo "      fail on 17+. If the load dies in a reflective-access or"
    echo "      NoClassDefFoundError trace, install openjdk-11-jre-headless and"
    echo "      point JAVA_HOME at it."
fi

# --- memory policy for the server -------------------------------------------
# IMPORTANT: 'local' means NO numactl at all, and it is the only setting that
# permits NUMA balancing. task_numa_work() skips every VMA where
# vma_policy_mof() is false (fair.c: "!vma_migratable(vma) || !vma_policy_mof(vma)").
# vma_policy_mof() returns pol->flags & MPOL_F_MOF, and MPOL_F_MOF is set ONLY
# on the kernel's built-in per-node default policy. Any explicit set_mempolicy()
# - which is what numactl --preferred / --membind / --interleave all issue -
# produces a policy without that flag, so nothing is marked PROT_NONE, no hint
# faults are taken, and promotion/demotion counters stay at exactly zero.
# The other policies remain available for deliberately measuring that effect.
NUMA_PREFIX=()
case "$REDIS_MEMPOLICY" in
    local)      ;;   # correct choice for tiering experiments
    preferred|interleave|membind*)
        case "$REDIS_MEMPOLICY" in
            preferred)  NUMA_PREFIX=(numactl --preferred=1) ;;
            interleave) NUMA_PREFIX=(numactl --interleave=0,1) ;;
            membind*)   NUMA_PREFIX=(numactl --membind=1) ;;
        esac
        echo "WARNING: REDIS_MEMPOLICY=$REDIS_MEMPOLICY sets an explicit mempolicy." >&2
        echo "         The NUMA scanner skips VMAs without MPOL_F_MOF, which no" >&2
        echo "         explicit policy carries, so this run will produce ZERO hint" >&2
        echo "         faults and ZERO promotions. Use 'local' unless you are" >&2
        echo "         deliberately measuring that." >&2
        if [[ "${ALLOW_ZERO_MIGRATION:-0}" != "1" ]]; then
            echo "ERROR: refusing to run. Set ALLOW_ZERO_MIGRATION=1 to override." >&2
            exit 1
        fi ;;
    *) echo "ERROR: unknown REDIS_MEMPOLICY '$REDIS_MEMPOLICY'" >&2; exit 1 ;;
esac

# --- refuse to run if a previous rep's server is still up --------------------
# Otherwise redis-server fails to bind, exits, and YCSB silently talks to the
# stale server holding the previous rep's data and page placement.
if redis-cli -h 127.0.0.1 -p 6379 ping >/dev/null 2>&1; then
    echo "ERROR: something is already listening on 127.0.0.1:6379" >&2
    exit 1
fi

echo "Starting Redis Server (mempolicy=$REDIS_MEMPOLICY)..."
"${NUMA_PREFIX[@]}" redis-server --save "" --appendonly no > "$OUT/redis.log" 2>&1 &
REDIS_PID=$!

for _ in $(seq 30); do
    redis-cli ping 2>/dev/null | grep -q PONG && break
    sleep 1
done
if ! redis-cli ping 2>/dev/null | grep -q PONG; then
    echo "ERROR: redis did not come up" >&2; cat "$OUT/redis.log" >&2; exit 1
fi

cleanup() {
    redis-cli shutdown nosave >/dev/null 2>&1 || kill "$REDIS_PID" 2>/dev/null
    wait "$REDIS_PID" 2>/dev/null
    echo "Redis stopped."
}
trap cleanup EXIT

# --- load -------------------------------------------------------------------
echo "Loading $RECORDS records into Redis via YCSB ($THREADS threads)..."
if ! "${YCSB_CMD[@]}" load redis -s -P "$WORKLOAD_FILE" \
        -p "redis.host=127.0.0.1" -p "redis.port=6379" \
        -p recordcount="$RECORDS" -threads "$THREADS" \
        ${JVM_ARGS+"${JVM_ARGS[@]}"} > "$OUT/ycsb_load.log" 2>&1; then
    echo "ERROR: YCSB load failed. Last 40 lines of $OUT/ycsb_load.log:" >&2
    # Print it here rather than only pointing at the file: this goes into the
    # rep log, so a failure in an overnight sweep is diagnosable in the morning.
    tail -40 "$OUT/ycsb_load.log" >&2
    if grep -q 'Unknown option' "$OUT/ycsb_load.log"; then
        echo "HINT: 'Unknown option' means an argument reached site.ycsb.Client" >&2
        echo "      that it does not understand. The usage text it prints" >&2
        echo "      mentions a missing 'workload' property, but the workload" >&2
        echo "      file is fine - look at the last line instead." >&2
    fi
    exit 1
fi
redis-cli info memory | grep -E 'used_memory_human|used_memory_rss_human'

# --- phase marker -----------------------------------------------------------
# The harness samples nbp_hist every 2 s with '=== <epoch> ===' headers; this
# timestamp lets you split that trace into load phase vs run phase afterwards.
# Snapshotting rather than resetting on purpose: a reset also zeroes the
# threshold, which would put a warm-up inside the measured window.
echo "[PHASE] load_done $(date +%s)"
# Snapshot the migration counters at the phase boundary. The harness wraps the
# WHOLE app in perf/vmstat, so its deltas span load+run - and the load is the
# larger part, dominated by first-touch allocation rather than the workload.
# This file lets the harness also report run-phase-only deltas.
grep -E '^(pgpromote_success|pgpromote_candidate|numa_pages_migrated|pgdemote_kswapd|pgdemote_direct|numa_hint_faults|numa_hint_faults_local|numa_pte_updates)' \
    /proc/vmstat > "$OUT/vmstat.after_load"
if [[ -r $DBG/nbp_hist ]]; then
    cat "$DBG/nbp_hist" > "$OUT/nbp_hist.after_load"
    echo -n "[PHASE] rl_rejected_after_load = "
    awk '$1=="rl_rejected" {print $3}' "$DBG/nbp_hist"
fi

# --- run --------------------------------------------------------------------
echo "Starting YCSB Benchmark Run..."
"${YCSB_CMD[@]}" run redis -s -P "$WORKLOAD_FILE" \
    -p "redis.host=127.0.0.1" -p "redis.port=6379" \
    -p recordcount="$RECORDS" -p operationcount="$OPS" \
    -threads "$THREADS" ${JVM_ARGS+"${JVM_ARGS[@]}"} 2>&1 | tee "$OUT/ycsb_run.log"

echo "[PHASE] run_done $(date +%s)"
[[ -r $DBG/nbp_hist ]] && cat "$DBG/nbp_hist" > "$OUT/nbp_hist.after_run"

# --- parse ------------------------------------------------------------------
runtime_ms=$(grep "\[OVERALL\], RunTime(ms)" "$OUT/ycsb_run.log" | awk -F', ' '{print $3}')
if [[ -z "${runtime_ms:-}" ]]; then
    echo "ERROR: no RunTime in YCSB output. Last 40 lines of $OUT/ycsb_run.log:" >&2
    tail -40 "$OUT/ycsb_run.log" >&2
    exit 1
fi
runtime_s=$(echo "scale=3; $runtime_ms / 1000" | bc)
echo "[YCSB] Average Time: $runtime_s"

# logs are deliberately kept - they are what you need when a rep looks odd
