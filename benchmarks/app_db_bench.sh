#!/usr/bin/env bash
# app_db_bench.sh - RocksDB db_bench workload for the two-tier NUMA harness.
#
# Invoked by run-bench-variant.sh under sudo, through an explicit env block.
# Nothing here is derived from $HOME: under sudo $HOME is /root.
#
# Three modes, selected by DB_MODE:
#   load  : create/populate the DB once per node, then compact it. NOT timed.
#           Run by tiers_setup.sh (or by hand), never inside a rep.
#   stamp : write the dataset stamp for a DB that was loaded before stamps
#           existed. Refuses if the on-disk size does not match DB_NUM.
#   run   : the measured read phase. Prints the line the harness parses:
#               [DBBENCH] Average Time: <micros_per_op>
#           and writes machine-readable metrics to $OUT/dbbench_metrics.txt
#
# Why the flags below are what they are (this is the part that matters for
# a tiering experiment, not the throughput number):
#
#   fillseq                  every key in [0, DB_NUM) is written exactly once.
#                            fillrandom draws keys WITH replacement, so only
#                            ~63% (1 - 1/e) of them exist after compaction and
#                            ~37% of reads become bloom-filter misses that
#                            never touch a data block.
#   --use_direct_reads       SST reads bypass the page cache. Unmapped page
#                            cache never takes a NUMA hint fault, so it would
#                            occupy the fast tier while contributing nothing
#                            to the histogram. Direct reads push the entire
#                            resident working set into the block cache, which
#                            is anonymous heap and therefore scanned/migratable.
#   --compression_type=none  a cached block occupies its full logical size, so
#                            --cache_size maps predictably onto RSS.
#   --cache_size             THE memory dial. Default holds the whole 12M-key
#                            dataset (~11.7 GiB), so after warm-up no read goes
#                            to disk and the run measures memory, not I/O.
#   --read_random_exp_range  turns readrandom from uniform into exponentially
#                            skewed. Share of accesses to the hottest fraction
#                            f of keys is 1 + ln(f)/R. R=0 is the flat control.
#   no numactl               ANY explicit mempolicy (preferred, membind,
#                            interleave) lacks MPOL_F_MOF, task_numa_work()
#                            skips every VMA and the run records zero hint
#                            faults and zero migrations. See the guard below.
set -uo pipefail

OUT="${OUT:-.}"
mkdir -p "$OUT"

DB_MODE="${DB_MODE:-run}"
DB_BENCH="${DB_BENCH:-./rocksdb/db_bench}"
DB_DIR="${DB_DIR:-/mydata/db_bench}"
STAMP="$DB_DIR/DATASET_STAMP"

DB_NUM="${DB_NUM:-12000000}"          # keys in the DB (load phase)
DB_READ_NUM="${DB_READ_NUM:-$DB_NUM}" # key range reads are drawn from
DB_KEY_SIZE="${DB_KEY_SIZE:-16}"
DB_VALUE_SIZE="${DB_VALUE_SIZE:-1024}"
DB_CACHE_GB="${DB_CACHE_GB:-16}"      # >= dataset: no disk reads after warm-up
DB_THREADS="${DB_THREADS:-8}"         # keep <= number of pinned cores
DB_DURATION="${DB_DURATION:-600}"     # seconds in the measured phase
DB_EXP_RANGE="${DB_EXP_RANGE:-8}"     # 0 = uniform; higher = more skew
DB_BENCHMARK="${DB_BENCHMARK:-readrandom}"
# readseq = scan the DB once per thread before the measured benchmark, in the
# SAME process (the block cache is per process). Fills the cache in key order,
# so the hot keys, which are scattered over the key space, start mostly on
# node 1 and promotion has work to do. none = cold start: the hottest blocks
# are cached first and first-touch puts them on node 0.
DB_WARMUP="${DB_WARMUP:-none}"
DB_MEMPOLICY="${DB_MEMPOLICY:-local}"   # local = no numactl; see note above
DB_MMAP_READ="${DB_MMAP_READ:-0}"     # 1 = negative control, see I/O path
DB_SEED="${DB_SEED:-1}"
DB_BLOOM_BITS="${DB_BLOOM_BITS:-10}"
# Compression cuts disk usage WITHOUT changing the tiering experiment: the
# block cache holds UNCOMPRESSED blocks, so --cache_size still maps onto the
# same RSS. The cost is CPU on every block-cache miss.
#   none   - predictable, needs ~1 byte of disk per byte of data
#   snappy - roughly halves the on-disk dataset
#   zstd   - smaller still, more CPU per miss
DB_COMPRESSION="${DB_COMPRESSION:-none}"
DB_COMPRESSION_RATIO="${DB_COMPRESSION_RATIO:-0.5}"

CACHE_BYTES=$(( DB_CACHE_GB * 1024 * 1024 * 1024 ))

[[ -x "$DB_BENCH" ]] || { echo "ERROR: db_bench not executable at '$DB_BENCH'" >&2; exit 1; }

# expected on-disk size in MB: one row = key + value (+~2% block/index overhead)
est_mb() {
  local ratio=1
  [[ "$DB_COMPRESSION" != "none" ]] && ratio="$DB_COMPRESSION_RATIO"
  awk -v n="$DB_NUM" -v k="$DB_KEY_SIZE" -v v="$DB_VALUE_SIZE" -v r="$ratio" \
      'BEGIN{printf "%d", n*(k+v*r)*1.02/1048576}'
}
db_mb() { du -sm "$DB_DIR" 2>/dev/null | awk '{print $1}'; }
stamp_val() { awk -F= -v k="$1" '$1==k{print $2}' "$STAMP" 2>/dev/null; }

# RocksDB version from the source tree db_bench was built in
rocks_version() {
  local h
  h="$(dirname "$(readlink -f "$DB_BENCH")")/include/rocksdb/version.h"
  awk '/#define ROCKSDB_MAJOR/{a=$3} /#define ROCKSDB_MINOR/{b=$3} /#define ROCKSDB_PATCH/{c=$3}
       END{ if (a=="") print "unknown"; else printf "%s.%s.%s\n", a, b, c }' "$h" 2>/dev/null \
    || echo unknown
}

write_stamp() {
  {
    echo "num=$DB_NUM"
    echo "key_size=$DB_KEY_SIZE"
    echo "value_size=$DB_VALUE_SIZE"
    echo "compression=$DB_COMPRESSION"
    echo "fill=$1"
    echo "rocksdb=$(rocks_version)"
    echo "size_mb=$(db_mb)"
    echo "host=$(hostname -s)"
    echo "date=$(date -Is)"
  } > "$STAMP"
}

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
    if [[ ! -f "$STAMP" ]]; then
      echo "ERROR: $DB_DIR holds a DB without a DATASET_STAMP. It may be a" >&2
      echo "       truncated load or an old fillrandom DB. Either delete it" >&2
      echo "       (rm -rf $DB_DIR/*) or, if you KNOW it is a full fillseq load" >&2
      echo "       of DB_NUM=$DB_NUM keys, run: DB_MODE=stamp bash app_db_bench.sh" >&2
      exit 1
    fi
    if [[ "$(stamp_val num)" != "$DB_NUM" || "$(stamp_val key_size)" != "$DB_KEY_SIZE" \
          || "$(stamp_val value_size)" != "$DB_VALUE_SIZE" ]]; then
      echo "ERROR: existing DB was loaded with a different shape:" >&2
      cat "$STAMP" >&2
      echo "       wanted num=$DB_NUM key=$DB_KEY_SIZE value=$DB_VALUE_SIZE." >&2
      echo "       Delete it (rm -rf $DB_DIR/*) and load again." >&2
      exit 1
    fi
    echo "[DBBENCH] existing stamped DB at $DB_DIR - skipping load"
    cat "$STAMP"
    exit 0
  fi

  mkdir -p "$DB_DIR" || { echo "ERROR: cannot create $DB_DIR" >&2; exit 1; }

  # The final full compaction rewrites the DB while the old files still exist,
  # so the load transiently needs ~2x the dataset.
  need_mb=$(( $(est_mb) * 2 ))
  free_mb=$(df -BM --output=avail "$DB_DIR" | tail -1 | tr -dc '0-9')
  if [[ "${free_mb:-0}" -lt "$need_mb" ]]; then
    echo "ERROR: $DB_DIR has ${free_mb} MB free, the load needs ~${need_mb} MB" >&2
    echo "       (dataset ~$(est_mb) MB, x2 for the final compaction)." >&2
    exit 1
  fi

  echo "[DBBENCH] loading $DB_NUM keys x ${DB_VALUE_SIZE}B into $DB_DIR (fillseq)"
  "$DB_BENCH" "${COMMON[@]}" \
      --benchmarks=fillseq,compact \
      --num="$DB_NUM" \
      --threads=1 \
      --disable_wal=1 \
      --cache_size=$((1024 * 1024 * 1024)) \
      --use_direct_io_for_flush_and_compaction=true \
      2>&1 | tee "$OUT/db_bench_load.log"
  rc=${PIPESTATUS[0]}

  echo "[DBBENCH] load exit=$rc, on-disk size: $(db_mb) MB (expected ~$(est_mb) MB)"
  if [[ $rc -eq 0 ]]; then
    write_stamp fillseq
    echo "[DBBENCH] stamp written:"; cat "$STAMP"
  else
    echo "ERROR: load failed - NOT stamping. Delete $DB_DIR/* before retrying." >&2
  fi
  exit "$rc"
fi

# ========================= STAMP MODE ===================================
# For a DB loaded by hand before stamps existed. The size check is what
# catches a fillrandom DB (~63% of the expected size) or a truncated load.
if [[ "$DB_MODE" == "stamp" ]]; then
  [[ -f "$DB_DIR/CURRENT" ]] || { echo "ERROR: no DB at $DB_DIR" >&2; exit 1; }
  have=$(db_mb); want=$(est_mb)
  if awk -v h="$have" -v w="$want" 'BEGIN{exit !(h < 0.9*w || h > 1.15*w)}'; then
    echo "ERROR: $DB_DIR is $have MB, a full load of $DB_NUM keys is ~$want MB." >&2
    echo "       Not stamping. Delete and load again." >&2
    exit 1
  fi
  write_stamp "fillseq(stamped-after)"
  echo "[DBBENCH] stamped ($have MB vs ~$want MB expected):"; cat "$STAMP"
  exit 0
fi

[[ "$DB_MODE" == "run" ]] || { echo "ERROR: DB_MODE='$DB_MODE' (load|stamp|run)" >&2; exit 1; }

# ========================= RUN MODE =====================================
if [[ ! -f "$DB_DIR/CURRENT" ]]; then
  echo "ERROR: no RocksDB at $DB_DIR - the load phase did not run." >&2
  echo "       Run: DB_MODE=load bash app_db_bench.sh" >&2
  exit 1
fi
if [[ ! -f "$STAMP" ]]; then
  echo "ERROR: $DB_DIR has no DATASET_STAMP - see DB_MODE=stamp." >&2
  exit 1
fi
# Reads generate keys from key_size and the key range, so a mismatch here
# turns every lookup into a miss without any error from db_bench.
if [[ "$(stamp_val key_size)" != "$DB_KEY_SIZE" ]]; then
  echo "ERROR: DB has key_size=$(stamp_val key_size), run uses $DB_KEY_SIZE" >&2; exit 1
fi
if [[ "$DB_READ_NUM" -gt "$(stamp_val num)" ]]; then
  echo "ERROR: DB_READ_NUM=$DB_READ_NUM exceeds the $(stamp_val num) keys loaded" >&2; exit 1
fi

# --- memory policy ------------------------------------------------------
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
  # NEGATIVE CONTROL, not a file-promotion variant: RocksDB maps its SSTs
  # read-only, and task_numa_work() skips read-only file-backed VMAs
  # (vm_file && (vm_flags & (VM_READ|VM_WRITE)) == VM_READ). The SST pages
  # therefore take NO hint faults; only the heap is scanned.
  IO_FLAGS=(--mmap_read=true --use_direct_reads=false)
else
  IO_FLAGS=(--use_direct_reads=true)
fi

# --- benchmark list ------------------------------------------------------
case "$DB_WARMUP" in
  none)    BENCH_LIST="$DB_BENCHMARK" ;;
  readseq) BENCH_LIST="readseq,$DB_BENCHMARK" ;;
  *) echo "ERROR: DB_WARMUP='$DB_WARMUP' (none|readseq)" >&2; exit 1 ;;
esac
MEASURED="${DB_BENCHMARK##*,}"     # the parser reads the LAST benchmark's line

# A read-only phase must not be disturbed by a leftover background compaction.
EXTRA=()
case "$DB_BENCHMARK" in
  *write*|*fill*|*update*|*merge*|mixgraph) ;;
  *) EXTRA+=(--disable_auto_compactions=1) ;;
esac

RUNLOG="$OUT/db_bench_run.log"

echo "[DBBENCH] benchmarks=$BENCH_LIST threads=$DB_THREADS duration=${DB_DURATION}s"
echo "[DBBENCH] cache=${DB_CACHE_GB}GB read_range=$DB_READ_NUM exp_range=$DB_EXP_RANGE"
echo "[DBBENCH] mempolicy=$DB_MEMPOLICY mmap_read=$DB_MMAP_READ warmup=$DB_WARMUP"
echo "[DBBENCH] dataset: $(tr '\n' ' ' < "$STAMP")"

"${NUMA_PREFIX[@]}" "$DB_BENCH" "${COMMON[@]}" \
    --use_existing_db=1 \
    --benchmarks="$BENCH_LIST" \
    --num="$DB_READ_NUM" \
    --duration="$DB_DURATION" \
    --threads="$DB_THREADS" \
    --cache_size="$CACHE_BYTES" \
    --cache_numshardbits=6 \
    --read_random_exp_range="$DB_EXP_RANGE" \
    "${IO_FLAGS[@]}" \
    "${EXTRA[@]}" \
    --statistics=1 \
    --histogram=1 \
    --report_interval_seconds=1 \
    --report_file="$OUT/db_bench_tput.csv" \
    2>&1 | tee "$RUNLOG"
rc=${PIPESTATUS[0]}

# --- parse -------------------------------------------------------------
# summary line:  readrandom : 8.325 micros/op 120118 ops/sec 600.000 seconds
#                  ... operations; (7200000 of 7200000 found)
# fields:        $1         $2 $3    $4       $5
read -r MICROS OPS <<<"$(awk -v b="$MEASURED" \
    '$1==b && $2==":" {m=$3; o=$5} END{print (m==""?"NA":m), (o==""?"NA":o)}' "$RUNLOG")"

# "( N of M found)": N < M means reads for keys that do not exist
read -r FOUND LOOKED <<<"$(awk -v b="$MEASURED" '$1==b && $2==":" {
      if (match($0, /\( *[0-9]+ of [0-9]+ found\)/)) {
        s = substr($0, RSTART, RLENGTH); gsub(/[()]/, "", s); split(s, a, " ")
        f = a[1]; l = a[3] } }
    END { print (f==""?"NA":f), (l==""?"NA":l) }' "$RUNLOG")"

# --histogram=1: the LAST Percentiles line belongs to the measured benchmark
read -r P50 P99 P999 <<<"$(awk '/^Percentiles:/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "P50:")   a = $(i+1)
        if ($i == "P99:")   b = $(i+1)
        if ($i == "P99.9:") c = $(i+1)
      }
    }
    END { print (a==""?"NA":a), (b==""?"NA":b), (c==""?"NA":c) }' "$RUNLOG")"

# --statistics=1: cumulative over the WHOLE process, warm-up included
HIT=$(awk '$1=="rocksdb.block.cache.hit"  && $2=="COUNT" {print $NF}' "$RUNLOG" | tail -1)
MISS=$(awk '$1=="rocksdb.block.cache.miss" && $2=="COUNT" {print $NF}' "$RUNLOG" | tail -1)
HITPCT=$(awk -v h="${HIT:-}" -v m="${MISS:-}" \
    'BEGIN{ if (h=="" || m=="" || h+m==0) print "NA"; else printf "%.2f", 100*h/(h+m) }')

{
  echo "micros_per_op=$MICROS"
  echo "ops_per_sec=$OPS"
  echo "p50_us=$P50"
  echo "p99_us=$P99"
  echo "p999_us=$P999"
  echo "found=$FOUND"
  echo "lookups=$LOOKED"
  echo "block_cache_hit=${HIT:-NA}"
  echo "block_cache_miss=${MISS:-NA}"
  echo "block_cache_hit_pct=$HITPCT"
  echo "benchmark=$MEASURED"
  echo "warmup=$DB_WARMUP"
  echo "threads=$DB_THREADS"
  echo "cache_gb=$DB_CACHE_GB"
  echo "read_num=$DB_READ_NUM"
  echo "exp_range=$DB_EXP_RANGE"
  echo "mempolicy=$DB_MEMPOLICY"
  echo "mmap_read=$DB_MMAP_READ"
} > "$OUT/dbbench_metrics.txt"

echo "[DBBENCH] ops_per_sec=$OPS p50=${P50}us p99=${P99}us p99.9=${P999}us"
echo "[DBBENCH] found=$FOUND/$LOOKED block_cache_hit=${HITPCT}% (cumulative, incl. warm-up)"
if [[ "$FOUND" =~ ^[0-9]+$ && "$LOOKED" =~ ^[0-9]+$ && "$FOUND" -lt "$LOOKED" ]]; then
  echo "WARNING: $((LOOKED - FOUND)) lookups missed - DB does not hold every key in range"
fi
# The harness greps this line. Units are microseconds per operation: a time,
# lower is better, same orientation as GAP's average trial time.
echo "[DBBENCH] Average Time: ${MICROS}"

exit "$rc"
