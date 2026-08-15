#!/usr/bin/env bash
# app_db_bench.sh - RocksDB db_bench workload for the two-tier NUMA harness.
#
# Invoked by run-bench-variant.sh under sudo, through an explicit env block.
# Nothing here is derived from $HOME: under sudo $HOME is /root.
#
# Two modes, selected by DB_MODE:
#   load : create/populate the DB once, then compact it.  NOT timed, run by
#          the harness before the rep loop so no rep pays the load cost.
#   run  : the measured read phase.  Prints the line the harness parses:
#              [DBBENCH] Average Time: <micros_per_op>
#          and writes machine-readable metrics to $OUT/dbbench_metrics.txt
#
# Why the flags below are what they are (this is the part that matters for
# a tiering experiment, not the throughput number):
#
#   --use_direct_reads       SST reads bypass the page cache.  Unmapped page
#                            cache never takes a NUMA hint fault, so it would
#                            silently occupy the fast tier while contributing
#                            nothing to the histogram.  Direct reads push the
#                            entire resident working set into the block cache,
#                            which is anonymous heap and therefore migratable.
#   --compression_type=none  a cached block occupies its full logical size, so
#                            --cache_size maps predictably onto RSS.
#   --cache_size             THE memory dial.  Set it to a multiple of the fast
#                            tier so promotion and demotion never converge.
#   --read_random_exp_range  turns readrandom from uniform into exponentially
#                            skewed.  Uniform access gives a flat hint-fault
#                            latency distribution with no hot decile, which is
#                            the worst possible input for a percentile-based
#                            promotion threshold.
#   numactl --preferred=1    starts every allocation on the slow tier, so the
#                            whole warm-up is promotion traffic.  NEVER use
#                            --membind=1: strict binding makes mpol_misplaced()
#                            return NUMA_NO_NODE and promotion is silently off.
set -uo pipefail

OUT="${OUT:-.}"
mkdir -p "$OUT"

DB_MODE="${DB_MODE:-run}"
DB_BENCH="${DB_BENCH:-./rocksdb/db_bench}"
DB_DIR="${DB_DIR:-/var/tmp/db_bench}"

DB_NUM="${DB_NUM:-40000000}"          # keys in the DB (load phase)
DB_READ_NUM="${DB_READ_NUM:-$DB_NUM}" # key range reads are drawn from
DB_KEY_SIZE="${DB_KEY_SIZE:-16}"
DB_VALUE_SIZE="${DB_VALUE_SIZE:-1024}"
DB_CACHE_GB="${DB_CACHE_GB:-24}"      # block cache; ~3x the 8 GB fast tier
DB_THREADS="${DB_THREADS:-8}"         # keep <= number of pinned cores
DB_DURATION="${DB_DURATION:-600}"     # seconds in the measured phase
DB_EXP_RANGE="${DB_EXP_RANGE:-8}"     # 0 = uniform; higher = more skew
DB_BENCHMARK="${DB_BENCHMARK:-readrandom}"
DB_MEMPOLICY="${DB_MEMPOLICY:-local}"   # local = no numactl; see note below
DB_MMAP_READ="${DB_MMAP_READ:-0}"     # 1 = mmap the SSTs instead of direct I/O
DB_SEED="${DB_SEED:-1}"
DB_BLOOM_BITS="${DB_BLOOM_BITS:-10}"
# Compression is the one knob that cuts disk usage WITHOUT weakening the
# tiering experiment: RocksDB's block cache holds UNCOMPRESSED blocks, so
# --cache_size still maps onto the same RSS and the same fast-tier pressure,
# while the SSTs on disk shrink by roughly --compression_ratio. The cost is
# CPU on every block-cache miss, which adds a little latency noise.
#   none   - predictable, needs ~1 byte of disk per byte of data
#   snappy - cheap, roughly halves the on-disk dataset
#   zstd   - smaller still, more CPU per miss
DB_COMPRESSION="${DB_COMPRESSION:-none}"
DB_COMPRESSION_RATIO="${DB_COMPRESSION_RATIO:-0.5}"

CACHE_BYTES=$(( DB_CACHE_GB * 1024 * 1024 * 1024 ))

[[ -x "$DB_BENCH" ]] || { echo "ERROR: db_bench not executable at '$DB_BENCH'" >&2; exit 1; }

# --- memory policy ------------------------------------------------------
# See the long note in app_redis_ycsb.sh: ANY explicit mempolicy (preferred,
# membind, interleave) yields a policy without MPOL_F_MOF, task_numa_work()
# then skips every VMA, and the run produces zero hint faults and zero
# migrations. 'local' (no numactl) is the only setting compatible with NUMA
# balancing, so it is the default here.
NUMA_PREFIX=()
case "$DB_MEMPOLICY" in
  local)  ;;
  preferred|interleave|membind*)
    case "$DB_MEMPOLICY" in
      preferred)  NUMA_PREFIX=(numactl --preferred=1) ;;
      interleave) NUMA_PREFIX=(numactl --interleave=0,1) ;;
      membind*)   NUMA_PREFIX=(numactl --membind=1) ;;
    esac
    echo "WARNING: DB_MEMPOLICY=$DB_MEMPOLICY sets an explicit mempolicy, so the" >&2
    echo "         NUMA scanner will skip every VMA and this run will record" >&2
    echo "         ZERO promotions and ZERO demotions. Use 'local'." >&2
    if [[ "${ALLOW_ZERO_MIGRATION:-0}" != "1" ]]; then
      echo "ERROR: refusing to run. Set ALLOW_ZERO_MIGRATION=1 to override." >&2
      exit 1
    fi ;;
  *) echo "ERROR: unknown DB_MEMPOLICY '$DB_MEMPOLICY'" >&2; exit 1 ;;
esac

# --- I/O path -----------------------------------------------------------
if [[ "$DB_MMAP_READ" == "1" ]]; then
  # SSTs are mapped, so file-backed pages also take hint faults. Noisier, but
  # a legitimate second variant: it exercises promotion of file folios.
  IO_FLAGS=(--mmap_read=true --use_direct_reads=false)
else
  IO_FLAGS=(--use_direct_reads=true)
fi

COMMON=(
  --db="$DB_DIR"
  --key_size="$DB_KEY_SIZE"
  --value_size="$DB_VALUE_SIZE"
  --compression_type="$DB_COMPRESSION"
  --compression_ratio="$DB_COMPRESSION_RATIO"
  --bloom_bits="$DB_BLOOM_BITS"
  --cache_index_and_filter_blocks=false
  --seed="$DB_SEED"
)

# ========================= LOAD MODE ====================================
if [[ "$DB_MODE" == "load" ]]; then
  if [[ -f "$DB_DIR/CURRENT" ]]; then
    echo "[DBBENCH] existing DB at $DB_DIR - skipping load"
    du -sh "$DB_DIR" 2>/dev/null || true
    exit 0
  fi

  mkdir -p "$DB_DIR" || { echo "ERROR: cannot create $DB_DIR" >&2; exit 1; }
  echo "[DBBENCH] loading $DB_NUM keys x ${DB_VALUE_SIZE}B into $DB_DIR"

  "$DB_BENCH" "${COMMON[@]}" \
      --benchmarks=fillrandom,compact \
      --num="$DB_NUM" \
      --threads=1 \
      --disable_wal=1 \
      --cache_size=$((1024 * 1024 * 1024)) \
      --use_direct_io_for_flush_and_compaction=true \
      2>&1 | tee "$OUT/db_bench_load.log"
  rc=${PIPESTATUS[0]}

  echo "[DBBENCH] load exit=$rc, on-disk size:"
  du -sh "$DB_DIR" 2>/dev/null || true
  exit "$rc"
fi

# ========================= RUN MODE =====================================
if [[ ! -f "$DB_DIR/CURRENT" ]]; then
  echo "ERROR: no RocksDB at $DB_DIR - the load phase did not run." >&2
  echo "       Run: DB_MODE=load bash app_db_bench.sh" >&2
  exit 1
fi

RUNLOG="$OUT/db_bench_run.log"

echo "[DBBENCH] benchmark=$DB_BENCHMARK threads=$DB_THREADS duration=${DB_DURATION}s"
echo "[DBBENCH] cache=${DB_CACHE_GB}GB read_range=$DB_READ_NUM exp_range=$DB_EXP_RANGE"
echo "[DBBENCH] mempolicy=$DB_MEMPOLICY mmap_read=$DB_MMAP_READ"

"${NUMA_PREFIX[@]}" "$DB_BENCH" "${COMMON[@]}" \
    --use_existing_db=1 \
    --benchmarks="$DB_BENCHMARK" \
    --num="$DB_READ_NUM" \
    --duration="$DB_DURATION" \
    --threads="$DB_THREADS" \
    --cache_size="$CACHE_BYTES" \
    --cache_numshardbits=6 \
    --read_random_exp_range="$DB_EXP_RANGE" \
    "${IO_FLAGS[@]}" \
    --histogram=1 \
    --report_interval_seconds=1 \
    --report_file="$OUT/db_bench_tput.csv" \
    2>&1 | tee "$RUNLOG"
rc=${PIPESTATUS[0]}

# --- parse -------------------------------------------------------------
# db_bench summary line looks like:
#   readrandom : 8.325 micros/op 120118 ops/sec 600.000 seconds ... ;
# fields:        $1     $2 $3    $4        $5     $6
read -r MICROS OPS <<<"$(awk -v b="$DB_BENCHMARK" \
    '$1==b && $2==":" {m=$3; o=$5} END{print (m==""?"NA":m), (o==""?"NA":o)}' "$RUNLOG")"

# --histogram=1 prints:  Percentiles: P50: 6.23 P75: 9.11 P99: 45.20 P99.9: ...
read -r P50 P99 P999 <<<"$(awk '/^Percentiles:/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "P50:")   a = $(i+1)
        if ($i == "P99:")   b = $(i+1)
        if ($i == "P99.9:") c = $(i+1)
      }
    }
    END { print (a==""?"NA":a), (b==""?"NA":b), (c==""?"NA":c) }' "$RUNLOG")"

{
  echo "micros_per_op=$MICROS"
  echo "ops_per_sec=$OPS"
  echo "p50_us=$P50"
  echo "p99_us=$P99"
  echo "p999_us=$P999"
  echo "benchmark=$DB_BENCHMARK"
  echo "threads=$DB_THREADS"
  echo "cache_gb=$DB_CACHE_GB"
  echo "read_num=$DB_READ_NUM"
  echo "exp_range=$DB_EXP_RANGE"
  echo "mempolicy=$DB_MEMPOLICY"
  echo "mmap_read=$DB_MMAP_READ"
} > "$OUT/dbbench_metrics.txt"

echo "[DBBENCH] ops_per_sec=$OPS p50=${P50}us p99=${P99}us p99.9=${P999}us"
# The harness greps this line. Units are microseconds per operation: a time,
# lower is better, same orientation as GAP's average trial time.
echo "[DBBENCH] Average Time: ${MICROS}"

exit "$rc"
