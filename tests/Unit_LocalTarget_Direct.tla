-------------------------- MODULE Unit_LocalTarget_Direct --------------------------
(***************************************************************************)
(* Pinned topology: HeadPeer = vatA hosts the LocalTarget at refId 2 AND   *)
(* the LocalPromise at refId 1.  PeerSend's Route(vatA, 1) hits a          *)
(* LocalPromise (queue) until ResolverResolve fires, then ProcessPending   *)
(* drains via the LocalTarget at refId 2 (deliver locally).  Tests the     *)
(* end-to-end self-routed pipeline.                                        *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA"}
HeadPeer == "vatA"
ChainLength == 2
MaxRefId == ChainLength
NumMessages == 2
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == FALSE
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
    /\ host = <<"vatA", "vatA">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

TypeOK_MC == PS!TypeOK
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EventualDelivery_MC == PS!EventualDelivery
============================================================================
