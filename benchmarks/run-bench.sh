#!/usr/bin/env bash
# run-bench-variant.sh - benchmark an arbitrary kernel VARIANT (not a static threshold).
#
# Usage:  ./run-bench-variant.sh <app> <variant> [cond] [reps]   (run with bash, NOT sh)
#   app     : key from the APPS map below (pr, bfs, cc, bc, ...)
#   variant : free-form label for what you're testing (histogram, static, stock, ...)
#   cond    : 1 = THP never/never (default), 2 = THP always
#   reps    : repetitions on this node (default 5)
#   rep0    : rep-number offset (default 0) - lets a sweep driver interleave
#             configs without clobbering rep logs or duplicating rep numbers
#   e.g.  ./run-bench-variant.sh pr histogram 1 10
#         ./run-bench-variant.sh pr histogram 1 1 3   # writes rep4.log
# Run from the directory holding your app scripts and ./gapbs.
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
REP0="${5:-0}"
MAXSEC="${MAXSEC:-3600}"          # per-rep wall-clock cap; hung reps are killed,
                                  # diagnosed, and the sweep moves on
NODE="$(hostname -s)"

CORES="0,1,2,3,4,5,6,7"           # cores on the FAST node - keep IDENTICAL across ALL runs
KMOD_DIR="$HOME/Natalia_SS2026/Linux-6-16-Tiers"
EVENTS="dTLB-load-misses,dTLB-loads,dTLB-store-misses,dTLB-stores,cache-misses,cache-references,bus-cycles"

# --- NBP histogram instrumentation (harmless on non-histogram kernels) --
HIST_DBG="/sys/kernel/debug/nbp_hist"
HIST_SAMPLE_S=2                   # snapshot cadence for the per-rep trace

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
# three-zone case counters, snapshotted as a group
ZONE_KEYS=(case1 case2_ok case2_no case3 case_warm)
# ------------------------------------------------------------------------

CMD="${APPS[$APP]:-}"
[[ -n "$CMD" ]] || { echo "unknown app '$APP' - known: ${!APPS[*]}" >&2; exit 1; }
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

OUTDIR="results/${NODE}/${APP}/${VAR}_cond${COND}"
mkdir -p "$OUTDIR"
CSV="$OUTDIR/summary.csv"
[[ -f "$CSV" ]] || echo "node,app,variant,condition,thp,rep,kernel,avg_trial_time_s,pgpromote_success_delta,numa_pages_migrated_delta,nr_active_file_delta,dTLB_load_miss_pct,cache_miss_pct,pgpromote_candidate_delta,rl_rejected_delta,threshold_ms_end,case1_delta,case2_ok_delta,case2_no_delta,case3_delta,case_warm_delta,zone1_ms_end,zone2_ms_end,peak_bucket_end" > "$CSV"

counter() { local v; v=$(grep -m1 "^$1 " /proc/vmstat | awk '{print $2}'); echo "${v:-0}"; }
# fast/slow tier occupancy - the state that plausibly carries between runs
tiers() {
  local n f t
  for n in 0 1; do
    t=$(awk '/MemTotal/{print $4}' /sys/devices/system/node/node$n/meminfo 2>/dev/null)
    f=$(awk '/MemFree/{print $4}'  /sys/devices/system/node/node$n/meminfo 2>/dev/null)
    [[ -n "$t" ]] && printf "node%s: %s MB free of %s MB (%d%% used)  " \
        "$n" "$((f/1024))" "$((t/1024))" "$(( 100*(t-f)/t ))"
  done
  echo
}
# everything worth having if a rep wedges
diagnose() {
  local out="$1"
  {
    echo "===== HANG DIAGNOSTIC $(date) ====="
    echo "--- tiers ---"; tiers
    echo "--- nbp_hist ---"; sudo cat "$HIST_DBG" 2>/dev/null
    echo "--- vmstat (promote/demote/migrate) ---"
    grep -E 'pgpromote|pgdemote|numa_pages_migrated|numa_hint' /proc/vmstat
    echo "--- processes ---"
    ps -eo pid,stat,wchan:32,pcpu,etime,comm | grep -Ev ' \[' | head -30
    for p in $(pgrep -x pr; pgrep -x perf); do
      echo "--- pid $p threads ---"
      ps -L -o tid,stat,wchan:32 -p "$p" 2>/dev/null
      for t in /proc/$p/task/*; do
        echo -n "  $(basename $t) syscall: "; cat $t/syscall 2>/dev/null
        sudo cat $t/stack 2>/dev/null | head -12
      done
    done
    echo "--- blocked tasks (sysrq-w) ---"
    sudo sh -c 'echo w > /proc/sysrq-trigger' 2>/dev/null
    sleep 1; dmesg | tail -120
  } > "$out" 2>&1
}
pct() { awk -v ev="$1" '{ci=0;pi=0;for(i=1;i<=NF;i++){if($i==ev)ci=i-1;if($i=="#")pi=i+1};if(ci>0){c=$ci;gsub(/,/,"",c);c=c+0;p=(pi>0)?$pi:"";gsub(/%/,"",p);if(c>max){max=c;best=p}}}END{print best}' "$2"; }

# ===== ONE-TIME SETUP (run AND verified) ================================
{
  echo "===== SETUP $(date) ====="
  echo "node=$NODE kernel=$(uname -r) app=$APP variant=$VAR cond=$COND ($THP) reps=$REPS"
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
  echo "--- tier occupancy BEFORE this batch ---"
  tiers
  echo "--- swap ---"
  sudo swapoff -a
  swapon --show || true
  echo "(swap above should be empty)"
} 2>&1 | tee -a "$OUTDIR/setup.log"

# ===== REPEATED RUNS ====================================================
for rep in $(seq 1 "$REPS"); do
    repno=$((REP0+rep))
    log="$OUTDIR/rep${repno}.log"
    {
      echo "########## REP $repno (local $rep/$REPS)  $(date) ##########"
      echo "node=$NODE app=$APP variant=$VAR cond=$COND ($THP) kernel=$(uname -r) cores=$CORES cmd='$CMD'"
      echo "--- THP state for this run ---"
      echo -n "enabled = "; sudo cat /sys/kernel/mm/transparent_hugepage/enabled
      echo -n "defrag  = "; sudo cat /sys/kernel/mm/transparent_hugepage/defrag
      echo "--- tier occupancy before rep ---"
      tiers
      echo "--- sync + drop caches ---"
      sudo sync
      sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
      echo "caches dropped"
    } 2>&1 | tee "$log"

    prom0=$(counter pgpromote_success); migr0=$(counter numa_pages_migrated); file0=$(counter nr_active_file)
    cand0=$(counter pgpromote_candidate)
    rej0=$(hist_val rl_rejected)
    for k in "${ZONE_KEYS[@]}"; do declare "z0_$k=$(hist_val "$k")"; done
    {
      echo "--- vmstat BEFORE ---"
      echo "numa_pages_migrated $migr0"; echo "pgpromote_success $prom0"; echo "nr_active_file $file0"
      echo "pgpromote_candidate $cand0"; echo "rl_rejected $rej0"
      echo "--- BENCHMARK ---"
    } 2>&1 | tee -a "$log"

    # --- start histogram trace sampler (same '=== epoch ===' format as before) ---
    HIST_TRACE="$OUTDIR/rep${repno}_hist.log"
    HIST_PID=""
    if hist_available; then
        (
          while :; do
            echo "=== $(date +%s) ==="
            sudo cat "$HIST_DBG"
            sleep "$HIST_SAMPLE_S"
          done
        ) >> "$HIST_TRACE" 2>/dev/null &
        HIST_PID=$!
    fi

    timeout --signal=TERM --kill-after=120 "$MAXSEC" \
      sudo /usr/bin/time --verbose \
        perf stat -a --per-socket -e "$EVENTS" \
        -- taskset -c "$CORES" $CMD 2>&1 | tee -a "$log"
    TIMED_OUT=0
    if [[ "${PIPESTATUS[0]}" == "124" ]]; then
        TIMED_OUT=1
        echo "!!! REP TIMED OUT after ${MAXSEC}s - collecting diagnostics !!!" | tee -a "$log"
        diagnose "$OUTDIR/rep${repno}_hang.log"
        sudo pkill -9 -x pr; sudo pkill -9 -x perf; sleep 5
    fi

    # --- stop sampler ---
    if [[ -n "$HIST_PID" ]]; then
        kill "$HIST_PID" 2>/dev/null
        wait "$HIST_PID" 2>/dev/null
    fi

    prom1=$(counter pgpromote_success); migr1=$(counter numa_pages_migrated); file1=$(counter nr_active_file)
    cand1=$(counter pgpromote_candidate)
    rej1=$(hist_val rl_rejected)
    th_end=$(hist_val threshold_ms)
    z1_end=$(hist_val zone1_ms); z2_end=$(hist_val zone2_ms)
    peak_end=$(hist_val peak_bucket)
    ZONE_DELTAS=""
    for k in "${ZONE_KEYS[@]}"; do
        v0="z0_$k"
        ZONE_DELTAS+="$(hist_delta "${!v0}" "$(hist_val "$k")"),"
    done

    if [[ "$rej0" =~ ^[0-9]+$ && "$rej1" =~ ^[0-9]+$ ]]; then
        rej_delta=$((rej1-rej0))
    else
        rej_delta=NA
    fi

    {
      echo "--- vmstat AFTER ---"
      echo "numa_pages_migrated $migr1"; echo "pgpromote_success $prom1"; echo "nr_active_file $file1"
      echo "pgpromote_candidate $cand1"; echo "rl_rejected $rej1"; echo "threshold_ms $th_end"
      echo "zone1_ms $z1_end"; echo "zone2_ms $z2_end"; echo "peak_bucket $peak_end"
      echo "--- three-zone case deltas (case1,case2_ok,case2_no,case3,case_warm) ---"
      echo "${ZONE_DELTAS%,}"
      echo "--- tier occupancy after rep ---"
      tiers
      echo "--- DELTAS ---"
      echo "pgpromote_success_delta   = $((prom1-prom0))"
      echo "numa_pages_migrated_delta = $((migr1-migr0))"
      echo "nr_active_file_delta      = $((file1-file0))"
      echo "pgpromote_candidate_delta = $((cand1-cand0))"
      echo "rl_rejected_delta         = $rej_delta"
      if [[ "$rej_delta" != "NA" && "$rej_delta" -gt 0 ]]; then
        echo "!!! RATE LIMITER BOUND DURING THIS RUN ($rej_delta pages) - histogram claim confounded !!!"
      fi
    } 2>&1 | tee -a "$log"

    if [[ "$APP" == "bfs_cc" ]]; then
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
    [[ "$TIMED_OUT" == "1" ]] && avg="TIMEOUT"
    dtlb_pct=$(pct dTLB-load-misses "$log")
    cache_pct=$(pct cache-misses "$log")

    echo "$NODE,$APP,$VAR,$COND,$THP,$repno,$(uname -r),${avg:-NA},$((prom1-prom0)),$((migr1-migr0)),$((file1-file0)),${dtlb_pct:-NA},${cache_pct:-NA},$((cand1-cand0)),$rej_delta,$th_end,${ZONE_DELTAS}${z1_end},${z2_end},${peak_end}" >> "$CSV"
done

echo ">>> done. logs + setup.log + summary.csv + per-rep hist traces in $OUTDIR"
