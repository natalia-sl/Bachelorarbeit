#!/usr/bin/env bash
# app_dlrm.sh - DLRM (facebookresearch/dlrm, dlrm_s_pytorch.py) under the
# tiering harness. Called by run-bench.sh through `sudo env ... taskset`.
#
# The whole point of this workload for us is the embedding tables: they are
# allocated once, at init, and then read at random row offsets forever. The
# footprint is therefore exactly
#
#     TABLES * ROWS * DIM * 4 bytes
#
# The *hot set* is a separate knob, but ONLY under DIST=gaussian: the sigma of
# the index distribution decides how much of the footprint is actually touched.
# Under DIST=uniform (the default, matching the published proxy config) every
# row is equally warm and there is no hot set at all - that configuration is a
# flat control, not a promotion test. Which of the two you are running is
# printed below and recorded in setup.log.
#
# Note on granularity: one row is DIM*4 bytes. At DIM=512 that is 2048 B, so
# exactly two rows share a 4 KB page and page-level locality is two rows wide
# regardless of how the indices are drawn.
#
# Everything below is env-overridable from run-bench.sh. $HOME is /root here
# (we run under sudo), so PYTHON and DLRM_PY must be passed in explicitly.
set -uo pipefail

# The harness hands us a RELATIVE OUT ("results/<node>/..."), which every other
# app script gets away with because none of them changes directory. This one
# does (see SCRATCH below), so resolve it while the CWD is still the harness's.
OUT="${OUT:-.}"
if [[ -d "$OUT" ]]; then
  OUT="$(cd "$OUT" && pwd)"
else
  echo "[DLRM] OUT directory '$OUT' does not exist (cwd: $PWD)" >&2; exit 1
fi
PYTHON="${PYTHON:?app_dlrm.sh needs PYTHON=<venv python> passed in}"
DLRM_PY="${DLRM_PY:?app_dlrm.sh needs DLRM_PY=<path to dlrm_s_pytorch.py> passed in}"
SCRATCH="${DLRM_SCRATCH:-/var/tmp/dlrm}"

TABLES="${DLRM_TABLES:-8}"          # number of embedding tables
ROWS="${DLRM_ROWS:-1000000}"        # rows per table
DIM="${DLRM_DIM:-512}"              # embedding dim (= last bot-MLP layer)
MBS="${DLRM_MBS:-2048}"             # --mini-batch-size
TEST_MBS="${DLRM_TEST_MBS:-16384}"  # --test-mini-batch-size
TEST_WORKERS="${DLRM_TEST_WORKERS:-0}"
BATCHES="${DLRM_BATCHES:-400}"      # iterations; wall time ~ BATCHES * per-iter
IDX="${DLRM_IDX:-200}"              # sparse indices per lookup
IDX_FIXED="${DLRM_IDX_FIXED:-0}"    # 1 -> --num-indices-per-lookup-fixed
MLP_BOT="${DLRM_MLP_BOT:-2048-2048-512}"
MLP_TOP="${DLRM_MLP_TOP:-1024-1024-1024-1}"
INTERACTION="${DLRM_INTERACTION:-dot}"
DATAGEN="${DLRM_DATAGEN:-random}"
DIST="${DLRM_DIST:-uniform}"        # uniform | gaussian
SIGMA="${DLRM_SIGMA:-125000}"       # ROW units; ONLY used when DIST=gaussian
THREADS="${DLRM_THREADS:-8}"        # must match the taskset core count
PRINT_FREQ="${DLRM_PRINT_FREQ:-10}"
SEED="${DLRM_SEED:-727}"

[[ -x "$PYTHON"  ]] || { echo "[DLRM] no python at $PYTHON"   >&2; exit 1; }
[[ -f "$DLRM_PY" ]] || { echo "[DLRM] no dlrm at $DLRM_PY"    >&2; exit 1; }

# --arch-interaction-op=dot concatenates the bottom-MLP output with the
# embedding vectors, so the last bot layer has to equal DIM. dlrm asserts on
# this only after every table is built, which is minutes in.
if [[ "${MLP_BOT##*-}" != "$DIM" ]]; then
  echo "[DLRM] MLP_BOT ends in ${MLP_BOT##*-} but DIM is $DIM - interaction-op=$INTERACTION needs them equal" >&2
  exit 1
fi
case "$DIST" in
  uniform|gaussian) : ;;
  *) echo "[DLRM] DLRM_DIST='$DIST' - expected uniform or gaussian" >&2; exit 1 ;;
esac

# "1000000-1000000-..." repeated TABLES times
EMB="$(printf -- "-%s" $(for _ in $(seq "$TABLES"); do echo "$ROWS"; done))"
EMB="${EMB:1}"

MAXROW=$((ROWS - 1))
FOOTPRINT_GB=$(awk -v t="$TABLES" -v r="$ROWS" -v d="$DIM" \
  'BEGIN{printf "%.1f", t*r*d*4/1024/1024/1024}')

# Tensorboard event files are written to "./<name>", i.e. relative to the CWD.
# Left in the NFS home that is writeback traffic on the shared export during a
# timed run, so we run from node-local scratch instead.
mkdir -p "$SCRATCH" || { echo "[DLRM] cannot create $SCRATCH" >&2; exit 1; }
cd "$SCRATCH"      || exit 1
rm -rf ./dlrm_tb

# torch otherwise sizes its thread pool from the machine's core count, not from
# the cpuset taskset gave us, and oversubscribes the 8 fast-node cores.
export OMP_NUM_THREADS="$THREADS"
export MKL_NUM_THREADS="$THREADS"

LOG="$OUT/dlrm.log"

echo "[DLRM] tables=$TABLES rows=$ROWS dim=$DIM -> embedding footprint ${FOOTPRINT_GB} GB"
echo "[DLRM] mlp_bot=$MLP_BOT mlp_top=$MLP_TOP interaction=$INTERACTION datagen=$DATAGEN seed=$SEED"
echo "[DLRM] batches=$BATCHES mbs=$MBS indices/lookup=$IDX threads=$THREADS"

# --- argument assembly ---------------------------------------------------
# Built as an array so the distribution and fixed-index flags can be omitted
# entirely rather than passed with a neutral-looking value.
ARGS=(
  --arch-sparse-feature-size="$DIM"
  --arch-embedding-size="$EMB"
  --arch-mlp-bot="$MLP_BOT"
  --arch-mlp-top="$MLP_TOP"
  --arch-interaction-op="$INTERACTION"
  --data-generation="$DATAGEN"
  --num-indices-per-lookup="$IDX"
  --mini-batch-size="$MBS"
  --test-mini-batch-size="$TEST_MBS"
  --test-num-workers="$TEST_WORKERS"
  --num-batches="$BATCHES"
  --nepochs=1
  --loss-function=bce
  --round-targets=True
  --learning-rate=0.1
  --numpy-rand-seed="$SEED"
  --print-freq="$PRINT_FREQ"
  --print-time
  --test-freq=-1
  --tensor-board-filename=dlrm_tb
)

# --data-generation=random routes through generate_dist_input_batch(), which
# honours --rand-data-dist. Under "uniform" the index is drawn straight from
# [0, size-1] and rand-data-min/max/sigma are never read, so passing them would
# only suggest they do something.
if [[ "$DIST" == "gaussian" ]]; then
  HOT_GB=$(awk -v t="$TABLES" -v r="$ROWS" -v s="$SIGMA" -v d="$DIM" \
    'BEGIN{h=6*s; if(h>r)h=r; printf "%.2f", t*h*d*4/1024/1024/1024}')
  HOT_PCT=$(awk -v s="$SIGMA" -v r="$ROWS" 'BEGIN{p=600*s/r; if(p>100)p=100; printf "%.0f", p}')
  echo "[DLRM] dist=gaussian sigma=$SIGMA over $ROWS rows -> hot set ~${HOT_GB} GB (+-3 sigma, ${HOT_PCT}% of rows)"
  if [[ "$HOT_PCT" -gt 40 ]]; then
    echo "[DLRM] WARNING: +-3 sigma covers ${HOT_PCT}% of every table - that is not a hot set."
    echo "[DLRM]          SIGMA has to scale with ROWS; try $((ROWS / 40)) for ~15%."
  fi
  ARGS+=(
    --rand-data-dist=gaussian
    --rand-data-min=0
    --rand-data-max="$MAXROW"
    --rand-data-sigma="$SIGMA"
  )
else
  echo "[DLRM] dist=uniform -> index draws are FLAT across all $ROWS rows per table."
  echo "[DLRM]                There is no hot set; SIGMA is unused. Control config."
fi

# --num-indices-per-lookup-fixed is argparse type=bool, so ANY non-empty value
# is true - "=False" would also mean true. It is passed only when we want it on.
# Off, the generator draws the group size from [1,IDX], so the MEAN lookup is
# ~IDX/2. That halves the embedding traffic without changing the per-sample
# Python cost in generate_dist_input_batch(), which runs inline in the training
# loop at --num-workers=0.
if [[ "$IDX_FIXED" == "1" ]]; then
  ARGS+=(--num-indices-per-lookup-fixed=True)
  echo "[DLRM] indices/lookup fixed at $IDX"
else
  echo "[DLRM] indices/lookup drawn from [1,$IDX] -> mean ~$((IDX / 2)) (set DLRM_IDX_FIXED=1 to pin)"
fi
echo "[DLRM] scratch=$SCRATCH python=$PYTHON"

"$PYTHON" "$DLRM_PY" "${ARGS[@]}" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}

# DLRM resets its accumulator at every print, so each "N.NN ms/it" is the mean
# over the last PRINT_FREQ iterations, not a running mean. The first such line
# also covers lazy allocation and the first touch of every embedding page, i.e.
# precisely the phase we do NOT want in a steady-state number, so it is dropped.
AVG=$(awk '
  match($0, /[0-9.]+ ms\/it/) {
    v = substr($0, RSTART, RLENGTH); sub(/ ms\/it/, "", v)
    n++; if (n > 1) { s += v; c++ }
  }
  END { if (c > 0) printf "%.6f", (s/c)/1000.0; else print "NA" }
' "$LOG")

FIRST=$(awk 'match($0,/[0-9.]+ ms\/it/){v=substr($0,RSTART,RLENGTH);sub(/ ms\/it/,"",v);printf "%.6f",v/1000.0;exit}' "$LOG")

echo "[DLRM] config dist=$DIST idx_fixed=$IDX_FIXED footprint_gb=$FOOTPRINT_GB rows=$ROWS dim=$DIM"
echo "[DLRM] first-window Time ${FIRST:-NA}   (warm-up: includes first touch of the tables)"
echo "[DLRM] Average Time ${AVG:-NA}"
exit "$RC"
