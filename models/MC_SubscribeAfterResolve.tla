------------------------- MODULE MC_SubscribeAfterResolve -------------------------
(***************************************************************************)
(* op:listen scenario: op:listen arrives at the resolver AFTER the promise *)
(* has already been resolved.                                              *)
(*                                                                         *)
(*   Peers     = {vatA, vatB}                                              *)
(*   host      = <<vatA, vatA>>     (LocalPromise p_1 AND LocalTarget T    *)
(*                                   both hosted at vatA)                  *)
(*   HeadPeer  = vatA                (vatA is the only sender; vatB is a   *)
(*                                   pure subscriber)                      *)
(*                                                                         *)
(* EmptyInitialListeners = TRUE so vatA's LocalPromise[1].listeners starts *)
(* empty.  EnableDynamicListen = TRUE so vatB may run the Listen action.   *)
(*                                                                         *)
(* Expected behavior:                                                      *)
(*   - vatA's ResolverResolve installs the resolution (no listeners ->     *)
(*     no op:resolve fires).                                               *)
(*   - vatA's ProcessPending drains the LocalPromise queue into the        *)
(*     LocalTarget sink.                                                   *)
(*   - At any time vatB may Listen -> op:listen on the wire.               *)
(*   - vatA's ReceiveNetwork on op:listen sees resolution set AND target;  *)
(*     adds vatB to listeners, replies with                                *)
(*     op:resolve(1, desc:import-target(2)).  (Target is on the sender    *)
(*     vatA, so from receiver vatB's perspective it is an import.)         *)
(*   - vatB receives op:resolve and installs localResolution.              *)
(*                                                                         *)
(* All invariants hold throughout.                                         *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB"}
HeadPeer == "vatA"
ChainLength == 2
MaxRefId == ChainLength
NumMessages == 1
EmptyInitialListeners == TRUE
EnableDynamicListen == TRUE
EnableHandoff == FALSE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
MaxGifts == 0
RoutingPolicy == "NaivePromiseResolution"
DebugTrace == FALSE

VARIABLES
    channels,
    host,
    vats,
    sent,
    delivered,
    nextRefId,
    lastAction

vars == << channels, host, vats, sent, delivered, nextRefId, lastAction >>

PS == INSTANCE PromiseResolution

Init ==
    /\ PS!Init
    /\ host = <<"vatA", "vatA">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

(* Witness invariant: in every reachable terminal state, vatB ends up in
   vatA's listener set after at least one Listen+notify roundtrip.  This is
   a no-op invariant (always TRUE under non-terminal states) used only as
   trace bookkeeping. *)

TypeOK_MC == PS!TypeOK
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EventualDelivery_MC == PS!EventualDelivery
WireDescriptorContract_MC == PS!WireDescriptorContract
OnlyKnownResolveDescriptors_MC == PS!OnlyKnownResolveDescriptors
============================================================================
