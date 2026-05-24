------------------- MODULE MC_ShorteningUnsafe_4Chain -------------------
(***************************************************************************)
(* ChainLength = 4 (three promises + terminal).  Race actor: host[2]      *)
(* (the only peer that ever installs a localResolution under terminal-only *)
(* propagation in this iteration).                                         *)
(*                                                                         *)
(* host[3] resolves p_3 -> RemoteTarget(host[4], 4); op:resolve fires to  *)
(* host[2] which immediately installs (ShorteningUnsafe = no embargo).    *)
(* Subsequent pipelined sends from host[2] take the shortened path via    *)
(* channels[host[2]][host[4]] while in-flight pre-resolve forwards still  *)
(* travel via channels[host[2]][host[3]] -> channels[host[3]][host[4]].   *)
(*                                                                         *)
(* Expected: EndToEndRefFIFO_MC violated.                                  *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC", "vatD", "vatE"}
HeadPeer == "vatA"
ChainLength == 4
MaxRefId == ChainLength
NumMessages == 5
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == FALSE
MaxGifts == 0
RoutingPolicy == "ShorteningUnsafe"
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
