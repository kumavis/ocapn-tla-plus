------------------------ MODULE Unit_Handoff_Pipeline ------------------------
(***************************************************************************)
(* Unit: pipelining op:deliver-only into a 3PHO withdraw-promise that is  *)
(* not yet resolved.                                                       *)
(*                                                                         *)
(* Pre-state (HandoffInitiate + deposit-gift + handoff-give have already  *)
(* been processed; only withdraw-gift remains in flight):                 *)
(*   vatA = gifter (inert in this trace)                                  *)
(*   vatB = recipient + HeadPeer; refs[vatB][1] = RemotePromise(vatC, 3) *)
(*     (the recipient ref points directly at the withdraw-promise pw=3)  *)
(*   vatC = target host;                                                  *)
(*     refs[vatC][2] = LocalTarget                                        *)
(*     refs[vatC][3] = LocalPromise (pre-minted on op:deposit-gift,       *)
(*                                    unresolved, listeners = {vatB})     *)
(*   gifts[vatC][vatA][1] = (recipient = vatB, targetLocalRefId = 2)     *)
(*   channels[vatB][vatC] = << op:withdraw-gift(1, vatA, 3) >>           *)
(*                                                                         *)
(* nextGiftId[vatA] = MaxGifts + 1 disables further HandoffInitiate, so   *)
(* the only interleaving is: PeerSend(s) interleaved with vatC processing *)
(* the withdraw and the queued sends.                                      *)
(*                                                                         *)
(* PeerSend(vatB, ref=1) routes via Route(vatB, 1) =                      *)
(*   [wire, vatC, 3].  vatC receives op:deliver-only(refId=3):           *)
(*     - if LocalPromise(3) unresolved -> enqueue in queue.               *)
(*     - if resolved (after withdraw) -> forward to LocalTarget.          *)
(* ProcessPending drains the queue after withdraw resolves the promise.  *)
(*                                                                         *)
(* Invariants: NoMessageLost (every send eventually delivered) and        *)
(* EndToEndRefFIFO (in-order at the sink).                                 *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC"}
HeadPeer == "vatB"
ChainLength == 2
MaxGifts == 1
MaxRefId == ChainLength + MaxGifts
NumMessages == 2
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
    /\ host = <<"vatA", "vatC">>
    /\ refs = [p \in Peers |->
                 [r \in (1..MaxRefId) |->
                    CASE p = "vatA" /\ r = 2 ->
                            PS!MkRemoteTarget("vatC", 2)
                      [] p = "vatB" /\ r = 1 ->
                            PS!MkRemotePromise("vatC", 3, PS!ResNone,
                                FALSE, "idle", << >>, TRUE)
                      [] p = "vatC" /\ r = 2 ->
                            PS!MkLocalTarget
                      [] p = "vatC" /\ r = 3 ->
                            PS!MkLocalPromise(<< >>, {"vatB"},
                                PS!ResNone, {}, FALSE)
                      [] OTHER -> PS!EntryNone]]
    /\ channels =
         [p \in Peers |->
            [q \in Peers |->
               IF p = "vatB" /\ q = "vatC"
               THEN << PS!OpWithdrawGift(1, "vatA", 3) >>
               ELSE << >>]]
    /\ sent = 0
    /\ delivered = << >>
    /\ gifts = [p \in Peers |->
                  [q \in Peers |->
                     [i \in 1..MaxGifts |->
                        IF p = "vatC" /\ q = "vatA" /\ i = 1
                        THEN [kind |-> "gift",
                              recipient |-> "vatB",
                              targetLocalRefId |-> 2]
                        ELSE PS!NoGift]]]
    /\ nextGiftId = [p \in Peers |-> IF p = "vatA" THEN MaxGifts + 1 ELSE 1]
    /\ nextRefId = ChainLength + MaxGifts + 1
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
