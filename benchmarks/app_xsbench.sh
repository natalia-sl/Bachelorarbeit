#!/usr/bin/env bash
# app_xsbench.sh - XSBench (openmp-threading) for the tiering harness.
#
# Env in (all supplied by run-bench.sh's explicit env block; sudo does not
# forward the environment, so nothing here may rely on $HOME):
#   OUT           app-private log directory
#   XS_BIN        path to the openmp-threading binary
#   XS_G          gridpoints per nuclide  (footprint MB ~= XS_G/2 at -G unionized)
#   XS_PARTICLES  particle histories      (runtime only; memory is set by XS_G)
#   XS_GRID       unionized | hash | nuclide
#   XS_THREADS    OpenMP threads; keep equal to the taskset core count
#
# Only the openmp-threading port is usable for tiering work. The cuda/hip/
# opencl/sycl and openmp-offload ports copy the grids into device memory, where
# task_numa_work() never scans them and every migration counter stays flat.
set -uo pipefail

XS_BIN="${XS_BIN:?XS_BIN not set}"
OUT="${OUT:?OUT not set}"
XS_G="${XS_G:-100000}"
XS_PARTICLES="${XS_PARTICLES:-20000000}"
XS_GRID="${XS_GRID:-unionized}"
XS_THREADS="${XS_THREADS:-8}"

log="$OUT/xsbench.log"

# -t is explicit rather than left to omp_get_num_procs(): under taskset the
# default would silently become a function of the affinity mask.
"$XS_BIN" -t "$XS_THREADS" -m history -s large \
          -g "$XS_G" -G "$XS_GRID" -p "$XS_PARTICLES" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}

# 'Runtime:' is the SIMULATION phase only - XSBench starts its timer after grid
# init, so this excludes the serial index-grid build. The harness's vmstat
# deltas do not.
runtime=$(awk '/^Runtime:/{print $2; exit}' "$log")
fom=$(awk '/^Lookups\/s:/{gsub(/,/,"",$2); print $2; exit}' "$log")
# XSBench prints fancy_int() values with thousands separators ("49,971"), so
# strip commas as well as spaces - otherwise the harness's [0-9]* capture
# stops at the comma and xsbench.csv records 49 instead of 49971.
mem=$(awk -F: '/Est. Memory Usage/{gsub(/[ ,]/,"",$2); print $2; exit}' "$log")

echo "[XSBENCH] grid=$XS_GRID g=$XS_G particles=$XS_PARTICLES est_mem_MB=${mem:-NA} lookups_per_s=${fom:-NA}"
# Runtime goes in the 'Average Time' column so it stays lower-is-better like
# every other app. lookups/s is higher-is-better and lives only in xsbench.csv.
echo "[XSBENCH] Average Time: ${runtime:-NA}"

# XSBench's main() returns is_invalid_result from print_results(), which is 1
# unless the verification hash equals one of four constants hardcoded in io.c.
# Those are only reachable at the reference parameters (-s large -g 11303
# -p 500000, history), so ANY other -g/-p exits 1 on a perfectly good run.
#
# The only return in main() is that one, after RESULTS is printed; allocation
# failures abort() earlier (rc 134) and never print Runtime. So if Runtime was
# parsed, the simulation completed and rc carries nothing but the checksum.
# At the reference parameters the checksum IS meaningful, so it still fails.
XS_REF_G=11303; XS_REF_P=500000
if [[ -n "$runtime" ]]; then
  if [[ "$rc" -eq 1 && ( "$XS_G" != "$XS_REF_G" || "$XS_PARTICLES" != "$XS_REF_P" ) ]]; then
    echo "[XSBENCH] exit 1 is the checksum flag at non-reference -g/-p - run completed"
    rc=0
  fi
else
  echo "[XSBENCH] no Runtime line - simulation did not complete (rc=$rc)" >&2
  [[ "$rc" -eq 0 ]] && rc=1
fi
exit "$rc"
