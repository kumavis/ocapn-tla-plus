--------------------------- MODULE Common ---------------------------
(***************************************************************************)
(* Common ground for protocol modules.                                      *)
(*                                                                         *)
(* Pulled in transitively by every per-protocol module under protocols/    *)
(* and by spec/Core.tla.  Holds:                                            *)
(*   - the shared CONSTANT block (DebugTrace, the Enable*** feature flags, *)
(*     NumMessages),                                                       *)
(*   - the lastAction VARIABLE used by debug tracing,                      *)
(*   - the Mark / HandoffVarsUnchanged helpers consumed by every protocol  *)
(*     action.                                                             *)
(*                                                                         *)
(* Per-protocol code lives in protocols/<Policy>.tla.  The big actions     *)
(* dispatch via policy-identity Boolean hooks declared as CONSTANTs in     *)
(* spec/Core.tla and substituted per policy; the choice of policy is the   *)
(* choice of which protocols/<Policy>.tla module the MC INSTANCEs.         *)
(***************************************************************************)

EXTENDS Naturals, Sequences, TLC, References, Network, PeerState

CONSTANT
    NumMessages,
    DebugTrace,
    EmptyInitialListeners,
    EnableDynamicListen,
    EnableHandoff,
    EnableHandoffInitiate,
    EnableRepropagate,
    EnableShorten

ASSUME NumMessages \in Nat \ {0}
ASSUME DebugTrace \in BOOLEAN
ASSUME EmptyInitialListeners \in BOOLEAN
ASSUME EnableDynamicListen \in BOOLEAN
ASSUME EnableHandoff \in BOOLEAN
ASSUME EnableHandoffInitiate \in BOOLEAN
ASSUME EnableRepropagate \in BOOLEAN
ASSUME EnableShorten \in BOOLEAN

VARIABLE lastAction

(* Debug bookkeeping: under DebugTrace = TRUE, every action records the
   structured record describing the step it just fired into lastAction.
   This lets scripts/trace_to_mermaid.py turn a TLC counterexample into a
   Lamport space-time diagram even when channel-diff alone is ambiguous
   (e.g. queue / hold tags). *)
Mark(rec) ==
    IF DebugTrace THEN lastAction' = rec ELSE UNCHANGED lastAction

(* Sentinel for actions that don't touch handoff-only state.  Under the
   vats consolidation, gifts and nextGiftId are vat fields, so a handoff-
   free action implicitly leaves them alone whenever it writes to vats
   via an EXCEPT chain that only touches refs.  This operator now only
   covers the truly top-level nextRefId counter. *)
HandoffVarsUnchanged ==
    UNCHANGED nextRefId

============================================================================
