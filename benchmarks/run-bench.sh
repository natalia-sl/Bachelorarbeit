#!/usr/bin/env bash
# run-bench-variant.sh - benchmark an arbitrary kernel VARIANT (not a static threshold).
#
# Usage:  ./run-bench-variant.sh <app> <variant> [cond] [reps]   (run with bash, NOT sh)
#   app     : key from the APPS map below (pr, bfs, cc, bc, bfs_cc, redis, db)
#   variant : free-form label for what you're testing (histogram, static, stock, ...)
#   cond    : 1 = THP never/never (default), 2 = THP always
#   reps    : repetitions on this node (default 5)
#   e.g.  ./run-bench-variant.sh pr histogram 1 10
# Run from the directory holding your app scripts and ./gapbs.
#
# For bfs_cc, generate the graph ONCE first (not per rep):
#   mkdir -p ~/graphs && ./gapbs/converter -u 27 -k 20 -b ~/graphs/u27k20.sg
#
# For db (RocksDB db_bench), the dataset is loaded ONCE automatically before
# the rep loop and reused by every rep. It must live on a LOCAL disk, never on
# the NFS home - both because O_DIRECT needs it and because filling the shared
# export takes down every node. Point DB_DIR at local storage:
#   DB_DIR=/var/tmp/db_bench ./run-bench-variant.sh db hist 1 5
set -uo pipefail

# --- match these to your actual app scripts -----------------------------
declare -A APPS=(
  [pr]="bash app_pr.sh"
  [bfs]="bash app_bfs.sh"
  [cc]="bash app_cc.sh"
  [bc]="bash app_bc.sh"
  [bfs_cc]="bash app_bfs_cc.sh"
  [redis]="bash app_redis_ycsb.sh"
  [db]="bash app_db_bench.sh"
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

# --- db_bench (RocksDB) tunables ----------------------------------------
# Resolved to an absolute path here, as the invoking user, for the same
# reason GRAPH is: the app runs under sudo where relative paths and $HOME
# both mean something else.
DB_BENCH="${DB_BENCH:-$PWD/rocksdb/db_bench}"
DB_DIR="${DB_DIR:-/var/tmp/db_bench}"      # MUST be local disk, never NFS home
DB_NUM="${DB_NUM:-40000000}"               # keys loaded once (~41 GB at 1 KB)
DB_READ_NUM="${DB_READ_NUM:-$DB_NUM}"      # key range reads draw from; shrink
                                           # this to move/resize the hot set
DB_KEY_SIZE="${DB_KEY_SIZE:-16}"
DB_VALUE_SIZE="${DB_VALUE_SIZE:-1024}"
DB_CACHE_GB="${DB_CACHE_GB:-24}"           # block cache ~3x the 8 GB fast tier
DB_THREADS="${DB_THREADS:-8}"              # keep <= number of cores in $CORES
DB_DURATION="${DB_DURATION:-600}"          # measured seconds per rep
DB_EXP_RANGE="${DB_EXP_RANGE:-8}"          # 0 = uniform, higher = more skew
DB_BENCHMARK="${DB_BENCHMARK:-readrandom}" # readrandom | readwhilewriting | ...
DB_MEMPOLICY="${DB_MEMPOLICY:-local}"      # local = no numactl (only setting
                                           # compatible with NUMA balancing)
DB_MMAP_READ="${DB_MMAP_READ:-0}"          # 1 = file-backed variant
DB_COMPRESSION="${DB_COMPRESSION:-none}"   # none | snappy | zstd - snappy
                                           # roughly halves the on-disk dataset
                                           # and leaves the cache footprint
                                           # unchanged (blocks are cached
                                           # uncompressed)
DB_COMPRESSION_RATIO="${DB_COMPRESSION_RATIO:-0.5}"
DB_LOAD_MAXSEC="${DB_LOAD_MAXSEC:-14400}"  # ceiling for the one-time load
# What to do with the ~40 GB dataset once the reps are done:
#   always - delete it (default; safest on a full disk)
#   auto   - delete only if THIS invocation created it, keep a pre-existing one
#   keep   - never delete
# Deleting means the next variant reloads from scratch. When running the three
# variants back to back, use DB_CLEANUP=keep for the first two and let the
# last one clean up, or keep all three and delete by hand afterwards.
DB_CLEANUP="${DB_CLEANUP:-always}"
# ------------------------------------------------------------------------

# --- NBP histogram instrumentation (harmless on non-histogram kernels) --
HIST_DBG="/sys/kernel/debug/nbp_hist"
HIST_SAMPLE_S=2                   # snapshot cadence for the per-rep trace
NBP_KNOBS=(nbp_spacing nbp_pow_n nbp_prune nbp_epoch nbp_epoch_min \
           nbp_access nbp_th_every nbp_epoch_every)

hist_available() { sudo test -r "$HIST_DBG" 2>/dev/null; }
# read one "key = value" line from the debugfs file; prints NA if absent
hist_val() {
  local v
  v=$(sudo awk -v k="$1" '$1==k {print $3}' "$HIST_DBG" 2>/dev/null)
  echo "${v:-NA}"
}
MEM_TOTAL_GB=$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo)

# targeted | full | none. Default avoids touching NFS mounts entirely.
SYNC_MODE="${SYNC_MODE:-targeted}"
SYNC_PATH="${SYNC_PATH:-/}"

# free memory on a NUMA node, in MB
node_free_mb() {
  awk '/MemFree/{print int($4/1024)}' "/sys/devices/system/node/node$1/meminfo" 2>/dev/null || echo 0
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
  ps -eo pid,ppid,stat,wchan:32,rss,etime,comm | grep -E 'bfs|cc|pr|bc|redis|java|perf|db_bench' | grep -v grep
  echo "--- kernel stacks ---"
  for pid in $(pgrep -f 'gapbs/(bfs|cc|pr|bc)|redis-server' 2>/dev/null; pgrep -x db_bench 2>/dev/null); do
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
  # -x, not -f: a -f match on 'db_bench' would also hit app_db_bench.sh and
  # this harness's own command line.
  sudo pkill -x db_bench 2>/dev/null || true
  sleep 3
  sudo pkill -9 -f 'gapbs/(bfs|cc|pr|bc)' 2>/dev/null || true
  sudo pkill -9 -f 'ycsb' 2>/dev/null || true
  sudo pkill -9 -x db_bench 2>/dev/null || true
  sleep 2
  echo "still running:"
  ps -eo pid,stat,comm | grep -E 'bfs|cc|pr|redis|java|db_bench' | grep -v grep || echo "(none)"
}

DB_CREATED_HERE=0
# Remove the RocksDB dataset once the reps are done. Armed as an EXIT trap only
# AFTER a successful load, so an early preflight failure can never delete a
# dataset this run did not touch.
db_cleanup() {
  [[ "$APP" == "db" ]] || return 0

  case "$DB_CLEANUP" in
    keep)
      echo ">>> keeping $DB_DIR (DB_CLEANUP=keep)"
      return 0 ;;
    auto)
      if [[ $DB_CREATED_HERE -ne 1 ]]; then
        echo ">>> keeping pre-existing $DB_DIR (DB_CLEANUP=auto)"
        return 0
      fi ;;
  esac

  # Guards. DB_DIR is user-supplied and this deletes as root, so verify the
  # target really is a RocksDB directory before recursing through it.
  if [[ -z "${DB_DIR:-}" || "$DB_DIR" == "/" || "$DB_DIR" == "$HOME" ]]; then
    echo "REFUSING to remove DB_DIR='$DB_DIR'" >&2
    return 0
  fi
  if [[ ! -e "$DB_DIR/CURRENT" && ! -e "$DB_DIR/IDENTITY" ]]; then
    echo "REFUSING to remove $DB_DIR - no CURRENT/IDENTITY, does not look like a RocksDB dir" >&2
    return 0
  fi

  echo ">>> removing dataset $DB_DIR ($(sudo du -sh "$DB_DIR" 2>/dev/null | cut -f1))"
  sudo rm -rf -- "$DB_DIR"
  echo ">>> free space now:"
  df -h "$(dirname "$DB_DIR")" | tail -1
}

# record the runtime knob state - VAR is only a label, this is the ground truth
dump_knobs() {
  echo "watermark_scale_factor = $(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null || echo NA)"
  echo "promote_rate_limit_MBps = $(cat /proc/sys/kernel/numa_balancing_promote_rate_limit_MBps 2>/dev/null || echo NA)"
  echo "demotion_enabled = $(cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || echo NA)"
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
    # the load is done once outside the loop, so a rep is just DB_DURATION
    # plus open/warm-up; give it generous headroom, not hours
    db)    MAXSEC=$(( DB_DURATION + 1800 )) ;;
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
if [[ -n "$GRAPH" && ! -f "$GRAPH" ]]; then
  echo "NOTE: graph '$GRAPH' not found - GAP apps will generate in-process." >&2
  echo "      To use a file instead: ./gapbs/converter -u 27 -k 20 -b $GRAPH  (~22.5 GB)" >&2
fi

# db_bench preflight. All three of these are silent killers if left to
# discover themselves three hours into an overnight sweep.
if [[ "$APP" == "db" ]]; then
  if [[ ! -x "$DB_BENCH" ]]; then
    echo "ERROR: db_bench not found or not executable at '$DB_BENCH'" >&2
    echo "  build it with:" >&2
    echo "    git clone https://github.com/facebook/rocksdb.git" >&2
    echo "    cd rocksdb && make -j\$(nproc) db_bench DEBUG_LEVEL=0" >&2
    echo "  DEBUG_LEVEL=0 is not optional - the default build has assertions on." >&2
    exit 1
  fi

  mkdir -p "$DB_DIR" 2>/dev/null || sudo mkdir -p "$DB_DIR" || {
    echo "ERROR: cannot create DB_DIR '$DB_DIR'" >&2; exit 1; }

  DB_FSTYPE="$(stat -f -c %T "$DB_DIR" 2>/dev/null || echo unknown)"
  case "$DB_FSTYPE" in
    nfs*)
      echo "ERROR: DB_DIR '$DB_DIR' is on NFS ($DB_FSTYPE)." >&2
      echo "       O_DIRECT is unreliable there, and a ~$(( DB_NUM * (DB_KEY_SIZE + DB_VALUE_SIZE) / 1024/1024/1024 )) GB dataset on the" >&2
      echo "       shared export takes every node down with ENOSPC. Use local disk." >&2
      exit 1 ;;
    tmpfs|ramfs)
      echo "ERROR: DB_DIR '$DB_DIR' is on $DB_FSTYPE - that IS memory." >&2
      echo "       The whole DB would live in RAM, so there is no I/O path and" >&2
      echo "       the tiering result would be meaningless. Use a real disk." >&2
      exit 1 ;;
  esac

  DB_EST_GB=$(( DB_NUM * (DB_KEY_SIZE + DB_VALUE_SIZE) / 1024 / 1024 / 1024 ))
  DB_FREE_GB=$(df -BG --output=avail "$DB_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')
  # 2x, not 1.5x: fillrandom followed by compact holds the old levels alongside
  # the new ones, so the transient peak is close to twice the logical size.
  # Running out mid-load leaves a CURRENT file behind, which the load step then
  # mistakes for a finished dataset - so this is a hard stop, not a warning.
  DB_NEED_GB=$(( DB_EST_GB * 2 ))
  if [[ -n "${DB_FREE_GB:-}" && $DB_FREE_GB -lt $DB_NEED_GB && ! -f "$DB_DIR/CURRENT" ]]; then
    if [[ "${DB_SKIP_SPACE_CHECK:-0}" == "1" ]]; then
      warn_msg="space check overridden"
      echo "WARNING: $warn_msg (${DB_FREE_GB} GB free, ~${DB_NEED_GB} GB needed)" >&2
    else
      # Fast-tier size, so we can say whether any config that fits on this
      # volume would still oversubscribe node 0 enough to be worth running.
      FAST_GB=$(awk '/MemTotal/{printf "%d", $4/1024/1024}' \
                /sys/devices/system/node/node0/meminfo 2>/dev/null)
      FAST_GB=${FAST_GB:-8}

      # What actually fits, at 80% of free space, given that the load peaks at
      # roughly twice the ON-DISK size and compression shrinks on-disk by
      # ~DB_COMPRESSION_RATIO. Dataset is sized at 1.5x the cache.
      read -r SUG_NUM SUG_CACHE SUG_NUM_C SUG_CACHE_C <<<"$(
        awk -v free="$DB_FREE_GB" -v rec="$(( DB_KEY_SIZE + DB_VALUE_SIZE ))" \
            -v ratio="$DB_COMPRESSION_RATIO" 'BEGIN {
          gb = 1024*1024*1024; usable = free * 0.8;
          fit_plain = usable / 2;
          fit_comp  = (ratio > 0) ? usable / (2 * ratio) : fit_plain;
          printf "%d %d %d %d",
            fit_plain*gb/rec, fit_plain*2/3, fit_comp*gb/rec, fit_comp*2/3;
        }')"

      echo "ERROR: $DB_DIR has ${DB_FREE_GB} GB free; the load peaks near ${DB_NEED_GB} GB" >&2
      echo "       (${DB_EST_GB} GB of data, roughly doubled during compaction)." >&2
      echo "" >&2
      echo "  Configurations that FIT in ${DB_FREE_GB} GB (node 0 is ${FAST_GB} GB):" >&2
      echo "    uncompressed:  DB_NUM=$SUG_NUM DB_CACHE_GB=$SUG_CACHE" >&2
      echo "    with snappy:   DB_COMPRESSION=snappy DB_NUM=$SUG_NUM_C DB_CACHE_GB=$SUG_CACHE_C" >&2
      echo "" >&2
      if [[ ${SUG_CACHE_C:-0} -lt $(( FAST_GB * 2 )) ]]; then
        echo "  WARNING: even compressed, the largest cache that fits (${SUG_CACHE_C} GB) is under" >&2
        echo "  2x the ${FAST_GB} GB fast tier. The run would work, but barely any of the" >&2
        echo "  working set would be forced onto the slow tier, so promotion and" >&2
        echo "  demotion volumes would be small and the comparison between variants" >&2
        echo "  weak. Finding more disk is worth more than shrinking further:" >&2
        echo "    lsblk; df -h -x tmpfs -x devtmpfs" >&2
        echo "  then: DB_DIR=/path/on/larger/volume ..." >&2
      else
        echo "  Or point DB_DIR at a larger local volume: lsblk; df -h -x tmpfs" >&2
      fi
      echo "  Override at your own risk (the load will die mid-way): DB_SKIP_SPACE_CHECK=1" >&2
      exit 1
    fi
  fi

  # A dataset far smaller than expected is the signature of a load that died
  # partway - typically on ENOSPC - and left CURRENT behind.
  if [[ -f "$DB_DIR/CURRENT" ]]; then
    DB_ACTUAL_GB=$(sudo du -sBG "$DB_DIR" 2>/dev/null | tr -dc '0-9' | head -c 6)
    if [[ -n "${DB_ACTUAL_GB:-}" && $DB_EST_GB -gt 0 && $DB_ACTUAL_GB -lt $(( DB_EST_GB / 2 )) ]]; then
      echo "ERROR: $DB_DIR holds only ${DB_ACTUAL_GB} GB but ~${DB_EST_GB} GB was expected." >&2
      echo "       This is almost certainly a load that failed partway and left" >&2
      echo "       CURRENT behind. Every rep would read a truncated dataset." >&2
      echo "       Fix: sudo rm -rf $DB_DIR   then re-run." >&2
      echo "       (If you deliberately set a smaller DB_NUM, pass DB_SKIP_SPACE_CHECK=1.)" >&2
      [[ "${DB_SKIP_SPACE_CHECK:-0}" == "1" ]] || exit 1
    fi
  fi

  if [[ $DB_CACHE_GB -gt $(( MEM_TOTAL_GB * 3 / 4 )) ]]; then
    echo "WARNING: block cache ${DB_CACHE_GB} GB vs ${MEM_TOTAL_GB} GB total RAM -" >&2
    echo "         this will push the machine into reclaim rather than tiering." >&2
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
# The results tree usually lives on the NFS home, which is shared by every
# node: filling it does not just break this run, it breaks the cluster. Logs
# are small, but a run that dies with "write error: No space left on device"
# from a bare echo has almost always hit this rather than the DB volume.
RES_FREE_MB=$(df -BM --output=avail . 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "${RES_FREE_MB:-}" && $RES_FREE_MB -lt 2048 ]]; then
  echo "ERROR: only ${RES_FREE_MB} MB free on the results volume ($(df -h --output=target . | tail -1))." >&2
  echo "       Every tee and echo in this run would fail with ENOSPC." >&2
  echo "       This volume is shared across nodes - clear old results first:" >&2
  echo "         du -sh results/*/*/* | sort -h | tail -20" >&2
  exit 1
fi

# NOTE: header is unchanged on purpose - existing summary.csv files and
# check_bench.py keep working. New information goes to the rep logs.
# Start a FRESH summary.csv for every invocation. The previous behaviour
# appended, so re-running a variant into an existing directory left rows from
# both attempts with repeating rep numbers - a groupby('rep') or .mean() in the
# plotting scripts would then silently average failed runs into the results.
# The old file is kept with a timestamp rather than deleted, since a partial
# run is sometimes still worth looking at.
CSV_HEADER="node,app,variant,condition,thp,rep,kernel,avg_trial_time_s,pgpromote_success_delta,numa_pages_migrated_delta,pgdemote_total_delta,pgdemote_kswapd_delta,pgdemote_direct_delta,nr_active_file_delta,dTLB_load_miss_pct,cache_miss_pct,pgpromote_candidate_delta,promote_success_pct,rl_rejected_delta,threshold_ms_end,run_promote_delta,run_candidate_delta,run_demote_delta"
if [[ -f "$CSV" ]]; then
  if [[ "${CSV_APPEND:-0}" == "1" ]]; then
    echo ">>> appending to existing $CSV (CSV_APPEND=1)"
  else
    mv "$CSV" "$CSV.$(date +%Y%m%d_%H%M%S).bak"
    echo ">>> archived previous summary.csv (set CSV_APPEND=1 to append instead)"
  fi
fi
[[ -f "$CSV" ]] || echo "$CSV_HEADER" > "$CSV"

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
  if [[ "$APP" == "db" ]]; then
    echo "db_bench tunables: bin=$DB_BENCH db=$DB_DIR ($DB_FSTYPE)"
    echo "  dataset  = $DB_NUM keys x ${DB_VALUE_SIZE}B ~= ${DB_EST_GB} GB on disk"
    echo "  read set = $DB_READ_NUM keys, exp_range=$DB_EXP_RANGE (0 = uniform)"
    echo "  cache    = ${DB_CACHE_GB} GB block cache vs $(( $(node_free_mb 0) / 1024 )) GB free on node 0"
    echo "  workload = $DB_BENCHMARK, ${DB_THREADS} threads, ${DB_DURATION}s"
    echo "  mempolicy= $DB_MEMPOLICY  mmap_read=$DB_MMAP_READ"
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
  # watermark_scale_factor governs the gap between the min/low/high watermarks,
  # and therefore how much free memory kswapd maintains on node 0. It is the
  # single most important knob for whether promotion can land at all: at the
  # 0.1% default a 6.6 GB node keeps only ~20 MB above high, kswapd sleeps, and
  # promotions fail against a full node with nothing being demoted.
  # Upper bound: if node 0 free reaches promo_wmark + 1 GB, pgdat_free_space_enough()
  # short-circuits and promotes unconditionally, bypassing the threshold entirely.
  if [[ -n "${WMARK_SCALE:-}" ]]; then
    sudo sh -c "echo $WMARK_SCALE > /proc/sys/vm/watermark_scale_factor"
  fi
  echo -n "watermark_scale_factor = "; cat /proc/sys/vm/watermark_scale_factor
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
  echo "--- swap ---"
  sudo swapoff -a
  swapon --show || true
  echo "(swap above should be empty)"
} 2>&1 | tee "$OUTDIR/setup.log"

# machine-readable copy of the knob state alongside the results
dump_knobs > "$OUTDIR/knobs.txt"

# ===== ONE-TIME DATASET LOAD (db only, outside the timed reps) ==========
# Loading 40 M keys takes tens of minutes. Doing it inside rep 1 would make
# rep 1 incomparable to reps 2..N, which is exactly the kind of silent
# asymmetry that ruins a 5-rep mean. The app script is idempotent: it checks
# for $DB_DIR/CURRENT and returns immediately if the DB already exists, so
# re-running the harness for another variant reuses the same dataset.
if [[ "$APP" == "db" ]]; then
  # The brace group below runs in a SUBSHELL because it is piped into tee, so
  # a bare `exit` there would not stop the harness. Signal failure through a
  # flag file and act on it out here instead.
  LOADFLAG="$OUTDIR/.dbload_failed"
  rm -f "$LOADFLAG"
  # Decide BEFORE the load whether the dataset was already there, so
  # DB_CLEANUP=auto can tell "we made this" from "this was already here".
  [[ -f "$DB_DIR/CURRENT" ]] || DB_CREATED_HERE=1
  {
    echo "===== DB_BENCH LOAD $(date) ====="
    if [[ -f "$DB_DIR/CURRENT" ]]; then
      echo "existing DB at $DB_DIR - reusing it (delete the directory to rebuild)"
      sudo du -sh "$DB_DIR" 2>/dev/null || true
    else
      echo "no DB at $DB_DIR - loading ${DB_NUM} keys, ceiling ${DB_LOAD_MAXSEC}s"
      sudo timeout -k 60 "$DB_LOAD_MAXSEC" \
        env OUT="$OUTDIR/dbload" \
            DB_MODE=load \
            DB_BENCH="$DB_BENCH" DB_DIR="$DB_DIR" \
            DB_NUM="$DB_NUM" DB_KEY_SIZE="$DB_KEY_SIZE" \
            DB_VALUE_SIZE="$DB_VALUE_SIZE" \
            DB_COMPRESSION="$DB_COMPRESSION" \
            DB_COMPRESSION_RATIO="$DB_COMPRESSION_RATIO" \
          bash app_db_bench.sh
      LOAD_RC=$?
      echo "load exit=$LOAD_RC"
      [[ $LOAD_RC -ne 0 ]] && echo "$LOAD_RC" > "$LOADFLAG"
    fi
    echo "--- dropping caches after the load ---"
    sudo timeout 120 sh -c 'echo 3 > /proc/sys/vm/drop_caches' || echo "WARNING: drop_caches timed out"
  } 2>&1 | tee "$OUTDIR/dbload.log"

  if [[ -f "$LOADFLAG" ]]; then
    echo "ERROR: dataset load failed (exit $(cat "$LOADFLAG")) - not starting the reps." >&2
    echo "       See $OUTDIR/dbload.log and $OUTDIR/dbload/db_bench_load.log" >&2
    exit 1
  fi
  sudo chown -R "$(id -un):$(id -gn)" "$OUTDIR" 2>/dev/null || true

  # Only now is it safe to arm cleanup: the dataset exists and is ours to
  # manage. As an EXIT trap it also fires on Ctrl+C or a mid-sweep failure,
  # which is exactly when a 40 GB leftover would otherwise wedge the node.
  echo ">>> dataset cleanup mode: DB_CLEANUP=$DB_CLEANUP (created_here=$DB_CREATED_HERE)"
  trap db_cleanup EXIT
fi

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
    demk0=$(counter pgdemote_kswapd); demd0=$(counter pgdemote_direct)
    dem0=$(( demk0 + demd0 ))
    rej0=$(hist_val rl_rejected)
    {
      echo "--- vmstat BEFORE ---"
      echo "numa_pages_migrated $migr0"; echo "pgpromote_success $prom0"; echo "nr_active_file $file0"
      echo "pgpromote_candidate $cand0"; echo "pgdemote_total $dem0"; echo "rl_rejected $rej0"
      echo "--- BENCHMARK ---"
    } 2>&1 | tee -a "$log"

    # --- start samplers -----------------------------------------------------
    # rep<N>_hist.log keeps the exact '=== epoch ===' format as before, so
    # existing parsers are unaffected. Per-node free memory and PSI go to a
    # SEPARATE file so a hang has a timeline even on non-histogram kernels.
    HIST_TRACE="$OUTDIR/rep${rep}_hist.log"
    MEM_TRACE="$OUTDIR/rep${rep}_mem.log"
    HIST_OK=""; hist_available && HIST_OK=1
    (
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
               GRAPH="$GRAPH" \
               TRIALS="$TRIALS" \
               THREADS="$YCSB_THREADS" \
               JVM_HEAP="$JVM_HEAP" \
               SCALE="$SCALE" \
               DEGREE="$DEGREE" \
               DB_MODE=run \
               DB_BENCH="$DB_BENCH" \
               DB_DIR="$DB_DIR" \
               DB_NUM="$DB_NUM" \
               DB_READ_NUM="$DB_READ_NUM" \
               DB_KEY_SIZE="$DB_KEY_SIZE" \
               DB_VALUE_SIZE="$DB_VALUE_SIZE" \
               DB_CACHE_GB="$DB_CACHE_GB" \
               DB_THREADS="$DB_THREADS" \
               DB_DURATION="$DB_DURATION" \
               DB_EXP_RANGE="$DB_EXP_RANGE" \
               DB_BENCHMARK="$DB_BENCHMARK" \
               DB_MEMPOLICY="$DB_MEMPOLICY" \
               DB_MMAP_READ="$DB_MMAP_READ" \
               DB_COMPRESSION="$DB_COMPRESSION" \
               DB_COMPRESSION_RATIO="$DB_COMPRESSION_RATIO" \
               DB_SEED="$rep" \
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
    demk1=$(counter pgdemote_kswapd); demd1=$(counter pgdemote_direct)
    dem1=$(( demk1 + demd1 ))
    rej1=$(hist_val rl_rejected)
    th_end=$(hist_val threshold_ms)

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
      echo "--- DELTAS ---"
      echo "pgpromote_success_delta   = $((prom1-prom0))"
      echo "numa_pages_migrated_delta = $((migr1-migr0))"
      echo "nr_active_file_delta      = $((file1-file0))"
      echo "pgpromote_candidate_delta = $((cand1-cand0))"
      echo "pgdemote_total_delta      = $((dem1-dem0))"
      echo "rl_rejected_delta         = $rej_delta"
      if [[ "$rej_delta" != "NA" && "$rej_delta" -gt 0 ]]; then
        echo "!!! RATE LIMITER BOUND DURING THIS RUN ($rej_delta pages) - histogram claim confounded !!!"
      fi
      # candidate >> success with ~0 demotion is the node-0-full signature
      if [[ $((cand1-cand0)) -gt 0 && $((prom1-prom0)) -lt $(( (cand1-cand0) / 2 )) ]]; then
        echo "NOTE: promotion success is under half of candidates - check demotion/node 0 capacity"
      fi

      # Apps with a load phase (redis) snapshot vmstat at the phase boundary.
      # The deltas above span load+run; these cover the measured workload only.
      PHASE_VM="$APPOUT/vmstat.after_load"
      if [[ -r "$PHASE_VM" ]]; then
        pv() { awk -v k="$1" '$1==k {print $2}' "$PHASE_VM"; }
        promL=$(pv pgpromote_success); candL=$(pv pgpromote_candidate)
        migrL=$(pv numa_pages_migrated)
        demL=$(( $(pv pgdemote_kswapd) + $(pv pgdemote_direct) ))
        if [[ -n "$promL" ]]; then
          echo "--- RUN-PHASE-ONLY DELTAS (after load marker) ---"
          echo "pgpromote_success_delta   = $((prom1-promL))"
          echo "numa_pages_migrated_delta = $((migr1-migrL))"
          echo "pgpromote_candidate_delta = $((cand1-candL))"
          echo "pgdemote_total_delta      = $((dem1-demL))"
          echo "(load phase alone: promote=$((promL-prom0)) candidate=$((candL-cand0)) demote=$((demL-dem0)))"
          # Written to a file rather than a shell variable: this block runs in
          # a subshell (it is piped into tee), so assignments here do not
          # survive into the CSV row below.
          echo "$((prom1-promL)) $((cand1-candL)) $((dem1-demL))" > "$APPOUT/.runphase"
        fi
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
    elif [[ "$APP" == "db" ]]; then
        # NOTE: for db this column holds MICROSECONDS PER OPERATION, not
        # seconds per trial. It is still a time and still lower-is-better, so
        # the schema and check_bench.py are unchanged, but do not plot it on
        # the same axis as the GAP numbers. Throughput and the read-latency
        # percentiles go to the sidecar dbbench.csv below.
        avg=$(grep -m1 '^\[DBBENCH\] Average Time' "$log" | awk '{print $NF}')
    else
        avg=$(grep -m1 'Average Time' "$log" | awk '{print $NF}')
    fi
    dtlb_pct=$(pct dTLB-load-misses "$log")
    cache_pct=$(pct cache-misses "$log")

    # Run-phase deltas, if the app recorded a load/run boundary. NA for apps
    # (GAP, db) that have no separate load phase inside the measured window.
    if [[ -r "$APPOUT/.runphase" ]]; then
      read -r run_prom run_cand run_dem < "$APPOUT/.runphase"
    else
      run_prom=NA; run_cand=NA; run_dem=NA
    fi

    # Promotion success rate: the fraction of pages the threshold logic wanted
    # to promote that actually made it. A low value here means the result is
    # governed by fast-tier headroom rather than by the promotion policy, so it
    # belongs next to the counters rather than being recomputed later.
    if [[ $((cand1-cand0)) -gt 0 ]]; then
      prom_pct=$(awk -v p=$((prom1-prom0)) -v c=$((cand1-cand0)) 'BEGIN{printf "%.2f", 100*p/c}')
    else
      prom_pct=NA
    fi

    echo "$NODE,$APP,$VAR,$COND,$THP,$rep,$(uname -r),${avg:-NA},$((prom1-prom0)),$((migr1-migr0)),$((dem1-dem0)),$((demk1-demk0)),$((demd1-demd0)),$((file1-file0)),${dtlb_pct:-NA},${cache_pct:-NA},$((cand1-cand0)),$prom_pct,$rej_delta,$th_end,$run_prom,$run_cand,$run_dem" >> "$CSV"

    # --- db_bench sidecar: the metrics that do not fit the shared schema ---
    if [[ "$APP" == "db" ]]; then
        DBCSV="$OUTDIR/dbbench.csv"
        [[ -f "$DBCSV" ]] || echo "node,app,variant,condition,thp,rep,kernel,benchmark,threads,cache_gb,read_num,exp_range,mempolicy,mmap_read,micros_per_op,ops_per_sec,p50_us,p99_us,p999_us,pgpromote_success_delta,pgdemote_total_delta,numa_pages_migrated_delta,threshold_ms_end" > "$DBCSV"

        m="$APPOUT/dbbench_metrics.txt"
        mval() { local v; v=$(grep -m1 "^$1=" "$m" 2>/dev/null | cut -d= -f2-); echo "${v:-NA}"; }

        echo "$NODE,$APP,$VAR,$COND,$THP,$rep,$(uname -r),$(mval benchmark),$(mval threads),$(mval cache_gb),$(mval read_num),$(mval exp_range),$(mval mempolicy),$(mval mmap_read),$(mval micros_per_op),$(mval ops_per_sec),$(mval p50_us),$(mval p99_us),$(mval p999_us),$((prom1-prom0)),$((dem1-dem0)),$((migr1-migr0)),$th_end" >> "$DBCSV"

        # A read-only workload against a cache larger than the fast tier should
        # produce continuous two-way traffic. Near-zero demotion means the
        # working set never actually outgrew node 0 - the run proves nothing.
        if [[ $((prom1-prom0)) -gt 0 && $((dem1-dem0)) -lt $(( (prom1-prom0) / 10 )) ]]; then
          echo "NOTE: demotion is under 10% of promotion - the block cache may be" \
               "smaller than the fast tier, so nothing is being evicted downward." \
               2>&1 | tee -a "$log"
        fi
    fi

    # the app ran under sudo, so its logs came out root-owned; hand them back
    sudo chown -R "$(id -un):$(id -gn)" "$OUTDIR" 2>/dev/null || true
done

echo ">>> done. logs + setup.log + knobs.txt + summary.csv + per-rep hist traces in $OUTDIR"
