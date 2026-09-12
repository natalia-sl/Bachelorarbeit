#!/usr/bin/env bash
# run-bench-variant.sh - benchmark an arbitrary kernel VARIANT (not a static threshold).
#
# Usage:  ./run-bench-variant.sh <app> <variant> [cond] [reps]   (run with bash, NOT sh)
#   app     : key from the APPS map below (pr, bfs, cc, bc, bfs_cc, redis)
#   variant : free-form label for what you're testing (histogram, static, stock, ...)
#   cond    : 1 = THP never/never (default), 2 = THP always
#   reps    : repetitions on this node (default 5)
#   e.g.  ./run-bench-variant.sh pr histogram 1 10
# Run from the directory holding your app scripts and ./gapbs.
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
# ------------------------------------------------------------------------

# --- NBP histogram instrumentation (harmless on non-histogram kernels) --
HIST_DBG="/sys/kernel/debug/nbp_hist"
HIST_SAMPLE_S=2                   # snapshot cadence for the per-rep trace
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
  ps -eo pid,ppid,stat,wchan:32,rss,etime,comm | grep -E 'bfs|cc|pr|bc|redis|java|perf' | grep -v grep
  echo "--- kernel stacks ---"
  for pid in $(pgrep -f 'gapbs/(bfs|cc|pr|bc)|redis-server' 2>/dev/null); do
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
  sleep 3
  sudo pkill -9 -f 'gapbs/(bfs|cc|pr|bc)' 2>/dev/null || true
  sudo pkill -9 -f 'ycsb' 2>/dev/null || true
  sleep 2
  echo "still running:"
  ps -eo pid,stat,comm | grep -E 'bfs|cc|pr|redis|java' | grep -v grep || echo "(none)"
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
    rej0=$(hist_val rl_rejected)
    for k in "${ZONE_KEYS[@]}"; do declare "z0_$k=$(hist_val "$k")"; done
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
      echo "--- DELTAS ---"
      echo "pgpromote_success_delta   = $((prom1-prom0))"
      echo "numa_pages_migrated_delta = $((migr1-migr0))"
      echo "nr_active_file_delta      = $((file1-file0))"
      echo "pgpromote_candidate_delta = $((cand1-cand0))"
      echo "pgdemote_total_delta      = $((dem1-dem0))"
      echo "rl_rejected_delta         = $rej_delta"
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
    else
        avg=$(grep -m1 'Average Time' "$log" | awk '{print $NF}')
    fi
    dtlb_pct=$(pct dTLB-load-misses "$log")
    cache_pct=$(pct cache-misses "$log")

    echo "$NODE,$APP,$VAR,$COND,$THP,$rep,$(uname -r),${avg:-NA},$((prom1-prom0)),$((migr1-migr0)),$((file1-file0)),${dtlb_pct:-NA},${cache_pct:-NA},$((cand1-cand0)),$rej_delta,$th_end" >> "$CSV"

    # Zone data goes to its own CSV rather than widening summary.csv, so
    # check_bench.py and every existing summary.csv keep working unchanged.
    # Join on (node,app,variant,condition,rep).
    ZCSV="$OUTDIR/zones.csv"
    [[ -f "$ZCSV" ]] || echo "node,app,variant,condition,rep,zones,zone1_ms_end,zone2_ms_end,peak_bucket_end,case1_delta,case2_ok_delta,case2_no_delta,case3_delta,case_warm_delta" > "$ZCSV"
    echo "$NODE,$APP,$VAR,$COND,$rep,${zones_on},${z1_end},${z2_end},${peak_end},${ZONE_DELTAS}" >> "$ZCSV"

    # the app ran under sudo, so its logs came out root-owned; hand them back
    sudo chown -R "$(id -un):$(id -gn)" "$OUTDIR" 2>/dev/null || true
done

echo ">>> done. logs + setup.log + knobs.txt + summary.csv + zones.csv + per-rep hist traces in $OUTDIR"
