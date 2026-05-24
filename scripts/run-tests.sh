#!/usr/bin/env bash
# Run every MC model under models/, classify outcomes against expectations,
# and exit non-zero only when an MC's actual outcome disagrees with its
# expected one.
#
# Each MC is declared below as MC|EXPECTED where EXPECTED is one of:
#   pass      - model checking completes, no invariant violation
#   violation - model checking finds an invariant violation
#
#   ./scripts/run-tests.sh --debug MC_NaivePromiseResolution
# runs models/MC_NaivePromiseResolution_Debug.tla (must exist), writes
# .tlc-logs/<name>.log and .tlc-logs/<name>.trace.md (mermaid).
#
# Defaults TLA jar location to ~/tla/tla2tools.jar; override with TLA_JAR.

set -u

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TLA_JAR="${TLA_JAR:-$HOME/tla/tla2tools.jar}"
if [[ ! -f "$TLA_JAR" ]]; then
  echo "ERROR: tla2tools.jar not found at $TLA_JAR" >&2
  echo "Set TLA_JAR=/path/to/tla2tools.jar and retry." >&2
  exit 2
fi

CP="$TLA_JAR:$ROOT/lib:$ROOT/protocols:$ROOT/spec:$ROOT/models"
WORKERS="${WORKERS:-auto}"
LOG_DIR="$ROOT/.tlc-logs"
mkdir -p "$LOG_DIR"

if [[ "${1:-}" == "--debug" ]]; then
  shift
  base="${1:?usage: $0 --debug MC_ModuleName (e.g. MC_NaivePromiseResolution)}"
  dbg="${base}_Debug"
  if [[ ! -f "models/${dbg}.tla" || ! -f "models/${dbg}.cfg" ]]; then
    echo "ERROR: expected models/${dbg}.tla and models/${dbg}.cfg" >&2
    exit 2
  fi
  log="$LOG_DIR/${base}.debug.log"
  trace_md="$LOG_DIR/${base}.trace.md"
  echo "Running TLC debug module ${dbg}..."
  set +e
  java -cp "$CP" tlc2.TLC \
    -workers "$WORKERS" \
    -config "models/${dbg}.cfg" \
    "models/${dbg}.tla" \
    >"$log" 2>&1
  code=$?
  set -e
  {
    echo "# TLC debug trace: ${dbg}"
    echo
    echo "Exit code: ${code}"
    echo
    echo "## Mermaid (wire traffic from \`channels\` diffs + step notes from \`lastAction\`)"
    echo
    python3 "$ROOT/scripts/trace_to_mermaid.py" <"$log"
  } >"$trace_md"
  echo "Wrote: $log"
  echo "Wrote: $trace_md"
  exit 0
fi

TESTS=(
  "MC_NaivePromiseResolution|violation"
  "MC_NoPromiseResolution|pass"
  "MC_NoPromiseResolution_3Chain|pass"
)

FAIL=0
PASS=0
UNEXPECTED=0

printf '%-36s  %-10s  %-10s  %s\n' "MODEL" "EXPECTED" "ACTUAL" "DETAIL"
printf '%-36s  %-10s  %-10s  %s\n' "------------------------------------" "----------" "----------" "-------"

for entry in "${TESTS[@]}"; do
  module="${entry%%|*}"
  expected="${entry##*|}"
  log="$LOG_DIR/${module}.log"

  set +e
  java -cp "$CP" tlc2.TLC \
    -workers "$WORKERS" \
    -config "models/${module}.cfg" \
    "models/${module}.tla" \
    >"$log" 2>&1
  code=$?
  set -e

  case $code in
    0)   actual="pass" ;;
    12)  actual="violation" ;;
    *)   actual="error(${code})" ;;
  esac

  detail=""
  if [[ "$actual" == "violation" ]]; then
    detail="$(grep -m1 -oE 'Invariant [A-Za-z_]+ is violated' "$log" || true)"
  elif [[ "$actual" == "pass" ]]; then
    detail="$(grep -E '[0-9]+ states generated, [0-9]+ distinct states found, 0 states left on queue' "$log" \
              | tail -n1 \
              | sed -E 's/^([0-9]+) states generated, ([0-9]+) distinct states found.*/\2 distinct \/ \1 generated/' \
              || true)"
  else
    detail="see $log"
  fi

  status="OK"
  if [[ "$actual" != "$expected" ]]; then
    status="MISMATCH"
    if [[ "$actual" == error* ]]; then
      UNEXPECTED=$((UNEXPECTED + 1))
    else
      FAIL=$((FAIL + 1))
    fi
  else
    PASS=$((PASS + 1))
  fi

  printf '%-36s  %-10s  %-10s  %s%s\n' \
    "$module" "$expected" "$actual" \
    "$detail" \
    "$( [[ "$status" == "OK" ]] && echo "" || echo "  <-- $status" )"
done

echo
echo "Summary: $PASS as-expected, $FAIL mismatched, $UNEXPECTED unexpected-error"
echo "Logs:    $LOG_DIR"
echo "Debug:   $0 --debug MC_NaivePromiseResolution"

[[ $FAIL -eq 0 && $UNEXPECTED -eq 0 ]] || exit 1
