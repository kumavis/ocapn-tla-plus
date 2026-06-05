--------------- MODULE MC_NaivePromiseResolution_2Party_PromiseShorten ---------------
(***************************************************************************)
(* Inter-vat promise-to-promise shortening under NaivePromiseResolution.   *)
(* Models §1.2.b's two-party form (Phase A): the resolver vatB emits an    *)
(* op:resolve(targetRefId, desc:export-promise(refId)) to the listener,    *)
(* and the listener immediately installs localResolution -- no flush.      *)
(*                                                                         *)
(* Topology (ChainLength = 3, two peers):                                  *)
(*   HeadPeer = vatA                                                       *)
(*   host[1]  = vatB   (resolver of p_1; listener {vatA})                  *)
(*   host[2]  = vatA   (resolver of p_2; listener {vatB}; also new        *)
(*                       promise's host for vatA's view of ref 1)         *)
(*   host[3]  = vatA   (LocalTarget T)                                     *)
(*                                                                         *)
(* Race surface (this is what makes the new wire emission unsafe under    *)
(* Naive):                                                                *)
(*                                                                         *)
(*   1. vatA pipelines seq=1 via Route(vatA, 1) -> wire(vatB, 1).          *)
(*   2. vatB receives seq=1, queues on vats[vatB].refs[1].queue.           *)
(*   3. vatB's ResolverResolve fires (the new firePromiseShorten branch): *)
(*        - sets vats[vatB].refs[1].resolution = ResRef(vatA, 2)           *)
(*        - sends op:resolve(1, desc:export-promise(2)) to vatA.           *)
(*   4. vatA receives the op:resolve; installs                             *)
(*      vats[vatA].refs[1].localResolution = ResRef(vatA, 2).              *)
(*   5. vatA pipelines seq=2 via Route(vatA, 1) -- now cascades through   *)
(*      localResolution to Route(vatA, 2) -- the LocalPromise queue on    *)
(*      vatA.  seq=2 enters vats[vatA].refs[2].queue immediately.         *)
(*   6. vatB's ProcessPending drains seq=1 from refs[1].queue to          *)
(*      wire(vatA, 2).  vatA receives seq=1 and queues it (or routes      *)
(*      onward) at refs[2].                                               *)
(*                                                                         *)
(* Steps 5 and 6 race: if seq=2 enters refs[2].queue before seq=1 does,   *)
(* the delivered sequence at the terminal observes seq=2 < seq=1 for    *)
(* ref 1 originator -- EndToEndRefFIFO violation.  Expected outcome:     *)
(* VIOLATION.                                                             *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB"}
HeadPeer == "vatA"
ChainLength == 3
MaxRefId == ChainLength
NumMessages == 2
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == FALSE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
EnableShorten == FALSE
MaxGifts == 0

CONSTANT DebugTrace  \* set in .cfg

VARIABLES
    channels,
    host,
    vats,
    sent,
    delivered,
    nextRefId,
    lastAction

vars == << channels, host, vats, sent, delivered, nextRefId, lastAction >>

PS == INSTANCE NaivePromiseResolution

Init ==
    /\ PS!Init
    /\ host = <<"vatB", "vatA", "vatA">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

\* SpecDebug: same Init/Next without fairness; for _Debug.cfg use.
SpecDebug == Init /\ [][Next]_vars

TypeOK_MC == PS!TypeOK
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
EventualDelivery_MC == PS!EventualDelivery
WireDescriptorContract_MC == PS!WireDescriptorContract
OnlyKnownResolveDescriptors_MC == PS!OnlyKnownResolveDescriptors

============================================================================
