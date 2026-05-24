-------------------- MODULE MC_OpFlushProtocol_4Chain --------------------
(***************************************************************************)
(* 4-chain op:flush protocol.  On promise resolution at host[3], emit     *)
(* op:flush(p_3) upstream to all listeners; each listener flushes its     *)
(* upstream channels then ack.  Only after all flush-acks received +      *)
(* outgoing channel drained + queue drained does op:resolve fire.         *)
(*                                                                         *)
(* Expected: EndToEndRefFIFO_MC holds.                                    *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC", "vatD", "vatE"}
HeadPeer == "vatA"
ChainLength == 4
MaxRefId == ChainLength
NumMessages == 3
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == FALSE
MaxGifts == 0
RoutingPolicy == "OpFlushProtocol"
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
    /\ host = <<"vatB", "vatC", "vatD", "vatE">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

TypeOK_MC == PS!TypeOK

EndToEndRefFIFO_MC == PS!EndToEndRefFIFO

PairingInvariant_MC == PS!PairingInvariant

NoMessageLost_MC == PS!NoMessageLost
EventualDelivery_MC == PS!EventualDelivery

============================================================================
