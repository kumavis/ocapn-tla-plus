----------------- MODULE MC_NaivePromiseResolution_Debug -----------------
(***************************************************************************)
(* Same as MC_NaivePromiseResolution with DebugTrace TRUE for TLC traces   *)
(* and scripts/trace-to-mermaid.sh.                                        *)
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
DebugTrace == TRUE

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

Spec == Init /\ [][Next]_vars

TypeOK_MC == PS!TypeOK

EndToEndRefFIFO_MC == PS!EndToEndRefFIFO

PairingInvariant_MC == PS!PairingInvariant

NoMessageLost_MC == PS!NoMessageLost

============================================================================
