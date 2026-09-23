#!/usr/bin/env bash
# tiers_setup.sh - bring a node up for the two-tier NUMA experiments.
#
# Safe to re-run. Two independent halves:
#
#   ACTIVATE  runtime state that does NOT survive a reboot: tier module,
#             numa_balancing=2, demotion, THP, swapoff. Run after every boot.
#   INSTALL   software that DOES survive: gapbs, redis, YCSB, rocksdb/db_bench,
#             perf. Skipped automatically when already present.
#
# Usage:
#   ./tiers_setup.sh              # activate + install whatever is missing
#   ACTIVATE_ONLY=1 ./tiers_setup.sh   # after a reboot; installs nothing except
#                                      # missing dlrm python deps (see PART A)
#   FORCE_BUILD=1 ./tiers_setup.sh     # rebuild even if binaries exist
#
# NOTE ON THE SHARED HOME: $HOME is an NFS export mounted on every node, so
# gapbs / YCSB / rocksdb are built ONCE and every node sees the result. Two
# nodes running this script at the same time would otherwise build into the
# same directory concurrently and corrupt it, so builds take a lock.
# Anything node-local (the db_bench dataset, the tier module, sysctls) is
# still done per node.
set -uo pipefail

export DEBIAN_FRONTEND=noninteractive

ACTIVATE_ONLY="${ACTIVATE_ONLY:-0}"
FORCE_BUILD="${FORCE_BUILD:-0}"

KDIR="$HOME/Natalia_SS2026/Linux-6-16-Tiers"
KSRC="$KDIR/linux-6.16.1"
GAPBS_DIR="$HOME/gapbs"
ROCKSDB_DIR="$HOME/rocksdb"
YCSB_DIR="$HOME/ycsb"
YCSB_VERSION="${YCSB_VERSION:-0.17.0}"
DLRM_DIR="$HOME/dlrm"
DLRM_VENV="$HOME/dlrm-venv"
XSBENCH_DIR="$HOME/XSBench"

# node-local scratch for the RocksDB dataset - NEVER the NFS home
DB_DIR="${DB_DIR:-/var/tmp/db_bench}"
# node-local scratch for DLRM's tensorboard event files - NEVER the NFS home
DLRM_SCRATCH="${DLRM_SCRATCH:-/var/tmp/dlrm}"

WARNINGS=()
step() { echo; echo "===== $* ====="; }
warn() { echo "WARNING: $*" >&2; WARNINGS+=("$*"); }

# Atomic-enough mutual exclusion for builds into the shared home. mkdir is the
# lock: it either creates the directory or it does not, with no race in between.
# Locks are released by the EXIT trap, NOT when the function returns - the
# caller still has to do the build.
HELD_LOCKS=()
release_locks() {
  local l
  for l in ${HELD_LOCKS+"${HELD_LOCKS[@]}"}; do rmdir "$l" 2>/dev/null; done
}
trap release_locks EXIT INT TERM

with_build_lock() {
  local lock="$1.buildlock" waited=0 l
  # Re-entrant: a lock THIS run already holds is not another node. Without this,
  # the dlrm dep top-up in PART A would take the venv lock and the venv block in
  # PART B would then wait an hour on itself under FORCE_BUILD=1.
  for l in ${HELD_LOCKS+"${HELD_LOCKS[@]}"}; do
    [[ "$l" == "$lock" ]] && return 0
  done
  while ! mkdir "$lock" 2>/dev/null; do
    if [[ $waited -eq 0 ]]; then
      echo "another node is building $(basename "$1") - waiting"
      echo "(if no other node is running, the lock is stale: rm -rf $lock)"
    fi
    sleep 10; waited=$((waited + 10))
    if [[ $waited -ge 3600 ]]; then
      warn "gave up waiting for $lock after 1h - build skipped"
      return 1
    fi
  done
  HELD_LOCKS+=("$lock")
  return 0
}

# DLRM python deps as "<import name>:<pip name>".
#
# required - imported at module scope by dlrm_s_pytorch.py or by something it
#            imports, so a missing one kills the run before argument parsing.
# optional - imported inside try/except: dlrm prints "Unable to import ..." and
#            carries on. onnx is only used by --save-onnx and mlperf_logging only
#            by --mlperf-logging; app_dlrm.sh passes neither, so installing these
#            silences two warning lines and changes nothing about the run.
DLRM_PYDEPS_REQUIRED="tqdm:tqdm sklearn.metrics:scikit-learn torch.utils.tensorboard:tensorboard"
DLRM_PYDEPS_OPTIONAL="mlperf_logging:mlperf-logging onnx:onnx"
DLRM_PYDEPS_CHECKED=0

# prints the pip names of every listed module that fails to import
dlrm_missing_pydeps() {
  "$DLRM_VENV/bin/python" - "$@" 2>/dev/null <<'PY'
import importlib, sys
missing = []
for spec in sys.argv[1:]:
    mod, pkg = spec.split(":")
    try:
        importlib.import_module(mod)
    except Exception:          # not just ImportError: a numpy ABI clash raises others
        missing.append(pkg)
print(" ".join(missing))
PY
}

# Check-then-install, so it is cheap when nothing is missing and safe to call on
# every run. The PART B venv block skips wholesale once the venv exists, which
# means a package added to its pip line never reaches an existing venv - this
# is what does.
ensure_dlrm_pydeps() {
  [[ "$DLRM_PYDEPS_CHECKED" == "1" ]] && return 0
  if [[ ! -x "$DLRM_VENV/bin/python" ]]; then
    echo "no venv at $DLRM_VENV yet - the PART B install creates it"
    return 0
  fi
  DLRM_PYDEPS_CHECKED=1
  # A broken torch would make torch.utils.tensorboard fail too and get
  # misreported as "tensorboard missing". It needs a rebuild, not a top-up.
  if ! "$DLRM_VENV/bin/python" -c 'import torch' 2>/dev/null; then
    warn "torch does not import in $DLRM_VENV - rebuild with FORCE_BUILD=1"
    return 1
  fi
  local req opt npv
  req=$(dlrm_missing_pydeps $DLRM_PYDEPS_REQUIRED)
  opt=$(dlrm_missing_pydeps $DLRM_PYDEPS_OPTIONAL)
  if [[ -z "$req$opt" ]]; then
    echo "all dlrm python deps importable"
    return 0
  fi
  [[ -n "$req" ]] && echo "missing (required): $req"
  [[ -n "$opt" ]] && echo "missing (optional): $opt"
  with_build_lock "$DLRM_VENV" || return 1

  # "numpy<2" is repeated in BOTH commands on purpose. onnx needs ml_dtypes, and
  # the current ml_dtypes requires numpy>=2; without the pin in the same command
  # pip satisfies onnx by upgrading numpy, and torch then fails at import.
  # Two separate installs so an optional package that has no wheel for this
  # python cannot take the required ones down with it.
  if [[ -n "$req" ]]; then
    "$DLRM_VENV/bin/pip" install --no-cache-dir "numpy<2" $req \
      || warn "required dlrm dep install failed: $req"
  fi
  if [[ -n "$opt" ]]; then
    "$DLRM_VENV/bin/pip" install --no-cache-dir "numpy<2" $opt \
      || echo "note: optional dep install failed ($opt) - dlrm runs without them"
  fi

  # Re-check the required set AFTER both installs: onnx also moves protobuf up a
  # major version, and tensorboard is the package that would notice.
  req=$(dlrm_missing_pydeps $DLRM_PYDEPS_REQUIRED)
  if [[ -n "$req" ]]; then
    warn "not importable after install: $req"
  else
    echo "required dlrm deps importable"
  fi
  opt=$(dlrm_missing_pydeps $DLRM_PYDEPS_OPTIONAL)
  [[ -n "$opt" ]] && echo "optional still missing: $opt (harmless)"
  npv=$("$DLRM_VENV/bin/python" -c 'import numpy; print(numpy.__version__)' 2>/dev/null)
  echo "numpy ${npv:-?}"
  if [[ -n "$npv" && "${npv%%.*}" -ge 2 ]]; then
    warn "numpy $npv in $DLRM_VENV - torch needs numpy<2 here: $DLRM_VENV/bin/pip install 'numpy<2'"
  fi
}

########################################################################
# PART A - ACTIVATION (every boot)
########################################################################

step "boot parameters"
echo "kernel  = $(uname -r)"
echo "cmdline = $(cat /proc/cmdline)"
if ! grep -q 'memmap=' /proc/cmdline; then
  warn "no memmap= in the kernel cmdline - the slow tier is probably NOT emulated."
  echo "         Expected something like: memmap=88G!8G"
  echo "         Fix GRUB_CMDLINE_LINUX in /etc/default/grub, then:"
  echo "           sudo update-grub && sudo reboot"
fi
for p in numa_balancing=2; do
  grep -q "$p" /proc/cmdline || echo "note: '$p' not on the cmdline (set below at runtime instead)"
done

step "tier module"
if [[ -d "$KDIR" ]]; then
  ( cd "$KDIR" && make ) || warn "tier module build failed in $KDIR"
  if lsmod | grep -q '^tierinit'; then
    echo "tierinit already loaded"
  else
    sudo insmod "$KDIR/tierinit.ko" && echo "tierinit loaded" \
      || warn "insmod tierinit.ko failed"
  fi
  ls /sys/devices/virtual/memory_tiering/ 2>/dev/null || warn "no memory_tiering sysfs directory"
else
  warn "$KDIR not found - kernel tree missing on this node"
fi

step "numa balancing + demotion"
sudo sh -c 'echo 2 > /proc/sys/kernel/numa_balancing'
sudo sh -c 'echo 1 > /sys/kernel/mm/numa/demotion_enabled'
echo -n "numa_balancing   = "; cat /proc/sys/kernel/numa_balancing
echo -n "demotion_enabled = "; cat /sys/kernel/mm/numa/demotion_enabled
echo -n "promote_rate_limit_MBps = "; cat /proc/sys/kernel/numa_balancing_promote_rate_limit_MBps 2>/dev/null || echo "(absent)"

step "transparent huge pages (cond 1 default: never)"
sudo sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled"
sudo sh -c "echo never > /sys/kernel/mm/transparent_hugepage/defrag"
echo -n "enabled = "; cat /sys/kernel/mm/transparent_hugepage/enabled
echo -n "defrag  = "; cat /sys/kernel/mm/transparent_hugepage/defrag

step "swap off"
# Swap competes with demotion for cold pages and makes migration counters
# uninterpretable, so it is off for every tiering run.
sudo swapoff -a
swapon --show || true
echo "(nothing listed above = correct)"

step "numa layout"
numactl -H 2>/dev/null || warn "numactl not installed yet (installed below)"
NNODES=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)
if [[ "$NNODES" -lt 2 ]]; then
  warn "only $NNODES NUMA node(s) visible - there is no slow tier to migrate to."
  echo "         Every promotion/demotion counter will stay at zero."
else
  n0=$(awk '/MemTotal/{printf "%.1f", $4/1024/1024}' /sys/devices/system/node/node0/meminfo 2>/dev/null)
  n1=$(awk '/MemTotal/{printf "%.1f", $4/1024/1024}' /sys/devices/system/node/node1/meminfo 2>/dev/null)
  echo "node0 (fast) = ${n0} GB    node1 (slow) = ${n1} GB"
  if [[ -n "${n1:-}" ]] && awk -v a="${n1:-0}" -v b="${n0:-0}" 'BEGIN{exit !(a<=b)}'; then
    warn "node1 is not larger than node0 - check the memmap= layout"
  fi
fi

step "debugfs / nbp knobs"
mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null
if sudo test -r /sys/kernel/debug/nbp_hist; then
  echo "nbp_hist present (histogram kernel)"
  sudo head -3 /sys/kernel/debug/nbp_hist
else
  echo "nbp_hist absent - fine for the stock/th0 kernels"
fi

# Not runtime state, but it lives here so ACTIVATE_ONLY=1 covers it too: the
# venv is on the shared home, so a missing package is a missing package on
# every node, and finding out in rep 1 costs a whole preflight cycle.
step "dlrm python deps"
ensure_dlrm_pydeps

if [[ "$ACTIVATE_ONLY" == "1" ]]; then
  step "ACTIVATE_ONLY=1 - skipping installs"
  [[ ${#WARNINGS[@]} -eq 0 ]] && echo "no warnings" || printf 'WARNING: %s\n' "${WARNINGS[@]}"
  exit 0
fi

########################################################################
# PART B - INSTALL (once, mostly into the shared home)
########################################################################

step "distro packages"
sudo apt update
sudo apt install -y \
  build-essential pkg-config flex bison python3 numactl git wget curl unzip \
  libelf-dev libdw-dev libtraceevent-dev \
  redis-server redis-tools openjdk-11-jre-headless \
  libgflags-dev libsnappy-dev zlib1g-dev libbz2-dev liblz4-dev libzstd-dev \
  python3-venv python3-pip

step "gapbs"
if [[ -x "$GAPBS_DIR/bfs" && "$FORCE_BUILD" != "1" ]]; then
  echo "gapbs already built at $GAPBS_DIR"
else
  if with_build_lock "$GAPBS_DIR"; then
    [[ -d "$GAPBS_DIR/.git" ]] || git clone https://github.com/sbeamer/gapbs.git "$GAPBS_DIR"
    ( cd "$GAPBS_DIR" && make -j"$(nproc)" ) || warn "gapbs build failed"
  fi
fi
for b in bfs cc pr bc converter; do
  [[ -x "$GAPBS_DIR/$b" ]] || warn "missing gapbs binary: $b"
done

step "redis"
# The harness starts and stops its own redis-server so it controls the port,
# the persistence settings and the NUMA policy. A distro service listening on
# 6379 in the background would silently absorb the YCSB traffic instead.
sudo systemctl disable --now redis-server 2>/dev/null || true
sudo systemctl mask redis-server 2>/dev/null || true
echo -n "redis-server: "; redis-server --version 2>/dev/null || warn "redis-server not installed"
# Redis forks for RDB snapshots; without overcommit the fork fails on a large
# dataset. Harmless for the other benchmarks.
sudo sysctl -w vm.overcommit_memory=1 >/dev/null
echo "vm.overcommit_memory = $(cat /proc/sys/vm/overcommit_memory)"

step "YCSB $YCSB_VERSION (redis binding)"
if [[ -x "$YCSB_DIR/bin/ycsb.sh" && "$FORCE_BUILD" != "1" ]]; then
  echo "YCSB already present at $YCSB_DIR"
else
  if with_build_lock "$YCSB_DIR"; then
    TARBALL="ycsb-redis-binding-${YCSB_VERSION}.tar.gz"
    URL="https://github.com/brianfrankcooper/YCSB/releases/download/${YCSB_VERSION}/${TARBALL}"
    tmp="$(mktemp -d)"
    if wget -q --show-progress -O "$tmp/$TARBALL" "$URL"; then
      tar -xzf "$tmp/$TARBALL" -C "$tmp"
      rm -rf "$YCSB_DIR"
      mv "$tmp/ycsb-redis-binding-${YCSB_VERSION}" "$YCSB_DIR"
      echo "YCSB unpacked to $YCSB_DIR"
    else
      warn "YCSB download failed: $URL"
    fi
    rm -rf "$tmp"
  fi
fi
[[ -x "$YCSB_DIR/bin/ycsb.sh" ]] || warn "no $YCSB_DIR/bin/ycsb.sh"
# Older app scripts hard-code ./YCSB. Keep both names valid rather than
# forcing every caller to change.
[[ -d "$YCSB_DIR" && ! -e "$HOME/YCSB" ]] && ln -s "$YCSB_DIR" "$HOME/YCSB"
echo -n "java: "; java -version 2>&1 | head -1 || warn "no JRE"
JAVA_MAJOR="$(java -version 2>&1 | awk -F'"' '/version/{split($2,a,"."); print (a[1]=="1" ? a[2] : a[1]); exit}')"
if [[ -n "${JAVA_MAJOR:-}" && "$JAVA_MAJOR" -ge 17 ]]; then
  warn "java $JAVA_MAJOR installed; YCSB $YCSB_VERSION targets java 8/11."
  echo "         If the YCSB load dies in a NoClassDefFoundError or reflective"
  echo "         access trace: sudo apt install -y openjdk-11-jre-headless"
fi

step "rocksdb / db_bench"
if [[ -x "$ROCKSDB_DIR/db_bench" && "$FORCE_BUILD" != "1" ]]; then
  echo "db_bench already built at $ROCKSDB_DIR/db_bench"
else
  if with_build_lock "$ROCKSDB_DIR"; then
    [[ -d "$ROCKSDB_DIR/.git" ]] || git clone --depth 1 https://github.com/facebook/rocksdb.git "$ROCKSDB_DIR"
    echo "building db_bench - this takes a while"
    # DEBUG_LEVEL=0 is not optional: the default build ships assertions and
    # runs several times slower, which distorts the hint-fault rate.
    ( cd "$ROCKSDB_DIR" && make -j"$(nproc)" db_bench DEBUG_LEVEL=0 ) \
      || warn "db_bench build failed"
  fi
fi
[[ -x "$ROCKSDB_DIR/db_bench" ]] || warn "no $ROCKSDB_DIR/db_bench"

step "db_bench dataset directory (node-local)"
sudo mkdir -p "$DB_DIR"
sudo chown "$(id -un):$(id -gn)" "$DB_DIR"
DB_FSTYPE="$(stat -f -c %T "$DB_DIR" 2>/dev/null || echo unknown)"
DB_FREE_GB="$(df -BG --output=avail "$DB_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')"
echo "$DB_DIR: fstype=$DB_FSTYPE free=${DB_FREE_GB:-?} GB"
case "$DB_FSTYPE" in
  nfs*)
    warn "$DB_DIR is on NFS. O_DIRECT is unreliable there and a ~41 GB dataset"
    echo "         on the shared export takes every node down with ENOSPC."
    echo "         Set DB_DIR to local storage." ;;
  tmpfs|ramfs)
    warn "$DB_DIR is on $DB_FSTYPE - that IS memory, so there is no I/O path"
    echo "         and the tiering result would be meaningless." ;;
esac
if [[ -n "${DB_FREE_GB:-}" && "$DB_FREE_GB" -lt 60 ]]; then
  warn "only ${DB_FREE_GB} GB free at $DB_DIR - the default 40M x 1 KB dataset"
  echo "         is ~41 GB and compaction needs headroom on top."
fi
if [[ -f "$DB_DIR/CURRENT" ]]; then
  echo "existing RocksDB dataset found - the harness will reuse it"
else
  echo "no dataset yet - run-bench-variant.sh loads it once on first 'db' run"
fi

step "xsbench"
# Only the openmp-threading port is usable here. The cuda/hip/opencl/sycl and
# openmp-offload ports copy the grids into device memory, where
# task_numa_work() never scans them and every migration counter stays flat.
if [[ -x "$XSBENCH_DIR/openmp-threading/XSBench" && "$FORCE_BUILD" != "1" ]]; then
  echo "XSBench already built at $XSBENCH_DIR/openmp-threading"
else
  if with_build_lock "$XSBENCH_DIR"; then
    [[ -d "$XSBENCH_DIR/.git" ]] || git clone https://github.com/ANL-CESAR/XSBench.git "$XSBENCH_DIR"
    ( cd "$XSBENCH_DIR/openmp-threading" && make -j"$(nproc)" ) || warn "XSBench build failed"
  fi
fi
if [[ -x "$XSBENCH_DIR/openmp-threading/XSBench" ]]; then
  # Footprint is set by -g at -s large (355 nuclides): MB ~= g/2.
  # 96.2% of it is the unionized index grid, hit thinly and uniformly; the hot
  # set is the nuclide grid + energy array, ~3.8%, allocated and first-touched
  # FIRST - so under plain first-touch it lands on node 0 and promotion has
  # nothing to do. Ballast node 0 if you want to measure promotion.
  n0mb=$(awk '/MemTotal/{print int($4/1024)}' /sys/devices/system/node/node0/meminfo 2>/dev/null)
  echo "sizing: -g <gridpoints>, footprint MB ~= g/2   (node0 = ${n0mb:-?} MB)"
  echo "        -g 46000 -> ~22.4 GiB total, ~915 MB hot"
  echo "        -G hash drops the index grid -> flat access distribution (control)"
  echo "note:   'INVALID CHECKSUM' is expected off default -g/-p, not a build fault"
else
  warn "no $XSBENCH_DIR/openmp-threading/XSBench"
fi

step "dlrm + pytorch venv"
# The venv lives in the shared home alongside gapbs/ycsb, so it is built once
# and every node imports the same torch. It is ~2 GB, hence the build lock.
if [[ -x "$DLRM_VENV/bin/python" && -f "$DLRM_DIR/dlrm_s_pytorch.py" && "$FORCE_BUILD" != "1" ]]; then
  echo "dlrm + venv already present ($DLRM_DIR, $DLRM_VENV)"
else
  if with_build_lock "$DLRM_VENV"; then
    [[ -d "$DLRM_DIR/.git" ]] || git clone --depth 1 https://github.com/facebookresearch/dlrm.git "$DLRM_DIR"
    [[ -x "$DLRM_VENV/bin/python" ]] || python3 -m venv "$DLRM_VENV"
    # --index-url cpu is not optional: the default PyPI torch wheel drags in
    # several GB of nvidia-* CUDA packages that this box will never use.
    # numpy is pinned below 2 because DLRM predates it and torch only handles
    # numpy 2 from 2.3 onward - the combination fails at import, not at run.
    # --no-cache-dir keeps pip from leaving a multi-GB cache on the NFS home.
    "$DLRM_VENV/bin/pip" install --no-cache-dir --upgrade pip setuptools wheel \
      || warn "pip bootstrap failed"
    "$DLRM_VENV/bin/pip" install --no-cache-dir \
        --index-url https://download.pytorch.org/whl/cpu torch \
      || warn "torch (cpu) install failed"
    # torch.utils.tensorboard is imported unconditionally by dlrm_s_pytorch.py,
    # so the tensorboard package is a hard dependency even though we never look
    # at the event files.
    # tqdm is not optional despite looking like it: dlrm_data_pytorch.py imports
    # data_loader_terabyte at module scope, and that file imports tqdm at its
    # own module scope, so it is pulled in even on a pure --data-generation=random
    # run that never touches the terabyte loader.
    "$DLRM_VENV/bin/pip" install --no-cache-dir "numpy<2" scikit-learn tensorboard tqdm \
      || warn "dlrm python deps install failed"
  fi
fi
# No-op if PART A already checked. Does the work on a fresh node, where the
# venv did not exist yet when PART A ran.
ensure_dlrm_pydeps
# DLRM's last commit predates torch 2.x. torch.autograd.profiler.profile() no
# longer accepts use_cuda=, so the unconditional `with` around the whole training
# loop raises TypeError before the first iteration. The block is entered with
# enabled=args.enable_profiling, which the harness never sets, so the profiler is
# a no-op and the kwarg can simply go. grep-guarded, so re-running is harmless,
# and it stays visible in `git -C $DLRM_DIR diff` for the writeup.
if [[ -f "$DLRM_DIR/dlrm_s_pytorch.py" ]]; then
  if grep -q 'use_cuda=use_gpu, record_shapes=True' "$DLRM_DIR/dlrm_s_pytorch.py"; then
    sed -i 's/args\.enable_profiling, use_cuda=use_gpu, record_shapes=True/args.enable_profiling, record_shapes=True/' \
      "$DLRM_DIR/dlrm_s_pytorch.py" \
      && echo "patched dlrm_s_pytorch.py: dropped the removed use_cuda= profiler kwarg" \
      || warn "failed to patch the use_cuda= profiler kwarg"
  else
    echo "dlrm_s_pytorch.py already patched (no use_cuda= profiler kwarg)"
  fi
fi

if [[ -x "$DLRM_VENV/bin/python" && -d "$DLRM_DIR" ]]; then
  "$DLRM_VENV/bin/python" -c \
    'import torch, numpy, sklearn; print("torch", torch.__version__, "numpy", numpy.__version__)' \
    || warn "torch/numpy/sklearn not importable in $DLRM_VENV"

  # A two-second run of the tiny default model, end to end. An import check only
  # proves the modules load; this exercises the argument plumbing, the training
  # loop and the profiler context that just broke, AND confirms the "ms/it" line
  # that app_dlrm.sh parses still looks the way it does. Any remaining torch-2
  # API break surfaces here instead of twenty minutes into rep 1.
  mkdir -p "$DLRM_SCRATCH" 2>/dev/null
  SMOKE="$(cd "$DLRM_SCRATCH" 2>/dev/null && "$DLRM_VENV/bin/python" \
             "$DLRM_DIR/dlrm_s_pytorch.py" --mini-batch-size=2 --data-size=6 \
             --print-time --print-freq=1 --tensor-board-filename=smoke_tb 2>&1)"
  if grep -q 'ms/it' <<<"$SMOKE"; then
    echo "dlrm smoke run ok:"
    grep 'ms/it' <<<"$SMOKE" | tail -1
  else
    warn "dlrm smoke run failed - see below"
    tail -15 <<<"$SMOKE"
  fi
  rm -rf "$DLRM_SCRATCH/smoke_tb"
else
  warn "no $DLRM_VENV/bin/python"
fi
[[ -f "$DLRM_DIR/dlrm_s_pytorch.py" ]] || warn "no $DLRM_DIR/dlrm_s_pytorch.py"

step "dlrm scratch directory (node-local)"
sudo mkdir -p "$DLRM_SCRATCH"
sudo chown "$(id -un):$(id -gn)" "$DLRM_SCRATCH"
DLRM_FSTYPE="$(stat -f -c %T "$DLRM_SCRATCH" 2>/dev/null || echo unknown)"
echo "$DLRM_SCRATCH: fstype=$DLRM_FSTYPE"
case "$DLRM_FSTYPE" in
  nfs*) warn "$DLRM_SCRATCH is on NFS - tensorboard writeback will land on the shared export mid-run" ;;
esac

step "perf"
# The distro perf often refuses to run against a self-built kernel. Build the
# one from the kernel tree instead; NO_JEVENTS/NO_LIBTRACEEVENT drop the
# optional deps that fail on this box.
if sudo perf stat -a -e cycles -- true >/dev/null 2>&1; then
  echo "perf works: $(perf --version 2>/dev/null)"
else
  warn "system perf does not work against $(uname -r) - building from the kernel tree"
  if [[ -d "$KSRC/tools/perf" ]]; then
    if with_build_lock "$KSRC/tools/perf"; then
      ( cd "$KSRC/tools/perf" && make NO_JEVENTS=1 NO_LIBTRACEEVENT=1 -j"$(nproc)" ) \
        && sudo install -m755 "$KSRC/tools/perf/perf" /usr/local/bin/perf \
        && echo "installed $(perf --version)" \
        || warn "perf build failed - run-bench-variant.sh needs perf stat"
    fi
  else
    warn "$KSRC/tools/perf not found"
  fi
fi

########################################################################
step "summary"
printf '%-28s %s\n' \
  "kernel"        "$(uname -r)" \
  "numa_balancing" "$(cat /proc/sys/kernel/numa_balancing)" \
  "demotion"      "$(cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || echo NA)" \
  "THP"           "$(cat /sys/kernel/mm/transparent_hugepage/enabled)" \
  "numa nodes"    "$NNODES" \
  "gapbs"         "$([[ -x $GAPBS_DIR/bfs ]] && echo ok || echo MISSING)" \
  "redis-server"  "$(command -v redis-server >/dev/null && echo ok || echo MISSING)" \
  "ycsb"          "$([[ -x $YCSB_DIR/bin/ycsb.sh ]] && echo ok || echo MISSING)" \
  "db_bench"      "$([[ -x $ROCKSDB_DIR/db_bench ]] && echo ok || echo MISSING)" \
  "db dataset dir" "$DB_DIR ($DB_FSTYPE)" \
  "xsbench"       "$([[ -x $XSBENCH_DIR/openmp-threading/XSBench ]] && echo ok || echo MISSING)" \
  "dlrm"          "$([[ -f $DLRM_DIR/dlrm_s_pytorch.py ]] && echo ok || echo MISSING)" \
  "dlrm venv"     "$([[ -x $DLRM_VENV/bin/python ]] && echo ok || echo MISSING)" \
  "dlrm profiler patch" "$(grep -q 'use_cuda=use_gpu' "$DLRM_DIR/dlrm_s_pytorch.py" 2>/dev/null && echo "NOT APPLIED" || echo applied)"

if [[ ${#WARNINGS[@]} -eq 0 ]]; then
  echo; echo "Done - no warnings."
else
  echo; echo "Done with ${#WARNINGS[@]} warning(s):"
  printf '  - %s\n' "${WARNINGS[@]}"
fi

cat <<EOF

Next:
  DB_BENCH=$ROCKSDB_DIR/db_bench DB_DIR=$DB_DIR \\
    ./run-bench-variant.sh db hist 1 5
  ./run-bench-variant.sh redis hist 1 5
  ./run-bench-variant.sh pr hist 1 5
  ./run-bench-variant.sh dlrm hist 1 5
  XS_BIN=$XSBENCH_DIR/openmp-threading/XSBench \\
  ./run-bench-variant.sh xsbench hist 1 5

After a reboot only the runtime state is lost:
  ACTIVATE_ONLY=1 ./tiers_setup.sh
EOF
