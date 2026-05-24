------------------------- MODULE MC_ConcurrentHandoffs -------------------------
(***************************************************************************)
(* Phase 3 gift-table sanity probe: two concurrent gifters allocate       *)
(* giftId = 1 each, sending separate gifts to the same target host       *)
(* about the same LocalTarget.  Verifies that (gifter, giftId) keys      *)
(* coexist in the gift table without collision and that each handoff     *)
(* completes independently.                                              *)
(*                                                                         *)
(* Topology (pinned at Init):                                            *)
(*   vatA: refs[1] = RemoteTarget(vatC, 1)                               *)
(*   vatB: refs[1] = RemoteTarget(vatC, 1)                               *)
(*   vatC: refs[1] = LocalTarget                                         *)
(*   vatD: (no refs initially; will receive both handoffs)               *)
(*                                                                         *)
(* Expected: both HandoffInitiate actions run independently; both        *)
(* withdraw-promises end up resolved at vatD; GiftOneShot,                *)
(* GiftHasOneRecipient, PairingInvariant, NoMessageLost all hold.        *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC", "vatD"}
HeadPeer == "vatA"
ChainLength == 2
MaxGifts == 2
MaxRefId == ChainLength + MaxGifts
NumMessages == 1
EmptyInitialListeners == TRUE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
RoutingPolicy == "NoPromiseResolution"
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

vars == << channels, host, refs, sent, delivered,
           gifts, nextGiftId, nextRefId, lastAction >>

PS ==
    INSTANCE PromiseResolution WITH
        Peers <- Peers,
        HeadPeer <- HeadPeer,
        ChainLength <- ChainLength,
        MaxRefId <- MaxRefId,
        MaxGifts <- MaxGifts,
        NumMessages <- NumMessages,
        RoutingPolicy <- RoutingPolicy,
        EmptyInitialListeners <- EmptyInitialListeners,
        EnableDynamicListen <- EnableDynamicListen,
        EnableHandoff <- EnableHandoff,
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
    /\ host = <<"vatC", "vatC">>
    /\ refs = [p \in Peers |->
                 [r \in (1..MaxRefId) |->
                    CASE p = "vatA" /\ r = 1 ->
                            PS!MkRemoteTarget("vatC", 1)
                      [] p = "vatB" /\ r = 1 ->
                            PS!MkRemoteTarget("vatC", 1)
                      [] p = "vatC" /\ r = 1 ->
                            PS!MkLocalTarget
                      [] OTHER -> PS!EntryNone]]
    /\ channels = [p \in Peers |-> [q \in Peers |-> << >>]]
    /\ sent = 0
    /\ delivered = << >>
    /\ gifts = [p \in Peers |-> [q \in Peers |-> [i \in 1..MaxGifts |->
                  PS!NoGift]]]
    /\ nextGiftId = [p \in Peers |-> 1]
    /\ nextRefId = ChainLength + 1
    /\ lastAction = [name |-> "init"]

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

TypeOK_MC == PS!TypeOK
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EventualDelivery_MC == PS!EventualDelivery
GiftOneShot_MC == PS!GiftOneShot
GiftHasOneRecipient_MC == PS!GiftHasOneRecipient
============================================================================
