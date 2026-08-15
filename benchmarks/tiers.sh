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
#   ACTIVATE_ONLY=1 ./tiers_setup.sh   # after a reboot, nothing to install
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

# node-local scratch for the RocksDB dataset - NEVER the NFS home
DB_DIR="${DB_DIR:-/var/tmp/db_bench}"

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
  local lock="$1.buildlock" waited=0
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
  libgflags-dev libsnappy-dev zlib1g-dev libbz2-dev liblz4-dev libzstd-dev

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
  "db dataset dir" "$DB_DIR ($DB_FSTYPE)"

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

After a reboot only the runtime state is lost:
  ACTIVATE_ONLY=1 ./tiers_setup.sh
EOF
