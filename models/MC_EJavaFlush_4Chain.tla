---------------------- MODULE MC_EJavaFlush_4Chain ----------------------
(***************************************************************************)
(* CANONICAL EJavaFlush on a 4-chain.  On op:resolve at host[2], if       *)
(* refs[host[2]][3] is pipelined (i.e., host[2] has in-flight ref-1 sends),*)
(* embargo + remember value; wait for channels[host[2]][host[3]] drain,   *)
(* then install + lift.                                                   *)
(*                                                                         *)
(* Expected: EndToEndRefFIFO_MC VIOLATED.  The local signal is blind to   *)
(* messages already forwarded past host[3] (now on                        *)
(* channels[host[3]][host[4]] or queued at host[3]'s LocalPromise).  The  *)
(* post-embargo direct path channels[host[2]][host[4]] races them.       *)
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
RoutingPolicy == "EJavaFlush"
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
