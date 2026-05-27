------------------------ MODULE Unit_Pipelining_On_Promise ------------------------
(***************************************************************************)
(* Pinned topology: HeadPeer = vatA holds a RemotePromise to vatB at      *)
(* refId 1; vatB hosts the LocalPromise; the terminal LocalTarget at      *)
(* refId 2 is back on vatA.  Tests pure pipelining: HeadPeer sends ref-1  *)
(* op:deliver-only into the wire BEFORE vatB resolves.  Messages arrive   *)
(* at vatB's LocalPromise.queue, drain back to vatA on resolution.        *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB"}
HeadPeer == "vatA"
ChainLength == 2
MaxRefId == ChainLength
NumMessages == 2
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == FALSE
EnableHandoffInitiate == FALSE
MaxGifts == 0
RoutingPolicy == "NoPromiseResolution"
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
    /\ host = <<"vatB", "vatA">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

TypeOK_MC == PS!TypeOK
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EventualDelivery_MC == PS!EventualDelivery
============================================================================
