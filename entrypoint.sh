#!/bin/sh
# Entrypoint for the Quai/KawPow SaladCloud AMD image.
# Do NOT export LD_LIBRARY_PATH or PYTHONPATH here - Salad injects them.
#
# Tries each miner in $MINERS in order. A miner "works" once it logs an
# accepted share; if it exits, or produces no accepted share within
# $NO_SHARE_TIMEOUT seconds, it is killed and the next miner is tried.
# (WildRig under ROCm OpenCL runs forever without hashing - hence the
# share-based check rather than an exit-code check.)

set -u

# This script is PID 1. Without a trap, PID 1 ignores SIGTERM and a Salad
# stop/reallocation waits out the grace period and SIGKILLs everything.
cleanup() {
  echo "=== SIGTERM received - stopping miner ==="
  pkill -TERM -f '/opt/' 2>/dev/null
  sleep 2
  pkill -KILL -f '/opt/' 2>/dev/null
  exit 0
}
trap cleanup TERM INT

# Interruptible sleep: a trap can't run while a foreground `sleep` is active,
# so background it and wait (wait IS interruptible).
isleep() { sleep "$1" & wait $! 2>/dev/null; }

if [ "${WALLET:-REPLACE_WITH_YOUR_WALLET}" = "REPLACE_WITH_YOUR_WALLET" ]; then
  echo "ERROR: set the WALLET environment variable in your SaladCloud container group." >&2
  exit 1
fi

WORKER_NAME="${SALAD_MACHINE_ID:-${WORKER:-salad01}}"
# Salad machine ids are long UUIDs; pools usually cap worker names, so trim.
WORKER_NAME="$(echo "$WORKER_NAME" | tr -cd 'A-Za-z0-9_-' | cut -c1-24)"
USER_ARG="$WALLET.$WORKER_NAME"

NO_SHARE_TIMEOUT="${NO_SHARE_TIMEOUT:-300}"
LOG=/tmp/miner.log

echo "=== GPU readiness check (rocminfo) ==="
echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-<unset>}"
GFX=""
if command -v rocminfo >/dev/null 2>&1; then
  ROCMINFO="$(rocminfo 2>&1)"
  echo "$ROCMINFO" | grep -E 'Name:|Marketing Name|gfx|HSA_STATUS' | head -20
  GFX="$(echo "$ROCMINFO" | grep -oE 'gfx[0-9a-f]+' | head -1)"
else
  echo "rocminfo not found in image (unexpected)"
fi

# Miner order. TeamRedMiner (last release 2024) has no RDNA4 support, so on
# gfx12xx (RX 9070 / 9060) go straight to SRBMiner.
if [ -z "${MINERS:-}" ]; then
  case "$GFX" in
    gfx12*) MINERS="srb wildrig" ;;
    *)      MINERS="trm srb wildrig" ;;
  esac
fi
echo "=== GPU arch: ${GFX:-unknown}  miner order: $MINERS ==="

echo "=== OpenCL platforms (clinfo) ==="
clinfo -l 2>&1 | head -20 || true

# Pool region auto-select. Salad nodes are spread worldwide and Quai jobs go
# stale fast, so a far-away pool costs 10%+ in "Job expired" rejects. If the
# pool is HeroMiners, time a TCP connect to each region and use the fastest.
# Disable with POOL_AUTO=0 or by setting a non-HeroMiners POOL.
if [ "${POOL_AUTO:-1}" = "1" ] && echo "$POOL" | grep -q 'quai\.herominers\.com'; then
  scheme="$(echo "$POOL" | sed -nE 's#^([a-z+]+://).*#\1#p')"
  port="$(echo "$POOL" | sed -nE 's#.*:([0-9]+)$#\1#p')"
  port="${port:-1185}"
  POOL_REGIONS="${POOL_REGIONS:-ca us de fi fr hk sg kr au br tr ru}"
  echo "=== Probing HeroMiners regions on port $port ==="
  best=""; best_ms=999999
  for r in $POOL_REGIONS; do
    h="$r.quai.herominers.com"
    t="$(curl -s -o /dev/null --max-time 3 -w '%{time_connect}' "telnet://$h:$port" 2>/dev/null </dev/null)"
    ms="$(echo "${t:-0}" | awk '{ printf "%d", $1 * 1000 }')"
    if [ "$ms" -gt 0 ]; then
      echo "  $r: ${ms} ms"
      if [ "$ms" -lt "$best_ms" ]; then best="$r"; best_ms="$ms"; fi
    else
      echo "  $r: unreachable"
    fi
  done
  if [ -n "$best" ]; then
    POOL="${scheme:-stratum+tcp://}$best.quai.herominers.com:$port"
    echo "=== Using nearest region: $best (${best_ms} ms) -> $POOL ==="
  else
    echo "=== No region reachable by probe; keeping $POOL ==="
  fi
fi

# Print the miner command for a given name. Pool URL for SRBMiner must not
# carry the stratum+tcp:// scheme.
POOL_HOSTPORT="$(echo "$POOL" | sed -E 's#^[a-z+]+://##')"

miner_cmd() {
  case "$1" in
    trm)
      echo /opt/trm/teamredminer -a "$ALGO" -o "$POOL" -u "$USER_ARG" -p x \
        --hardware=gpu --watchdog_disabled --disable_colors --log_interval=30 \
        ${TRM_EXTRA_ARGS:-}
      ;;
    srb)
      echo /opt/srb/SRBMiner-MULTI --algorithm "$ALGO" --pool "$POOL_HOSTPORT" \
        --wallet "$USER_ARG" --password x --disable-cpu \
        ${SRB_EXTRA_ARGS:-}
      ;;
    wildrig)
      echo /opt/wildrig/wildrig-multi --algo "$ALGO" --url "$POOL" --user "$USER_ARG" \
        --pass x --opencl-platforms amd --no-adl --no-igcl --no-sysfs \
        --progpow-kernel "${PROGPOW_KERNEL:-1}" ${WILDRIG_EXTRA_ARGS:-}
      ;;
    *)
      echo "echo unknown miner '$1'; false"
      ;;
  esac
}

# Accepted-share detector. Each miner words it differently, and miners also
# print periodic stats containing "accepted" with a zero count, which must
# NOT count:
#   TRM      "share accepted. (GPU0) (a:5 r:0)"      -> counts
#   SRBMiner "GPU0[t0] share accepted [ 70ms]"       -> counts
#   WildRig  "Accepted: -" (stats table)             -> must not count
#   krig     "shares: 0 accepted 0 stale 0 rejected" -> must not count
# Rules: "N accepted" needs N>0, "Accepted: N" needs N>0, and anything else
# must be share wording - never bare "accept" (that matched "accepting jobs"
# / "accepted connection" and could lock MINERS onto a miner that isn't hashing).
has_accepted() {
  grep -iE 'accept' "$LOG" 2>/dev/null \
    | grep -viE 'no accepted|not accepted|accepting|accepted connection' \
    | awk '
      { l = tolower($0) }
      l ~ /[0-9]+ accepted/    { if (l ~ /(^|[^0-9.])[1-9][0-9]* accepted/) found = 1; next }
      l ~ /accepted:? *[-0-9]/ { if (l ~ /accepted:? *[1-9]/) found = 1; next }
      l ~ /shares? accepted|accepted shares?|accepted \(|accepted \[|accepted!/ { found = 1 }
      END { exit found ? 0 : 1 }'
}

run_miner() {
  name="$1"
  : > "$LOG"
  echo "=== [$name] starting: $(miner_cmd "$name") ==="
  cd "/opt/$name" 2>/dev/null || cd /opt/wildrig
  # tee -a so the periodic truncation below actually frees space (with plain
  # tee the writer keeps its old offset and the file just goes sparse).
  sh -c "$(miner_cmd "$name")" 2>&1 | tee -a "$LOG" &
  pipeline_pid=$!
  start=$(date +%s)
  confirmed=0
  while :; do
    isleep 10
    alive=1
    kill -0 "$pipeline_pid" 2>/dev/null || alive=0
    # Check the log BEFORE judging an exit, so a miner that got shares and
    # then lost the pool is restarted rather than replaced by the next one.
    if [ "$confirmed" -eq 0 ] && has_accepted; then
      confirmed=1
      echo "=== [$name] ACCEPTED SHARE - this miner works on this node ==="
    fi
    if [ "$alive" -eq 0 ]; then
      wait "$pipeline_pid" 2>/dev/null
      if [ "$confirmed" -eq 1 ]; then
        echo "=== [$name] exited after running successfully ==="
        return 0
      fi
      echo "=== [$name] exited before any accepted share ==="
      return 1
    fi
    if [ "$confirmed" -eq 1 ]; then
      # Miner output keeps flowing to Salad's log via tee's stdout; the file
      # copy is only needed for the share check, so keep it from growing
      # (~25 MB/day otherwise, which fills minimum storage in a few weeks).
      : > "$LOG"
      continue
    fi
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$NO_SHARE_TIMEOUT" ]; then
      echo "=== [$name] no accepted share after ${elapsed}s - killing and trying next miner ==="
      pkill -TERM -f "/opt/$name/" 2>/dev/null
      sleep 3
      pkill -KILL -f "/opt/$name/" 2>/dev/null
      wait "$pipeline_pid" 2>/dev/null
      return 1
    fi
  done
}

while :; do
  for m in $MINERS; do
    if run_miner "$m"; then
      # It worked then died (pool drop / node hiccup): stick with this miner.
      MINERS="$m"
      break
    fi
  done
  echo "=== restarting in 15s ==="
  isleep 15
done
