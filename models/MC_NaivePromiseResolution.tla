--------------------- MODULE MC_NaivePromiseResolution ---------------------
(***************************************************************************)
(* Canonical naive race: 1-promise chain with terminal at the head peer.   *)
(*                                                                         *)
(*   HeadPeer = vatA                                                       *)
(*   host[1]  = vatB   (resolver of p_1)                                   *)
(*   host[2]  = vatA   (LocalTarget T at head)                             *)
(*                                                                         *)
(* host[1] resolves p_1 -> RemoteTarget(vatA, 2) (a Target!); op:resolve   *)
(* fires to HeadPeer who installs localResolution.  Pipelined ref-1 sends  *)
(* in flight on channels[vatA][vatB] (and back forwards on                 *)
(* channels[vatB][vatA]) race the direct local delivery.                   *)
(*                                                                         *)
(* Expected: EndToEndRefFIFO_MC violated.                                  *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB"}
HeadPeer == "vatA"
ChainLength == 2
MaxRefId == ChainLength
NumMessages == 3
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == FALSE
EnableHandoffInitiate == FALSE
MaxGifts == 0
RoutingPolicy == "NaivePromiseResolution"

CONSTANT DebugTrace  \* set in .cfg: FALSE for normal run, TRUE for _Debug.cfg

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
    /\ host[1] = "vatB"
    /\ host[2] = "vatA"

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

\* SpecDebug: same Init/Next but no fairness; used by _Debug.cfg to render
\* a single counterexample trace without TLC trying to satisfy liveness.
SpecDebug == Init /\ [][Next]_vars

TypeOK_MC == PS!TypeOK
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
EventualDelivery_MC == PS!EventualDelivery

============================================================================
