#!/usr/bin/env bash
# app_dlrm.sh - DLRM (facebookresearch/dlrm, dlrm_s_pytorch.py) under the
# tiering harness. Called by run-bench-variant.sh through `sudo env ... taskset`.
#
# The whole point of this workload for us is the embedding tables: they are
# allocated once, at init, and then read at random row offsets forever. The
# footprint is therefore exactly
#
#     TABLES * ROWS * DIM * 4 bytes
#
# and the *hot set* is controlled separately, by the sigma of the gaussian
# index distribution. That separation is why DLRM is worth the trouble: GAP
# and YCSB give you a footprint, DLRM gives you a footprint AND a tunable
# hot/cold split, which is the thing the histogram threshold actually reacts to.
#
# Everything below is env-overridable from run-bench-variant.sh. $HOME is /root
# here (we run under sudo), so PYTHON and DLRM_PY must be passed in explicitly.
set -uo pipefail

OUT="${OUT:-.}"
PYTHON="${PYTHON:?app_dlrm.sh needs PYTHON=<venv python> passed in}"
DLRM_PY="${DLRM_PY:?app_dlrm.sh needs DLRM_PY=<path to dlrm_s_pytorch.py> passed in}"
SCRATCH="${DLRM_SCRATCH:-/var/tmp/dlrm}"

TABLES="${DLRM_TABLES:-8}"        # number of embedding tables
ROWS="${DLRM_ROWS:-5000000}"      # rows per table
DIM="${DLRM_DIM:-128}"            # embedding dimension (= last bot-MLP layer)
MBS="${DLRM_MBS:-2048}"           # mini-batch size
BATCHES="${DLRM_BATCHES:-1000}"   # iterations; wall time ~ BATCHES * per-iter
IDX="${DLRM_IDX:-50}"             # sparse indices per lookup, FIXED
SIGMA="${DLRM_SIGMA:-125000}"     # gaussian sigma, in ROW units -> hot-set size
THREADS="${DLRM_THREADS:-8}"      # must match the taskset core count
PRINT_FREQ="${DLRM_PRINT_FREQ:-10}"
SEED="${DLRM_SEED:-123}"

[[ -x "$PYTHON"  ]] || { echo "[DLRM] no python at $PYTHON"   >&2; exit 1; }
[[ -f "$DLRM_PY" ]] || { echo "[DLRM] no dlrm at $DLRM_PY"    >&2; exit 1; }

# "5000000-5000000-..." repeated TABLES times
EMB="$(printf -- "-%s" $(for _ in $(seq "$TABLES"); do echo "$ROWS"; done))"
EMB="${EMB:1}"

MAXROW=$((ROWS - 1))
FOOTPRINT_GB=$(awk -v t="$TABLES" -v r="$ROWS" -v d="$DIM" \
  'BEGIN{printf "%.1f", t*r*d*4/1024/1024/1024}')
# +-3 sigma, clipped at the table edges, is where ~99.7% of the lookups land
HOT_GB=$(awk -v t="$TABLES" -v r="$ROWS" -v s="$SIGMA" -v d="$DIM" \
  'BEGIN{h=6*s; if(h>r)h=r; printf "%.2f", t*h*d*4/1024/1024/1024}')

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
echo "[DLRM] sigma=$SIGMA over $ROWS rows -> hot set ~${HOT_GB} GB (+-3 sigma)"
echo "[DLRM] batches=$BATCHES mbs=$MBS indices/lookup=$IDX threads=$THREADS"
echo "[DLRM] scratch=$SCRATCH python=$PYTHON"

# --num-indices-per-lookup-fixed is argparse type=bool, so ANY non-empty value
# is true - "=False" would also mean true. It is passed only when we want it on.
# Fixed-size lookups matter for more than determinism: the generator draws the
# whole group with ONE ra.normal() call, so a larger IDX amortises the per-sample
# Python overhead over more index lookups.
"$PYTHON" "$DLRM_PY" \
  --arch-sparse-feature-size="$DIM" \
  --arch-embedding-size="$EMB" \
  --arch-mlp-bot="128-128-$DIM" \
  --arch-mlp-top="256-128-1" \
  --arch-interaction-op=dot \
  --data-generation=random \
  --rand-data-dist=gaussian \
  --rand-data-min=0 \
  --rand-data-max="$MAXROW" \
  --rand-data-sigma="$SIGMA" \
  --num-indices-per-lookup="$IDX" \
  --num-indices-per-lookup-fixed=True \
  --mini-batch-size="$MBS" \
  --num-batches="$BATCHES" \
  --nepochs=1 \
  --loss-function=bce \
  --round-targets=True \
  --learning-rate=0.1 \
  --numpy-rand-seed="$SEED" \
  --print-freq="$PRINT_FREQ" \
  --print-time \
  --test-freq=-1 \
  --tensor-board-filename=dlrm_tb \
  2>&1 | tee "$LOG"
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

echo "[DLRM] first-window Time ${FIRST:-NA}   (warm-up: includes first touch of the tables)"
echo "[DLRM] Average Time ${AVG:-NA}"
exit "$RC"
