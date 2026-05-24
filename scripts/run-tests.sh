#!/usr/bin/env bash
# Run every MC model under models/, classify outcomes against expectations,
# and exit non-zero only when an MC's actual outcome disagrees with its
# expected one.
#
# Each MC is declared below as MC|EXPECTED where EXPECTED is one of:
#   pass      - model checking completes, no invariant violation
#   violation - model checking finds an invariant violation
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

# Modules live under lib/, protocols/, spec/; MCs under models/.
CP="$TLA_JAR:$ROOT/lib:$ROOT/protocols:$ROOT/spec:$ROOT/models"

# MC test matrix: <module>|<expected outcome>
TESTS=(
  "MC_NaivePromiseResolution|violation"
  "MC_NoPromiseResolution|pass"
)

WORKERS="${WORKERS:-auto}"
LOG_DIR="$ROOT/.tlc-logs"
mkdir -p "$LOG_DIR"

FAIL=0
PASS=0
UNEXPECTED=0

printf '%-32s  %-10s  %-10s  %s\n' "MODEL" "EXPECTED" "ACTUAL" "DETAIL"
printf '%-32s  %-10s  %-10s  %s\n' "--------------------------------" "----------" "----------" "-------"

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

  # TLC exit codes we care about:
  #   0  : model checking completed successfully (no invariant violation)
  #   12 : invariant violated (counterexample produced)
  case $code in
    0)   actual="pass" ;;
    12)  actual="violation" ;;
    *)   actual="error(${code})" ;;
  esac

  detail=""
  if [[ "$actual" == "violation" ]]; then
    detail="$(grep -m1 -oE 'Invariant [A-Za-z_]+ is violated' "$log" || true)"
  elif [[ "$actual" == "pass" ]]; then
    # Final summary line: "<N> states generated, <D> distinct states found, 0 states left on queue."
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

  printf '%-32s  %-10s  %-10s  %s%s\n' \
    "$module" "$expected" "$actual" \
    "$detail" \
    "$( [[ "$status" == "OK" ]] && echo "" || echo "  <-- $status" )"
done

echo
echo "Summary: $PASS as-expected, $FAIL mismatched, $UNEXPECTED unexpected-error"
echo "Logs:    $LOG_DIR"

[[ $FAIL -eq 0 && $UNEXPECTED -eq 0 ]] || exit 1
