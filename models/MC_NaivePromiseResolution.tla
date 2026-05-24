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
MaxGifts == 0
RoutingPolicy == "NaivePromiseResolution"
DebugTrace == FALSE

VARIABLES
    channels,
    host,
    refs,
    sent,
    delivered,
    gifts,
    nextGiftId,
    nextRefId,
    lastAction

vars == << channels, host, refs, sent, delivered, gifts, nextGiftId, nextRefId, lastAction >>

PS ==
    INSTANCE PromiseResolution WITH
        Peers <- Peers,
        HeadPeer <- HeadPeer,
        ChainLength <- ChainLength,
        MaxRefId <- MaxRefId,
        NumMessages <- NumMessages,
        RoutingPolicy <- RoutingPolicy,
        EmptyInitialListeners <- EmptyInitialListeners,
        EnableDynamicListen <- EnableDynamicListen,
        EnableHandoff <- EnableHandoff,
        MaxGifts <- MaxGifts,
        DebugTrace <- DebugTrace,
        channels <- channels,
        host <- host,
        refs <- refs,
        sent <- sent,
        delivered <- delivered,
        gifts <- gifts,
        nextGiftId <- nextGiftId,
        nextRefId <- nextRefId,
        lastAction <- lastAction

Init ==
    /\ PS!Init
    /\ host[1] = "vatB"
    /\ host[2] = "vatA"

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

TypeOK_MC == PS!TypeOK

EndToEndRefFIFO_MC == PS!EndToEndRefFIFO

PairingInvariant_MC == PS!PairingInvariant

NoMessageLost_MC == PS!NoMessageLost
EventualDelivery_MC == PS!EventualDelivery

============================================================================
