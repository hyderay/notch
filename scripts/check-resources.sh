#!/usr/bin/env bash
# Acceptance gate: idle CPU, RSS stability, and `leaks`.
set -euo pipefail

IDLE_CPU_MAX="${IDLE_CPU_MAX:-1.0}"
BUSY_CPU_MAX="${BUSY_CPU_MAX:-5.0}"
IDLE_RSS_GROWTH_KB="${IDLE_RSS_GROWTH_KB:-4096}"
EXERCISE_RSS_GROWTH_KB="${EXERCISE_RSS_GROWTH_KB:-16384}"
SAMPLES="${SAMPLES:-6}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}"

find_pid() {
  pgrep -x Notch | head -1
}

find_nctl() {
  if [[ -x /Applications/Notch.app/Contents/MacOS/notchctl ]]; then
    echo /Applications/Notch.app/Contents/MacOS/notchctl
  elif [[ -x "$(dirname "$0")/../.build/Notch.app/Contents/MacOS/notchctl" ]]; then
    echo "$(cd "$(dirname "$0")/.." && pwd)/.build/Notch.app/Contents/MacOS/notchctl"
  elif command -v notchctl >/dev/null 2>&1; then
    command -v notchctl
  else
    echo ""
  fi
}

sample() {
  local pid="$1" n="$2" label="$3"
  python3 - "$pid" "$n" "$SAMPLE_INTERVAL" "$label" <<'PY'
import re, subprocess, sys
pid, n, interval, label = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]

# A single continuous `top` session reports interval CPU. Repeated `ps %cpu`
# samples retain history, so work done before the idle window polluted the old
# acceptance result for several seconds.
pattern = re.compile(rf"^\s*{re.escape(pid)}\s+([0-9.]+)", re.MULTILINE)
cpus, rss = [], []
for _ in range(n):
    output = subprocess.check_output(
        ["top", "-l", "2", "-s", f"{interval:g}", "-pid", pid, "-stats", "pid,cpu"],
        stderr=subprocess.DEVNULL, text=True,
    )
    values = pattern.findall(output)
    if not values:
        raise SystemExit("top produced no CPU samples")
    cpus.append(float(values[-1]))
    rss.append(int(subprocess.check_output(["ps", "-o", "rss=", "-p", pid], text=True).strip()))
avg_cpu = sum(cpus) / len(cpus)
print(f"{label}\tavg_cpu={avg_cpu:.2f}%\tmin_cpu={min(cpus):.2f}%\tmax_cpu={max(cpus):.2f}%\t"
      f"rss_kb={rss[-1]}\trss_min={min(rss)}\trss_max={max(rss)}\trss_delta={rss[-1]-rss[0]}")
print(f"{avg_cpu:.4f} {rss[0]} {rss[-1]} {max(rss)-min(rss)}")
PY
}

PID="$(find_pid || true)"
if [[ -z "${PID}" ]]; then
  echo "check-resources: Notch is not running" >&2
  exit 1
fi

NCTL="$(find_nctl)"
echo "==> pid ${PID}"
ps -o pid,pcpu,pmem,rss,comm -p "${PID}"

echo
echo "==> idle sample (${SAMPLES}s)"
IDLE_OUT="$(sample "${PID}" "${SAMPLES}" idle)"
echo "${IDLE_OUT}" | head -1
IDLE_NUMS="$(echo "${IDLE_OUT}" | tail -1)"
IDLE_CPU="$(echo "${IDLE_NUMS}" | awk '{print $1}')"
IDLE_RSS0="$(echo "${IDLE_NUMS}" | awk '{print $2}')"
IDLE_RSS1="$(echo "${IDLE_NUMS}" | awk '{print $3}')"
IDLE_SPAN="$(echo "${IDLE_NUMS}" | awk '{print $4}')"

FAIL=0
python3 - "${IDLE_CPU}" "${IDLE_CPU_MAX}" <<'PY' || FAIL=1
import sys
cpu, cap = float(sys.argv[1]), float(sys.argv[2])
sys.exit(0 if cpu <= cap else 1)
PY
if [[ "${FAIL}" -eq 1 ]]; then
  echo "FAIL: idle CPU ${IDLE_CPU}% > ${IDLE_CPU_MAX}%" >&2
fi
if [[ "${IDLE_SPAN}" -gt "${IDLE_RSS_GROWTH_KB}" ]]; then
  echo "FAIL: idle RSS spanned ${IDLE_SPAN} KB (cap ${IDLE_RSS_GROWTH_KB})" >&2
  FAIL=1
fi

if [[ -n "${NCTL}" ]]; then
  echo
  echo "==> exercise one session"
  "${NCTL}" working --agent codex --session resource-check --title notch --detail "check-resources" >/dev/null
  sleep 2
  BUSY_OUT="$(sample "${PID}" 3 busy)"
  echo "${BUSY_OUT}" | head -1
  BUSY_CPU="$(echo "${BUSY_OUT}" | tail -1 | awk '{print $1}')"
  python3 - "${BUSY_CPU}" "${BUSY_CPU_MAX}" <<'PY' || { echo "FAIL: busy CPU ${BUSY_CPU}% > ${BUSY_CPU_MAX}%" >&2; FAIL=1; }
import sys
cpu, cap = float(sys.argv[1]), float(sys.argv[2])
sys.exit(0 if cpu <= cap else 1)
PY
  "${NCTL}" remove --agent codex --session resource-check >/dev/null
  sleep 2
  echo
  echo "==> idle after exercise"
  AFTER_OUT="$(sample "${PID}" "${SAMPLES}" after)"
  echo "${AFTER_OUT}" | head -1
  AFTER_NUMS="$(echo "${AFTER_OUT}" | tail -1)"
  AFTER_CPU="$(echo "${AFTER_NUMS}" | awk '{print $1}')"
  AFTER_RSS="$(echo "${AFTER_NUMS}" | awk '{print $3}')"
  python3 - "${AFTER_CPU}" "${IDLE_CPU_MAX}" <<'PY' || { echo "FAIL: post-exercise idle CPU ${AFTER_CPU}% > ${IDLE_CPU_MAX}%" >&2; FAIL=1; }
import sys
cpu, cap = float(sys.argv[1]), float(sys.argv[2])
sys.exit(0 if cpu <= cap else 1)
PY
  GROWTH=$(( AFTER_RSS - IDLE_RSS0 ))
  if [[ "${GROWTH}" -gt "${EXERCISE_RSS_GROWTH_KB}" ]]; then
    echo "FAIL: RSS grew ${GROWTH} KB after session cycle (cap ${EXERCISE_RSS_GROWTH_KB})" >&2
    FAIL=1
  fi
else
  echo "skip exercise: notchctl not found"
fi

echo
echo "==> leaks"
LEAKS_OUT="$(leaks "${PID}" 2>&1 || true)"
echo "${LEAKS_OUT}" | rg "Process ${PID}:|Physical footprint|not debuggable" || true
# Ad-hoc GUI apps always show NSXPC/AppIntents "leaks" that are system cycles.
# Only fail when a stack frame belongs to our binary, not the report header.
OURS="$(echo "${LEAKS_OUT}" | rg "NotchCore|NotchApp|MacOS/Notch" | rg -v "^Path:|^Process:" || true)"
if [[ -n "${OURS}" ]]; then
  echo "${OURS}"
  echo "FAIL: leaks attributed to Notch" >&2
  FAIL=1
else
  echo "no leaks in Notch code (system XPC cycles ignored)"
fi

echo
if [[ "${FAIL}" -eq 0 ]]; then
  echo "PASS: idle CPU ${IDLE_CPU}%  RSS ${IDLE_RSS1} KB  no leak growth"
  exit 0
fi
echo "FAIL: resource check" >&2
exit 1
