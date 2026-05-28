#!/usr/bin/env bash
# Run every MC model under models/ and every unit-test MC under tests/,
# classify outcomes against expectations, and exit non-zero only when an
# MC's actual outcome disagrees with its expected one.
#
# Each MC is declared below as MC|EXPECTED where EXPECTED is one of:
#   pass      - model checking completes, no invariant violation
#   violation - model checking finds an invariant violation
#
# Debug mode (renders a mermaid trace from the .trace.md file):
#   ./scripts/run-tests.sh --debug MC_NaivePromiseResolution
#   ./scripts/run-tests.sh --debug MC_EJavaFlush_4Chain
#   ./scripts/run-tests.sh --debug MC_OpFlushProtocol_4Chain
# runs models/<name>.tla against models/<name>_Debug.cfg (which sets
# DebugTrace = TRUE and SPECIFICATION = SpecDebug), writes
# .tlc-logs/<name>.debug.log and .tlc-logs/<name>.trace.md (mermaid).
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

CP="$TLA_JAR:$ROOT/lib:$ROOT/spec:$ROOT/models:$ROOT/tests"
WORKERS="${WORKERS:-auto}"
LOG_DIR="$ROOT/.tlc-logs"
mkdir -p "$LOG_DIR"

if [[ "${1:-}" == "--debug" ]]; then
  shift
  base="${1:?usage: $0 --debug MC_ModuleName (e.g. MC_NaivePromiseResolution)}"
  dbg_cfg="${base}_Debug.cfg"
  if [[ ! -f "models/${base}.tla" || ! -f "models/${dbg_cfg}" ]]; then
    echo "ERROR: expected models/${base}.tla and models/${dbg_cfg}" >&2
    exit 2
  fi
  log="$LOG_DIR/${base}.debug.log"
  trace_md="$LOG_DIR/${base}.trace.md"
  trace_svg="$LOG_DIR/${base}.trace.svg"
  echo "Running TLC debug: models/${base}.tla with models/${dbg_cfg}..."
  set +e
  java -cp "$CP" tlc2.TLC \
    -metadir "$LOG_DIR/tlc-meta" \
    -workers "$WORKERS" \
    -config "models/${dbg_cfg}" \
    "models/${base}.tla" \
    >"$log" 2>&1
  code=$?
  set -e
  {
    echo "# TLC debug trace: ${base} (${dbg_cfg})"
    echo
    echo "Exit code: ${code}"
    echo
    echo "## Mermaid (enqueue/dequeue events with TLC step prefixes [sN])"
    echo
    python3 "$ROOT/scripts/trace_to_mermaid.py" \
      --svg "$trace_svg" <"$log"
    echo
    echo "## Lamport space-time (sibling SVG)"
    echo
    echo "See [\`${base}.trace.svg\`](${base}.trace.svg) — diagonals from sender to receiver show transit time across TLC steps."
    echo
    echo "![Lamport](${base}.trace.svg)"
  } >"$trace_md"
  echo "Wrote: $log"
  echo "Wrote: $trace_md"
  [[ -f "$trace_svg" ]] && echo "Wrote: $trace_svg"
  exit 0
fi

# Tests: scenario MCs in models/ (policy-level race scenarios)
SCENARIO_TESTS=(
  "MC_NoPromiseResolution|pass"
  "MC_NoPromiseResolution_3Chain|pass"
  "MC_NaivePromiseResolution|violation"
  "MC_NaivePromiseResolution_PromiseShorten|violation"
  "MC_NaivePromiseResolution_3Chain|violation"
  "MC_ShorteningUnsafe_4Chain|violation"
  "MC_EJavaFlush_3Chain|pass"
  "MC_EJavaFlush_3Chain_PromiseShorten|pass"
  "MC_EJavaFlush_3Chain_PromiseShorten_3Party|pass"
  "MC_EJavaFlush_4Chain|pass"
  "MC_OpFlushProtocol_3Chain_PromiseShorten|pass"
  "MC_OpFlushProtocol_3Chain_PromiseShorten_3Party|pass"
  "MC_EJavaFlush_TribbleFourWay|violation"
  "MC_OpFlushProtocol_TribbleFourWay|pass"
  "MC_OpFlushProtocol_4Chain|pass"
  "MC_SubscribeAfterResolve|pass"
  "MC_TerminalHandoff_Baseline|pass"
  "MC_TerminalHandoff_WithForwarder|violation"
  "MC_ConcurrentHandoffs|pass"
)

# Tests: unit MCs in tests/ (focused, single-mechanism checks)
UNIT_TESTS=(
  "Unit_LocalTarget_Direct|pass"
  "Unit_LocalShorten_Cascade|pass"
  "Unit_RemoteTarget_Forward|pass"
  "Unit_Pipelining_On_Promise|pass"
  "Unit_Listen_Subscribe_Unresolved|pass"
  "Unit_Listen_Subscribe_AfterResolve|pass"
  "Unit_Handoff_DepositWithdraw|pass"
  "Unit_Handoff_Pipeline|pass"
  "Unit_Handoff_Pipeline_BeforeDeposit|pass"
  "Unit_Handoff_RejectWrongRecipient|pass"
  "Unit_EJavaFlush_RefScopedEmbargo|pass"
  "Unit_EJavaFlush_EmbargoFires|violation"
  "Unit_EJavaFlush_HandoffChainProbe|violation"
  "Unit_WireDesc_DescriptorChoice|pass"
  "Unit_PromiseShorten_TwoParty|violation"
  "Unit_PromiseShorten_ThreeParty|violation"
)

FAIL=0
PASS=0
UNEXPECTED=0

run_one() {
  local dir="$1"
  local entry="$2"
  local module="${entry%%|*}"
  local expected="${entry##*|}"
  local log="$LOG_DIR/${module}.log"

  set +e
  java -cp "$CP" tlc2.TLC \
    -metadir "$LOG_DIR/tlc-meta" \
    -workers "$WORKERS" \
    -config "${dir}/${module}.cfg" \
    "${dir}/${module}.tla" \
    >"$log" 2>&1
  local code=$?
  set -e

  local actual
  case $code in
    0)   actual="pass" ;;
    12)  actual="violation" ;;
    *)   actual="error(${code})" ;;
  esac

  local detail=""
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

  local status="OK"
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
}

printf '\n== Scenario MCs (policy-level race scenarios) ==\n'
printf '%-36s  %-10s  %-10s  %s\n' "MODEL" "EXPECTED" "ACTUAL" "DETAIL"
printf '%-36s  %-10s  %-10s  %s\n' "------------------------------------" "----------" "----------" "-------"
for entry in "${SCENARIO_TESTS[@]}"; do
  run_one "models" "$entry"
done

printf '\n== Unit tests (focused, single-mechanism checks) ==\n'
printf '%-36s  %-10s  %-10s  %s\n' "MODEL" "EXPECTED" "ACTUAL" "DETAIL"
printf '%-36s  %-10s  %-10s  %s\n' "------------------------------------" "----------" "----------" "-------"
for entry in "${UNIT_TESTS[@]}"; do
  run_one "tests" "$entry"
done

echo
echo "Summary: $PASS as-expected, $FAIL mismatched, $UNEXPECTED unexpected-error"
echo "Logs:    $LOG_DIR"
echo "Debug:   $0 --debug MC_NaivePromiseResolution"

[[ $FAIL -eq 0 && $UNEXPECTED -eq 0 ]] || exit 1
