#!/usr/bin/env bash
# run-bench-variant.sh - benchmark an arbitrary kernel VARIANT (not a static threshold).
#
# Usage:  ./run-bench-variant.sh <app> <variant> [cond] [reps]   (run with bash, NOT sh)
#   app     : key from the APPS map below (pr, bfs, cc, bc, bfs_cc, redis, xsbench, dlrm)
#   variant : free-form label for what you're testing (histogram, static, stock, ...)
#   cond    : 1 = THP never/never (default), 2 = THP always
#   reps    : repetitions on this node (default 5)
#   e.g.  ./run-bench-variant.sh pr histogram 1 10
# Run from the directory holding your app scripts and ./gapbs.
#
# Between every rep: zone_reclaim_mode, swapoff -a, sync, drop_caches=3.
#   ZONE_RECLAIM_MODE=0|1   (default 1)  - a run CONDITION, see the guard below
#   SYNC_MODE=targeted|full|none (default targeted) - full = bare global sync
#
# For bfs_cc, generate the graph ONCE first (not per rep):
#   mkdir -p ~/graphs && ./gapbs/converter -u 27 -k 20 -b ~/graphs/u27k20.sg
set -uo pipefail

# --- match these to your actual app scripts -----------------------------
declare -A APPS=(
  [pr]="bash app_pr.sh"
  [bfs]="bash app_bfs.sh"
  [cc]="bash app_cc.sh"
  [bc]="bash app_bc.sh"
  [bfs_cc]="bash app_bfs_cc.sh"
  [redis]="bash app_redis_ycsb.sh"
  [xsbench]="bash app_xsbench.sh"
  [dlrm]="bash app_dlrm.sh"
)
# ------------------------------------------------------------------------

APP="${1:?usage: $0 <app> <variant> [cond] [reps]   apps: ${!APPS[*]}}"
VAR="${2:?need a variant/label, e.g. histogram}"
COND="${3:-1}"                    # default never/never
REPS="${4:-5}"
NODE="$(hostname -s)"

CORES="0,1,2,3,4,5,6,7"           # cores on the FAST node - keep IDENTICAL across ALL runs
KMOD_DIR="$HOME/Natalia_SS2026/Linux-6-16-Tiers"
EVENTS="dTLB-load-misses,dTLB-loads,dTLB-store-misses,dTLB-stores,cache-misses,cache-references,bus-cycles"

# --- app tunables -------------------------------------------------------
# Resolved HERE, as the invoking user, because the app itself runs under
# sudo where $HOME is /root. These are handed to the app via an explicit
# env block (sudo does not forward the environment).
GRAPH="${GRAPH:-$HOME/graphs/u27k20.sg}"   # pre-serialized GAP graph for bfs_cc
TRIALS="${TRIALS:-16}"                     # GAP trials per app (-n)
SCALE="${SCALE:-27}"                       # GAP -u scale, used when generating
DEGREE="${DEGREE:-20}"                     # GAP -k degree, used when generating
YCSB_THREADS="${YCSB_THREADS:-16}"         # YCSB client threads (load AND run)
JVM_HEAP="${JVM_HEAP:-4g}"                 # cap the YCSB JVM so it doesn't eat node 0

# DLRM. Resolved here for the same reason as the rest: under sudo the app sees
# $HOME=/root, so the venv and the checkout have to be handed over explicitly.
# Footprint = TABLES*ROWS*DIM*4 B; the defaults below are 15.3 GiB of embedding
# tables, ~2.4x node 0. One row is DIM*4 = 2048 B, so exactly two rows share a
# 4 KB page - page-level access granularity is 2 rows regardless of index skew.
DLRM_VENV="${DLRM_VENV:-$HOME/dlrm-venv}"
DLRM_HOME="${DLRM_HOME:-$HOME/dlrm}"
DLRM_PY="${DLRM_PY:-$DLRM_HOME/dlrm_s_pytorch.py}"
DLRM_PYTHON="${DLRM_PYTHON:-$DLRM_VENV/bin/python}"
DLRM_SCRATCH="${DLRM_SCRATCH:-/var/tmp/dlrm}"   # node-local, NEVER the NFS home
DLRM_TABLES="${DLRM_TABLES:-8}"                 # -> --arch-embedding-size
DLRM_ROWS="${DLRM_ROWS:-1000000}"               # rows per table
DLRM_DIM="${DLRM_DIM:-512}"                     # --arch-sparse-feature-size
DLRM_MBS="${DLRM_MBS:-2048}"                    # --mini-batch-size
DLRM_TEST_MBS="${DLRM_TEST_MBS:-16384}"         # --test-mini-batch-size
DLRM_TEST_WORKERS="${DLRM_TEST_WORKERS:-0}"     # --test-num-workers
DLRM_BATCHES="${DLRM_BATCHES:-400}"             # --num-batches
DLRM_IDX="${DLRM_IDX:-200}"                     # --num-indices-per-lookup
DLRM_IDX_FIXED="${DLRM_IDX_FIXED:-0}"           # 1 -> --num-indices-per-lookup-fixed
DLRM_MLP_BOT="${DLRM_MLP_BOT:-2048-2048-512}"   # last layer MUST equal DLRM_DIM
DLRM_MLP_TOP="${DLRM_MLP_TOP:-1024-1024-1024-1}"
DLRM_INTERACTION="${DLRM_INTERACTION:-dot}"     # --arch-interaction-op
DLRM_DATAGEN="${DLRM_DATAGEN:-random}"          # --data-generation
DLRM_DIST="${DLRM_DIST:-uniform}"               # --rand-data-dist: uniform | gaussian
DLRM_SIGMA="${DLRM_SIGMA:-125000}"              # ROW units; ONLY used when DLRM_DIST=gaussian
DLRM_SEED="${DLRM_SEED:-727}"                   # --numpy-rand-seed
DLRM_THREADS="${DLRM_THREADS:-8}"               # keep equal to the taskset core count

# XSBench. At -s large (355 nuclides) with -G unionized the footprint is set by
# -g alone: MB ~= g/2. -p changes only runtime, not memory, because history mode
# keeps just nthreads particles live at a time. 96.2% of the footprint is the
# unionized index grid (hit thinly, uniformly); the hot set is the nuclide grid
# plus the energy array, and both are malloc'd and first-touched BEFORE it.
XS_BIN="${XS_BIN:-$HOME/XSBench/openmp-threading/XSBench}"
XS_G="${XS_G:-100000}"                     # ~48.8 GiB footprint, ~1.9 GiB hot
XS_PARTICLES="${XS_PARTICLES:-20000000}"   # 680M lookups
XS_GRID="${XS_GRID:-unionized}"            # unionized | hash | nuclide
XS_THREADS="${XS_THREADS:-$(awk -F, '{print NF}' <<<"$CORES")}"
# ------------------------------------------------------------------------

# --- NBP histogram instrumentation (harmless on non-histogram kernels) --
HIST_DBG="/sys/kernel/debug/nbp_hist"
HIST_SAMPLE_S=2                   # snapshot cadence for the per-rep trace
PLACE_EVERY="${PLACE_EVERY:-5}"   # every 5th tick -> 10s placement snapshots
NBP_KNOBS=(nbp_spacing nbp_pow_n nbp_nbuckets nbp_rebal_k \
           nbp_prune nbp_epoch nbp_epoch_min \
           nbp_zones nbp_access nbp_th_every nbp_epoch_every)

hist_available() { sudo test -r "$HIST_DBG" 2>/dev/null; }
# read one "key = value" line from the debugfs file; prints NA if absent
hist_val() {
  local v
  v=$(sudo awk -v k="$1" '$1==k {print $3}' "$HIST_DBG" 2>/dev/null)
  echo "${v:-NA}"
}
# numeric delta of two hist_val readings; NA if either side is missing
hist_delta() {
  if [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]]; then echo $(( $2 - $1 )); else echo NA; fi
}
# three-zone policy: per-case fault counters (all NA on pre-zone kernels)
ZONE_KEYS=(case1 case2_ok case2_no case3 case_warm)
MEM_TOTAL_GB=$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo)

# targeted | full | none. Default avoids touching NFS mounts entirely.
SYNC_MODE="${SYNC_MODE:-targeted}"
SYNC_PATH="${SYNC_PATH:-/}"

# vm.zone_reclaim_mode. 1 = RECLAIM_ZONE only: when node 0 is under its
# watermark, a blocking allocation first reclaims UNMAPPED page cache/slab on
# node 0 before falling back to node 1. may_unmap stays 0, so mapped app
# memory is never touched; with demotion on, that cache is demoted to node 1
# rather than dropped (counted in pgdemote_direct). Promotion allocations
# cannot block, so the promotion path itself is unaffected.
# Changes where an app's memory STARTS -> it is a run condition, not hygiene.
ZONE_RECLAIM_MODE="${ZONE_RECLAIM_MODE:-1}"
[[ "$ZONE_RECLAIM_MODE" =~ ^[0-7]$ ]] \
  || { echo "ERROR: ZONE_RECLAIM_MODE='$ZONE_RECLAIM_MODE' - expected 0..7" >&2; exit 1; }

# free memory on a NUMA node, in MB
node_free_mb() {
  awk '/MemFree/{print int($4/1024)}' "/sys/devices/system/node/node$1/meminfo" 2>/dev/null || echo 0
}

# resident MB per NUMA node for one pid, summed over its VMAs: "<n0> <n1>".
# numa_maps reports N<node>= in BASE pages even for THP, so *4 KB is correct
# under both cond 1 and cond 2.
proc_numa_mb() {
  sudo awk '{for(i=1;i<=NF;i++){
               if($i ~ /^N0=/){split($i,a,"=");n0+=a[2]}
               else if($i ~ /^N1=/){split($i,a,"=");n1+=a[2]}}}
             END{printf "%d %d", n0*4/1024, n1*4/1024}' \
      "/proc/$1/numa_maps" 2>/dev/null || echo "NA NA"
}

# everything worth knowing when a rep wedges
diagnose_hang() {
  echo "===== HANG DIAGNOSTICS $(date) ====="
  echo "--- per-node free memory ---"
  for n in 0 1; do echo "node$n free = $(node_free_mb "$n") MB"; done
  numactl -H 2>/dev/null | head -20
  echo "--- memory pressure (PSI) ---"
  cat /proc/pressure/memory 2>/dev/null || echo "(no PSI)"
  echo "--- promotion / demotion / hint-fault counters ---"
  grep -E '^(pgpromote_success|pgpromote_candidate|numa_pages_migrated|pgdemote_kswapd|pgdemote_direct|numa_hint_faults|numa_hint_faults_local|numa_pte_updates)' /proc/vmstat
  echo "--- nbp histogram ---"
  sudo cat "$HIST_DBG" 2>/dev/null || echo "(absent)"
  echo "--- last memory samples before the hang ---"
  tail -20 "$MEM_TRACE" 2>/dev/null || echo "(no trace)"
  echo "--- ALL uninterruptible (D state) tasks - these cannot be killed ---"
  ps -eo pid,stat,wchan:40,comm | awk '$2 ~ /D/' || echo "(none)"
  echo "--- NFS / hung task messages ---"
  sudo dmesg 2>/dev/null | grep -iE 'nfs|hung task|blocked for more than' | tail -20 || echo "(none)"
  echo "--- benchmark processes (STAT D = uninterruptible; WCHAN = where it is stuck) ---"
  ps -eo pid,ppid,stat,wchan:32,rss,etime,comm | grep -E 'bfs|cc|pr|bc|redis|java|python|perf|XSBench' | grep -v grep
  echo "--- kernel stacks ---"
  for pid in $(pgrep -f 'gapbs/(bfs|cc|pr|bc)|redis-server|dlrm_s_pytorch|XSBench' 2>/dev/null); do
    echo "pid $pid ($(cat "/proc/$pid/comm" 2>/dev/null)):"
    sudo cat "/proc/$pid/stack" 2>/dev/null | head -20 || echo "  (stack unavailable)"
  done
  echo "--- dmesg tail ---"
  sudo dmesg 2>/dev/null | tail -60
  echo "===== END DIAGNOSTICS ====="
}

# timeout signals the process group, but sweep up anything that survived
kill_stragglers() {
  echo "--- killing stragglers ---"
  redis-cli -h 127.0.0.1 -p 6379 shutdown nosave >/dev/null 2>&1 || true
  sudo pkill -f 'gapbs/(bfs|cc|pr|bc)' 2>/dev/null || true
  sudo pkill -f 'ycsb' 2>/dev/null || true
  sudo pkill -f 'dlrm_s_pytorch' 2>/dev/null || true
  sudo pkill -f 'XSBench' 2>/dev/null || true
  sleep 3
  sudo pkill -9 -f 'gapbs/(bfs|cc|pr|bc)' 2>/dev/null || true
  sudo pkill -9 -f 'ycsb' 2>/dev/null || true
  sudo pkill -9 -f 'dlrm_s_pytorch' 2>/dev/null || true
  sudo pkill -9 -f 'XSBench' 2>/dev/null || true
  sleep 2
  echo "still running:"
  ps -eo pid,stat,comm | grep -E 'bfs|cc|pr|redis|java|python|XSBench' | grep -v grep || echo "(none)"
}

# record the runtime knob state - VAR is only a label, this is the ground truth
dump_knobs() {
  local k
  for k in "${NBP_KNOBS[@]}"; do
    if sudo test -r "/sys/kernel/debug/$k"; then
      echo "$k = $(sudo cat "/sys/kernel/debug/$k" 2>/dev/null)"
    else
      echo "$k = absent"
    fi
  done
}
# ------------------------------------------------------------------------

CMD="${APPS[$APP]:-}"
[[ -n "$CMD" ]] || { echo "unknown app '$APP' - known: ${!APPS[*]}" >&2; exit 1; }

# wall-clock ceiling per rep; redis needs more because the YCSB load alone is long
if [[ -z "${MAXSEC:-}" ]]; then
  case "$APP" in
    redis) MAXSEC=10800 ;;
    dlrm)  MAXSEC=10800 ;;   # table init alone is minutes before the first iter
    xsbench) MAXSEC=7200 ;;   # the index-grid build is a SERIAL pass over 50 GB
    *)     MAXSEC=3600  ;;
  esac
fi
[[ "$COND" == "2" ]] && THP="always" || THP="never"

# soft check: warn (don't block) if the booted kernel name doesn't mention the variant
case "$(uname -r)" in
  *"$VAR"*) : ;;
  *) echo "WARNING: kernel '$(uname -r)' does not contain '$VAR' - is the right kernel booted?" >&2 ;;
esac

# hard-ish check: histogram variant should expose the debugfs file
if [[ "$VAR" == *hist* ]] && ! hist_available; then
  echo "WARNING: variant '$VAR' but $HIST_DBG is not readable - wrong kernel, or debugfs not mounted?" >&2
fi

# A missing graph is no longer fatal: the GAP app scripts fall back to
# generating in-process. Just say which mode this run is in, so the log
# records it. Note the in-process peak is ~2x steady state per process.
if [[ "$APP" != "xsbench" && "$APP" != "dlrm" && -n "$GRAPH" && ! -f "$GRAPH" ]]; then
  echo "NOTE: graph '$GRAPH' not found - GAP apps will generate in-process." >&2
  echo "      To use a file instead: ./gapbs/converter -u 27 -k 20 -b $GRAPH  (~22.5 GB)" >&2
fi

if [[ "$APP" == "xsbench" ]]; then
  [[ -x "$XS_BIN" ]] || { echo "ERROR: no XSBench binary at $XS_BIN - run ./tiers_setup.sh" >&2; exit 1; }
  case "$XS_GRID" in
    unionized|hash|nuclide) : ;;
    *) echo "ERROR: XS_GRID='$XS_GRID' - expected unionized, hash or nuclide" >&2; exit 1 ;;
  esac
fi

# DLRM needs its interpreter and its checkout to exist BEFORE the reps start;
# discovering this inside rep 1, under sudo, costs a whole preflight cycle.
if [[ "$APP" == "dlrm" ]]; then
  [[ -x "$DLRM_PYTHON" ]] || { echo "ERROR: no venv python at $DLRM_PYTHON - run ./tiers_setup.sh" >&2; exit 1; }
  [[ -f "$DLRM_PY"     ]] || { echo "ERROR: no $DLRM_PY - run ./tiers_setup.sh" >&2; exit 1; }
  # --arch-interaction-op=dot requires the bottom MLP to emit exactly
  # --arch-sparse-feature-size. dlrm asserts on this only after the tables are
  # built, which is minutes in, so catch it here instead of losing a rep.
  bot_last="${DLRM_MLP_BOT##*-}"
  if [[ "$bot_last" != "$DLRM_DIM" ]]; then
    echo "ERROR: DLRM_MLP_BOT ends in $bot_last but DLRM_DIM is $DLRM_DIM;" >&2
    echo "       --arch-interaction-op=$DLRM_INTERACTION needs them equal." >&2
    exit 1
  fi
  dlrm_gb=$(awk -v t="$DLRM_TABLES" -v r="$DLRM_ROWS" -v d="$DLRM_DIM" \
            'BEGIN{printf "%.1f", t*r*d*4/1024/1024/1024}')
  # np.random.uniform builds each table as float64 and then casts, so one table
  # transiently costs rows*dim*(8+4) B on top of the steady-state footprint.
  dlrm_peak=$(awk -v r="$DLRM_ROWS" -v d="$DLRM_DIM" \
            'BEGIN{printf "%.1f", r*d*12/1024/1024/1024}')
  echo "NOTE: DLRM embedding footprint = ${dlrm_gb} GiB (${DLRM_TABLES} x ${DLRM_ROWS} x ${DLRM_DIM} x 4 B)"
  echo "      init adds ~${dlrm_peak} GiB transiently per table; total RAM = ${MEM_TOTAL_GB} GB"
  if [[ "$DLRM_DIST" == "gaussian" ]]; then
    dlrm_hot=$(awk -v t="$DLRM_TABLES" -v s="$DLRM_SIGMA" -v d="$DLRM_DIM" \
            'BEGIN{printf "%.1f", t*6*s*d*4/1024/1024/1024}')
    dlrm_hot_pct=$(awk -v s="$DLRM_SIGMA" -v r="$DLRM_ROWS" 'BEGIN{printf "%.0f", 600*s/r}')
    echo "      dist=gaussian sigma=${DLRM_SIGMA} rows -> +-3 sigma ~ ${dlrm_hot} GiB (${dlrm_hot_pct}% of rows)"
    if [[ "${dlrm_hot_pct%%.*}" -gt 40 ]]; then
      echo "      WARNING: that is not a hot set. Scale DLRM_SIGMA with DLRM_ROWS."
    fi
  else
    echo "      dist=${DLRM_DIST}: index draws are FLAT, so there is no hot set to"
    echo "      promote and DLRM_SIGMA is ignored. This is a control configuration."
  fi
  if [[ "$DLRM_IDX_FIXED" != "1" ]]; then
    echo "      --num-indices-per-lookup-fixed is OFF, so the count is drawn from"
    echo "      [1,${DLRM_IDX}]: mean lookup is ~$((DLRM_IDX/2)) indices, not ${DLRM_IDX}."
  fi
fi

# If the results volume is on a hung NFS mount, every write below blocks in
# uninterruptible D state. Find out now, not three reps in.
if ! timeout 10 stat -f . >/dev/null 2>&1; then
  echo "ERROR: cannot stat the current filesystem within 10s." >&2
  echo "       A hung NFS mount will wedge this run in D state, where it cannot" >&2
  echo "       be killed. Check: dmesg | grep -i nfs" >&2
  exit 1
fi

OUTDIR="results/${NODE}/${APP}/${VAR}_cond${COND}"
mkdir -p "$OUTDIR" || { echo "ERROR: cannot create $OUTDIR" >&2; exit 1; }

# Fail here, with a usable message, rather than emitting a "Permission denied"
# from every tee in the run. This happens when the tree was created by a
# root-owned run: do NOT run this script under sudo, it sudos where it needs to.
if [[ ! -w "$OUTDIR" ]]; then
  echo "ERROR: $OUTDIR is not writable by $(id -un) (owner: $(stat -c %U "$OUTDIR"))" >&2
  echo "  fix with: sudo chown -R \"$(id -un):$(id -gn)\" results" >&2
  echo "  and run this script as your user, not under sudo" >&2
  exit 1
fi

CSV="$OUTDIR/summary.csv"

# summary.csv has no column for zone_reclaim_mode, so reps run with different
# values would become indistinguishable once they share a file. The stamp
# records the value per result dir. A dir that already has results but no
# stamp predates this setting: its value was never logged, so it is treated
# as unknown and refused rather than silently assumed to be 0.
ZRM_STAMP="$OUTDIR/zone_reclaim_mode"
if [[ -f "$CSV" ]]; then
  prev_zrm=$(cat "$ZRM_STAMP" 2>/dev/null || echo "unrecorded")
  if [[ "$prev_zrm" != "$ZONE_RECLAIM_MODE" ]]; then
    echo "ERROR: $OUTDIR already holds reps with zone_reclaim_mode=$prev_zrm;" >&2
    echo "       this run would use $ZONE_RECLAIM_MODE. They must not share a summary.csv." >&2
    echo "       Move the old dir out of results/ (e.g. into results_pre_zrm/)," >&2
    echo "       or run under a new variant label." >&2
    exit 1
  fi
fi
echo "$ZONE_RECLAIM_MODE" > "$ZRM_STAMP"

# NOTE: header is unchanged on purpose - existing summary.csv files and
# check_bench.py keep working. New information goes to the rep logs.
[[ -f "$CSV" ]] || echo "node,app,variant,condition,thp,rep,kernel,avg_trial_time_s,pgpromote_success_delta,numa_pages_migrated_delta,nr_active_file_delta,dTLB_load_miss_pct,cache_miss_pct,pgpromote_candidate_delta,rl_rejected_delta,threshold_ms_end" > "$CSV"

counter() { local v; v=$(grep -m1 "^$1 " /proc/vmstat | awk '{print $2}'); echo "${v:-0}"; }
pct() { awk -v ev="$1" '{ci=0;pi=0;for(i=1;i<=NF;i++){if($i==ev)ci=i-1;if($i=="#")pi=i+1};if(ci>0){c=$ci;gsub(/,/,"",c);c=c+0;p=(pi>0)?$pi:"";gsub(/%/,"",p);if(c>max){max=c;best=p}}}END{print best}' "$2"; }

# ===== ONE-TIME SETUP (run AND verified) ================================
{
  echo "===== SETUP $(date) ====="
  echo "node=$NODE kernel=$(uname -r) app=$APP variant=$VAR cond=$COND ($THP) reps=$REPS"
  if [[ -n "$GRAPH" && -f "$GRAPH" ]]; then
    echo "app tunables: graph=$GRAPH (loaded) trials=$TRIALS ycsb_threads=$YCSB_THREADS jvm_heap=$JVM_HEAP"
  else
    echo "app tunables: graph=GENERATED -u $SCALE -k $DEGREE trials=$TRIALS ycsb_threads=$YCSB_THREADS jvm_heap=$JVM_HEAP"
  fi
  echo "--- free space on results volume ---"
  df -h .
  echo "--- transparent hugepage ---"
  sudo sh -c "echo $THP > /sys/kernel/mm/transparent_hugepage/enabled"
  sudo sh -c "echo $THP > /sys/kernel/mm/transparent_hugepage/defrag"
  echo -n "enabled = "; sudo cat /sys/kernel/mm/transparent_hugepage/enabled
  echo -n "defrag  = "; sudo cat /sys/kernel/mm/transparent_hugepage/defrag
  echo "--- tier module ---"
  ( cd "$KMOD_DIR" && sudo insmod tierinit.ko 2>&1 || echo "(insmod skipped: already loaded or failed)" )
  ls /sys/devices/virtual/memory_tiering/ 2>/dev/null || echo "(no memory_tiering dir)"
  echo "--- demotion + numa_balancing ---"
  sudo sh -c 'echo 1 > /sys/kernel/mm/numa/demotion_enabled'
  sudo sh -c 'echo 2 > /proc/sys/kernel/numa_balancing'
  echo -n "demotion_enabled = "; sudo cat /sys/kernel/mm/numa/demotion_enabled
  echo -n "numa_balancing   = "; sudo cat /proc/sys/kernel/numa_balancing
  echo "--- promotion rate limit (must never bind for the histogram claim) ---"
  echo -n "promote_rate_limit_MBps = "; cat /proc/sys/kernel/numa_balancing_promote_rate_limit_MBps
  echo "--- nbp histogram debugfs ---"
  if hist_available; then echo "$HIST_DBG present"; else echo "$HIST_DBG absent (ok for non-histogram variants)"; fi
  echo "--- nbp runtime knobs (ground truth for what '$VAR' actually is) ---"
  dump_knobs
  echo "--- numa layout ---"
  numactl -H 2>/dev/null || echo "(numactl not installed)"
  if [[ "$APP" == "dlrm" ]]; then
    echo "--- dlrm config ---"
    echo "python    = $DLRM_PYTHON"
    echo "script    = $DLRM_PY"
    echo "tables=$DLRM_TABLES rows=$DLRM_ROWS dim=$DLRM_DIM idx=$DLRM_IDX fixed=$DLRM_IDX_FIXED"
    echo "mbs=$DLRM_MBS test_mbs=$DLRM_TEST_MBS batches=$DLRM_BATCHES threads=$DLRM_THREADS"
    echo "mlp_bot=$DLRM_MLP_BOT mlp_top=$DLRM_MLP_TOP interaction=$DLRM_INTERACTION"
    echo "datagen=$DLRM_DATAGEN dist=$DLRM_DIST sigma=$DLRM_SIGMA seed=$DLRM_SEED"
    awk -v t="$DLRM_TABLES" -v r="$DLRM_ROWS" -v d="$DLRM_DIM" -v m="$DLRM_MBS" -v i="$DLRM_IDX" \
        'BEGIN{printf "footprint = %.1f GiB    embedding bytes touched per batch ~ %.1f GiB (mean idx)\n", \
               t*r*d*4/1024/1024/1024, m*t*(i/2)*d*4/1024/1024/1024}'
    n0_tot=$(awk '/MemTotal/{print int($4/1024)}' /sys/devices/system/node/node0/meminfo)
    echo "node0 total = ${n0_tot} MB    free now: node0 $(node_free_mb 0) MB / node1 $(node_free_mb 1) MB"
  fi
  if [[ "$APP" == "xsbench" ]]; then
    echo "--- xsbench sizing ---"
    # nuclide grid 355*g*48 B, energy array 355*g*8 B, index grid 355*g*355*4 B
    xs_hot_mb=$(( 355*XS_G*56 / 1048576 ))
    if [[ "$XS_GRID" == "unionized" ]]; then
      xs_mb=$(( (355*XS_G*56 + 355*XS_G*355*4) / 1048576 ))
    else
      xs_mb=$(( 355*XS_G*48 / 1048576 ))
    fi
    n0_tot=$(awk '/MemTotal/{print int($4/1024)}' /sys/devices/system/node/node0/meminfo)
    n0_free=$(node_free_mb 0); n1_free=$(node_free_mb 1)
    echo "binary    = $XS_BIN"
    echo "grid=$XS_GRID gridpoints=$XS_G particles=$XS_PARTICLES threads=$XS_THREADS"
    echo "footprint ~ ${xs_mb} MB    node0 total = ${n0_tot} MB    free now: node0 ${n0_free} MB / node1 ${n1_free} MB"
    if [[ $xs_mb -gt $(( n0_free + n1_free )) ]]; then
      echo "WARNING: footprint exceeds free memory on both nodes - this rep will OOM."
    fi
    if [[ "$XS_GRID" == "unionized" ]]; then
      echo "hot set   ~ ${xs_hot_mb} MB (nuclide grid + energy array)"
      echo "NOTE: the hot set is first-touched BEFORE the index grid, so under plain"
      echo "      first-touch it lands on node 0 and promotion has nothing to do."
      echo "      rep<N>_place.log is what confirms or refutes that."
    else
      echo "NOTE: -G $XS_GRID has no index grid, so the access distribution is flat."
      echo "      Control case; it should NOT produce a stable histogram peak."
    fi
  fi
  echo "--- zone reclaim ---"
  sudo sh -c "echo $ZONE_RECLAIM_MODE > /proc/sys/vm/zone_reclaim_mode"
  echo -n "zone_reclaim_mode  = "; cat /proc/sys/vm/zone_reclaim_mode
  # node reclaim only runs while a node's unmapped page cache exceeds this % of it
  echo -n "min_unmapped_ratio = "; cat /proc/sys/vm/min_unmapped_ratio
  echo "--- swap ---"
  sudo swapoff -a
  swapon --show || true
  echo "(swap above should be empty)"
} 2>&1 | tee "$OUTDIR/setup.log"

# machine-readable copy of the knob state alongside the results
dump_knobs > "$OUTDIR/knobs.txt"

# ===== REPEATED RUNS ====================================================
for rep in $(seq 1 "$REPS"); do
    log="$OUTDIR/rep${rep}.log"
    APPOUT="$OUTDIR/rep${rep}_app"        # app-private logs (bfs.log, ycsb_run.log, ...)
    mkdir -p "$APPOUT"

    # leftover redis from a crashed rep would make the next rep silently talk
    # to a server that already holds the previous rep's data and placement
    if [[ "$APP" == "redis" ]]; then
        redis-cli -h 127.0.0.1 -p 6379 shutdown nosave >/dev/null 2>&1 || true
        sleep 2
    fi

    {
      echo "########## REP $rep/$REPS  $(date) ##########"
      echo "node=$NODE app=$APP variant=$VAR cond=$COND ($THP) kernel=$(uname -r) cores=$CORES cmd='$CMD'"
      echo "--- THP state for this run ---"
      echo -n "enabled = "; sudo cat /sys/kernel/mm/transparent_hugepage/enabled
      echo -n "defrag  = "; sudo cat /sys/kernel/mm/transparent_hugepage/defrag
      echo "--- nbp knobs for this run ---"
      dump_knobs
      echo "--- clearing stragglers from any previous rep ---"
      # A killed rep can leave bfs/cc holding tens of GB. The next rep then
      # starts already in the hole and thrashes.
      kill_stragglers
      echo "--- waiting for memory to be released ---"
      for _ in $(seq 60); do
        avail_gb=$(awk '/MemAvailable/{printf "%.0f", $2/1024/1024}' /proc/meminfo)
        [[ ${avail_gb:-0} -ge $((MEM_TOTAL_GB * 70 / 100)) ]] && break
        sleep 2
      done
      echo "MemAvailable = ${avail_gb:-?} GB of ${MEM_TOTAL_GB} GB"
      echo "--- between-rep reset: zone_reclaim_mode + swapoff ---"
      # Both were already set in setup and nothing in a rep changes them, so
      # this is idempotent. Re-asserting per rep makes each rep log show the
      # state that rep actually ran in, instead of relying on setup.log.
      sudo sh -c "echo $ZONE_RECLAIM_MODE > /proc/sys/vm/zone_reclaim_mode"
      zrm_now=$(cat /proc/sys/vm/zone_reclaim_mode)
      echo "zone_reclaim_mode = $zrm_now"
      [[ "$zrm_now" == "$ZONE_RECLAIM_MODE" ]] \
        || echo "WARNING: zone_reclaim_mode is $zrm_now, wanted $ZONE_RECLAIM_MODE"
      sudo swapoff -a
      if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
        echo "WARNING: swap is still active:"; swapon --show
      else
        echo "swap = off"
      fi
      echo "--- sync + drop caches (mode: $SYNC_MODE) ---"
      # A bare `sync` syncs EVERY mounted filesystem, including NFS. A task
      # blocked in NFS writeback sits in uninterruptible D state, where
      # neither timeout's SIGKILL nor Ctrl+C can reach it - the rep hangs
      # forever regardless of any timeout. `sync -f PATH` syncs only the
      # filesystem containing PATH, so a hung export elsewhere cannot block.
      case "$SYNC_MODE" in
        none)
          echo "sync skipped (SYNC_MODE=none)" ;;
        targeted)
          sudo timeout 60 sync -f "$SYNC_PATH" \
            || echo "WARNING: targeted sync of $SYNC_PATH timed out" ;;
        full)
          sudo timeout 300 sync \
            || echo "WARNING: global sync timed out - check for hung NFS mounts" ;;
      esac
      # drop_caches walks every superblock and can also block on a hung NFS
      # mount, so it gets its own ceiling.
      sudo timeout 120 sh -c 'echo 3 > /proc/sys/vm/drop_caches' \
        || echo "WARNING: drop_caches timed out"
      echo "caches dropped"
      echo "--- preflight: per-node free memory ---"
      for n in 0 1; do echo "node$n free = $(node_free_mb "$n") MB"; done
      if [[ $(node_free_mb 0) -lt 1024 ]]; then
        echo "WARNING: node 0 has under 1 GB free BEFORE this rep starts."
        echo "         A previous run may not have released its memory; promotion"
        echo "         will stall on migration failures and the rep may wedge."
      fi
      echo "timeout for this rep: ${MAXSEC}s"
    } 2>&1 | tee "$log"

    prom0=$(counter pgpromote_success); migr0=$(counter numa_pages_migrated); file0=$(counter nr_active_file)
    cand0=$(counter pgpromote_candidate)
    dem0=$(( $(counter pgdemote_kswapd) + $(counter pgdemote_direct) ))
    # node reclaim: did zone_reclaim_mode actually fire, and how much it demoted
    zrs0=$(counter zone_reclaim_success); zrf0=$(counter zone_reclaim_failed)
    ddir0=$(counter pgdemote_direct)
    rej0=$(hist_val rl_rejected)
    for k in "${ZONE_KEYS[@]}"; do declare "z0_$k=$(hist_val "$k")"; done
    {
      echo "--- vmstat BEFORE ---"
      echo "numa_pages_migrated $migr0"; echo "pgpromote_success $prom0"; echo "nr_active_file $file0"
      echo "pgpromote_candidate $cand0"; echo "pgdemote_total $dem0"; echo "rl_rejected $rej0"
      echo "zone_reclaim_success $zrs0"; echo "zone_reclaim_failed $zrf0"; echo "pgdemote_direct $ddir0"
      echo "--- BENCHMARK ---"
    } 2>&1 | tee -a "$log"

    # --- start samplers -----------------------------------------------------
    # rep<N>_hist.log keeps the exact '=== epoch ===' format as before, so
    # existing parsers are unaffected. Per-node free memory and PSI go to a
    # SEPARATE file so a hang has a timeline even on non-histogram kernels.
    HIST_TRACE="$OUTDIR/rep${rep}_hist.log"
    MEM_TRACE="$OUTDIR/rep${rep}_mem.log"
    PLACE_TRACE="$OUTDIR/rep${rep}_place.log"
    HIST_OK=""; hist_available && HIST_OK=1
    # dlrm runs as the venv interpreter, so match the script name, not comm
    case "$APP" in
      xsbench) PLACE_PROC="XSBench"; PLACE_MATCH="-x" ;;
      dlrm)    PLACE_PROC="dlrm_s_pytorch"; PLACE_MATCH="-f" ;;
      *)       PLACE_PROC=""; PLACE_MATCH="-x" ;;
    esac
    (
      n=0
      while :; do
        ts=$(date +%s)
        {
          echo "=== $ts ==="
          echo "node0_free_mb $(node_free_mb 0)"
          echo "node1_free_mb $(node_free_mb 1)"
          sed 's/^/psi /' /proc/pressure/memory 2>/dev/null
        } >> "$MEM_TRACE"
        if [[ -n "$HIST_OK" ]]; then
          { echo "=== $ts ==="; sudo cat "$HIST_DBG"; } >> "$HIST_TRACE" 2>/dev/null
        fi
        # Per-VMA placement. Reading numa_maps forces a page-table walk over the
        # whole address space, so this runs on a slower cadence than the rest and
        # prints only VMAs above 10 MB - which is exactly the three grids.
        if [[ -n "$PLACE_PROC" ]] && (( n % PLACE_EVERY == 0 )); then
          ppid=$(pgrep "$PLACE_MATCH" "$PLACE_PROC" 2>/dev/null | head -1)
          if [[ -n "$ppid" ]]; then
            {
              echo "=== $ts pid=$ppid ==="
              echo "total_mb $(proc_numa_mb "$ppid")"
              sudo grep -E 'N[01]=' "/proc/$ppid/numa_maps" 2>/dev/null \
                | awk '{n0=0;n1=0;
                        for(i=1;i<=NF;i++){
                          if($i~/^N0=/){split($i,a,"=");n0=a[2]}
                          else if($i~/^N1=/){split($i,a,"=");n1=a[2]}}
                        if(n0+n1 > 2560) printf "vma %s N0=%dMB N1=%dMB\n", $1, n0*4/1024, n1*4/1024}'
            } >> "$PLACE_TRACE" 2>/dev/null
          fi
        fi
        n=$((n+1))
        sleep "$HIST_SAMPLE_S"
      done
    ) >/dev/null 2>&1 &
    HIST_PID=$!

    # `env` is required: sudo does not forward the environment, and inside the
    # app $HOME would be /root. Everything the app needs is passed explicitly.
    # timeout signals the whole process group in its default (non --foreground)
    # mode, so the GAP children go down with it; -k 60 escalates to SIGKILL.
    sudo timeout -k 60 "$MAXSEC" \
        /usr/bin/time --verbose \
        perf stat -a --per-socket -e "$EVENTS" \
        -- env OUT="$APPOUT" \
               PYTHON="$DLRM_PYTHON" \
               DLRM_PY="$DLRM_PY" \
               DLRM_SCRATCH="$DLRM_SCRATCH" \
               DLRM_TABLES="$DLRM_TABLES" \
               DLRM_ROWS="$DLRM_ROWS" \
               DLRM_DIM="$DLRM_DIM" \
               DLRM_MBS="$DLRM_MBS" \
               DLRM_TEST_MBS="$DLRM_TEST_MBS" \
               DLRM_TEST_WORKERS="$DLRM_TEST_WORKERS" \
               DLRM_BATCHES="$DLRM_BATCHES" \
               DLRM_IDX="$DLRM_IDX" \
               DLRM_IDX_FIXED="$DLRM_IDX_FIXED" \
               DLRM_MLP_BOT="$DLRM_MLP_BOT" \
               DLRM_MLP_TOP="$DLRM_MLP_TOP" \
               DLRM_INTERACTION="$DLRM_INTERACTION" \
               DLRM_DATAGEN="$DLRM_DATAGEN" \
               DLRM_DIST="$DLRM_DIST" \
               DLRM_SIGMA="$DLRM_SIGMA" \
               DLRM_SEED="$DLRM_SEED" \
               DLRM_THREADS="$DLRM_THREADS" \
               GRAPH="$GRAPH" \
               TRIALS="$TRIALS" \
               THREADS="$YCSB_THREADS" \
               JVM_HEAP="$JVM_HEAP" \
               SCALE="$SCALE" \
               DEGREE="$DEGREE" \
               XS_BIN="$XS_BIN" \
               XS_G="$XS_G" \
               XS_PARTICLES="$XS_PARTICLES" \
               XS_GRID="$XS_GRID" \
               XS_THREADS="$XS_THREADS" \
           taskset -c "$CORES" $CMD 2>&1 | tee -a "$log"
    APP_RC=${PIPESTATUS[0]}

    # --- stop samplers ---
    if [[ -n "$HIST_PID" ]]; then
        pkill -P "$HIST_PID" 2>/dev/null
        kill "$HIST_PID" 2>/dev/null
        wait "$HIST_PID" 2>/dev/null
    fi

    # --- timeout handling ---
    TIMED_OUT=0
    if [[ $APP_RC -eq 124 || $APP_RC -eq 137 ]]; then
        TIMED_OUT=1
        {
          echo "!!! REP $rep TIMED OUT after ${MAXSEC}s (exit $APP_RC) !!!"
          diagnose_hang
          kill_stragglers
        } 2>&1 | tee -a "$log"
    elif [[ $APP_RC -ne 0 ]]; then
        echo "WARNING: app exited $APP_RC" 2>&1 | tee -a "$log"
    fi

    prom1=$(counter pgpromote_success); migr1=$(counter numa_pages_migrated); file1=$(counter nr_active_file)
    cand1=$(counter pgpromote_candidate)
    dem1=$(( $(counter pgdemote_kswapd) + $(counter pgdemote_direct) ))
    zrs1=$(counter zone_reclaim_success); zrf1=$(counter zone_reclaim_failed)
    ddir1=$(counter pgdemote_direct)
    rej1=$(hist_val rl_rejected)
    th_end=$(hist_val threshold_ms)
    zones_on=$(hist_val zones)
    z1_end=$(hist_val zone1_ms); z2_end=$(hist_val zone2_ms)
    peak_end=$(hist_val peak_bucket)
    ZONE_DELTAS=""
    for k in "${ZONE_KEYS[@]}"; do
        v0="z0_$k"
        ZONE_DELTAS+="$(hist_delta "${!v0}" "$(hist_val "$k")"),"
    done
    ZONE_DELTAS="${ZONE_DELTAS%,}"

    if [[ "$rej0" =~ ^[0-9]+$ && "$rej1" =~ ^[0-9]+$ ]]; then
        rej_delta=$((rej1-rej0))
    else
        rej_delta=NA
    fi

    {
      echo "--- vmstat AFTER ---"
      echo "numa_pages_migrated $migr1"; echo "pgpromote_success $prom1"; echo "nr_active_file $file1"
      echo "pgpromote_candidate $cand1"; echo "pgdemote_total $dem1"
      echo "rl_rejected $rej1"; echo "threshold_ms $th_end"
      echo "zone_reclaim_success $zrs1"; echo "zone_reclaim_failed $zrf1"; echo "pgdemote_direct $ddir1"
      echo "--- DELTAS ---"
      echo "pgpromote_success_delta   = $((prom1-prom0))"
      echo "numa_pages_migrated_delta = $((migr1-migr0))"
      echo "nr_active_file_delta      = $((file1-file0))"
      echo "pgpromote_candidate_delta = $((cand1-cand0))"
      echo "pgdemote_total_delta      = $((dem1-dem0))"
      echo "rl_rejected_delta         = $rej_delta"
      echo "zone_reclaim_success_delta = $((zrs1-zrs0))"
      echo "zone_reclaim_failed_delta  = $((zrf1-zrf0))"
      echo "pgdemote_direct_delta      = $((ddir1-ddir0))"
      if [[ "$zones_on" == "1" ]]; then
        echo "--- three-zone policy ---"
        echo "zone1_ms = $z1_end   zone2_ms = $z2_end   peak_bucket = $peak_end"
        IFS=, read -r c1 c2ok c2no c3 cwarm <<<"$ZONE_DELTAS"
        echo "case1 (always promote)      = $c1"
        echo "case2_ok (space available)  = $c2ok"
        echo "case2_no (tier full)        = $c2no"
        echo "case3 (past the peak)       = $c3"
        echo "case_warm (pre-first-recompute) = $cwarm"
        # if the middle zone never resolves either way it is not doing work
        if [[ "$c2ok" =~ ^[0-9]+$ && "$c2no" =~ ^[0-9]+$ && $((c2ok+c2no)) -gt 0 ]]; then
          echo "case2 promoted share        = $(( 100*c2ok/(c2ok+c2no) ))%"
        fi
        if [[ "$cwarm" =~ ^[0-9]+$ && "$c1" =~ ^[0-9]+$ && $cwarm -gt $((c1+1)) ]]; then
          echo "NOTE: warm-up faults exceed case1 - the run may be too short for the recompute interval"
        fi
      fi
      if [[ "$rej_delta" != "NA" && "$rej_delta" -gt 0 ]]; then
        echo "!!! RATE LIMITER BOUND DURING THIS RUN ($rej_delta pages) - histogram claim confounded !!!"
      fi
      # candidate >> success with ~0 demotion is the node-0-full signature
      if [[ $((cand1-cand0)) -gt 0 && $((prom1-prom0)) -lt $(( (cand1-cand0) / 2 )) ]]; then
        echo "NOTE: promotion success is under half of candidates - check demotion/node 0 capacity"
      fi
    } 2>&1 | tee -a "$log"

    if [[ $TIMED_OUT -eq 1 ]]; then
        avg=TIMEOUT
    elif [[ "$APP" == "bfs_cc" ]]; then
        avg_bfs=$(grep -m1 '^\[BFS\].*Average Time' "$log" | awk '{print $NF}')
        avg_cc=$(grep -m1 '^\[CC\].*Average Time' "$log" | awk '{print $NF}')

        # Combine them with an underscore (e.g., "1.23_0.85") so it fits in one CSV column
        avg="${avg_bfs:-NA}_${avg_cc:-NA}"
    elif [[ "$APP" == "redis" ]]; then
        # Parse the YCSB wrapper output
        avg=$(grep -m1 '^\[YCSB\] Average Time' "$log" | awk '{print $NF}')
    elif [[ "$APP" == "xsbench" ]]; then
        # seconds of SIMULATION only - XSBench's own timer excludes grid init
        avg=$(grep -m1 '^\[XSBENCH\] Average Time' "$log" | awk '{print $NF}')
    elif [[ "$APP" == "dlrm" ]]; then
        # seconds per iteration, warm-up window already excluded by the app script
        avg=$(grep -m1 '^\[DLRM\] Average Time' "$log" | awk '{print $NF}')
    else
        avg=$(grep -m1 'Average Time' "$log" | awk '{print $NF}')
    fi
    dtlb_pct=$(pct dTLB-load-misses "$log")
    cache_pct=$(pct cache-misses "$log")

    echo "$NODE,$APP,$VAR,$COND,$THP,$rep,$(uname -r),${avg:-NA},$((prom1-prom0)),$((migr1-migr0)),$((file1-file0)),${dtlb_pct:-NA},${cache_pct:-NA},$((cand1-cand0)),$rej_delta,$th_end" >> "$CSV"

    # Zone data goes to its own CSV rather than widening summary.csv, so
    # check_bench.py and every existing summary.csv keep working unchanged.
    # Join on (node,app,variant,condition,rep).
    # XSBench's FOM is lookups/s (higher is better) so it cannot share a column
    # with avg_trial_time_s. Own file, join on (node,variant,condition,rep).
    if [[ "$APP" == "xsbench" ]]; then
      XSCSV="$OUTDIR/xsbench.csv"
      [[ -f "$XSCSV" ]] || echo "node,variant,condition,rep,grid_type,gridpoints,particles,est_mem_mb,runtime_s,lookups_per_s,checksum" > "$XSCSV"
      xs_line=$(grep -m1 '^\[XSBENCH\] grid=' "$log")
      xs_mem=$(sed -n 's/.*est_mem_MB=\([0-9]*\).*/\1/p' <<<"$xs_line")
      xs_fom=$(sed -n 's/.*lookups_per_s=\([0-9]*\).*/\1/p' <<<"$xs_line")
      xs_sum=$(grep -m1 'Verification checksum' "$log" | awk '{print $3}')
      echo "$NODE,$VAR,$COND,$rep,$XS_GRID,$XS_G,$XS_PARTICLES,${xs_mem:-NA},${avg:-NA},${xs_fom:-NA},${xs_sum:-NA}" >> "$XSCSV"
    fi

    ZCSV="$OUTDIR/zones.csv"
    [[ -f "$ZCSV" ]] || echo "node,app,variant,condition,rep,zones,zone1_ms_end,zone2_ms_end,peak_bucket_end,case1_delta,case2_ok_delta,case2_no_delta,case3_delta,case_warm_delta" > "$ZCSV"
    echo "$NODE,$APP,$VAR,$COND,$rep,${zones_on},${z1_end},${z2_end},${peak_end},${ZONE_DELTAS}" >> "$ZCSV"

    # the app ran under sudo, so its logs came out root-owned; hand them back
    sudo chown -R "$(id -un):$(id -gn)" "$OUTDIR" 2>/dev/null || true
done

echo ">>> done. logs + setup.log + knobs.txt + summary.csv + zones.csv + per-rep hist traces in $OUTDIR"
