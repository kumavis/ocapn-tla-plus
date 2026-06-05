------------------------ MODULE Unit_LocalShorten_Cascade ------------------------
(***************************************************************************)
(* Pinned topology: HeadPeer = vatA hosts BOTH LocalPromises (refIds 1, 2) *)
(* and vatB hosts the terminal LocalTarget at refId 3.                     *)
(*                                                                         *)
(* When LocalPromise[1] resolves to LocalPromise[2] (same peer), the spec  *)
(* must intra-vat-spill its queue into LocalPromise[2].queue (intra-vat    *)
(* promise shortening, no wire traffic), then drain when [2] resolves.    *)
(* See ../notes/path-changes.md section 1.2.a.                             *)
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

PS == INSTANCE NoPromiseResolution

Init ==
    /\ PS!Init
    /\ host = <<"vatA", "vatA", "vatB">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

TypeOK_MC == PS!TypeOK
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EventualDelivery_MC == PS!EventualDelivery
============================================================================
