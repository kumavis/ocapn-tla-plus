------------------------ MODULE Unit_Handoff_Pipeline_BeforeDeposit ------------------------
(***************************************************************************)
(* Unit: a pipelined op:deliver-only(refId=pw) reaches the target host    *)
(* on channels[recipient][targetHost] strictly before the corresponding   *)
(* op:deposit-gift reaches it on channels[gifter][targetHost].  These two *)
(* messages travel on different wires (no FIFO between them), so the      *)
(* pipelined message can race ahead.                                       *)
(*                                                                         *)
(* Expectation: the target host's ReceiveNetwork handler is *disabled* on *)
(* the pipelined message (refs[targetHost][pw] = EntryNone) and the wire  *)
(* head-of-line blocks until the deposit pre-mints LocalPromise(pw).       *)
(* Once the deposit fires, LocalPromise(pw) exists, the pipelined send is  *)
(* enqueued at LocalPromise(pw).queue, and the standard ReceiveOpWithdraw *)
(* + ProcessPending drain delivers it to the LocalTarget.  This is the    *)
(* "queueing via promise" invariant: the pipelined message ultimately     *)
(* lands in a LocalPromise.queue, not in any ad-hoc buffer.               *)
(*                                                                         *)
(* Pre-state (HandoffInitiate already fired; messages staged on wires):   *)
(*   channels[vatB][vatC] = << op:deliver-only(seq=1, refId=3),           *)
(*                              op:withdraw-gift(1, vatA, 3) >>           *)
(*   channels[vatA][vatC] = << op:deposit-gift(1, vatB, 2, 3) >>          *)
(*   refs[vatA][2]    = RemoteTarget(vatC, 2)                            *)
(*   refs[vatB][1]    = RemotePromise(vatC, 3, listenSent=TRUE)           *)
(*   refs[vatC][2]    = LocalTarget                                      *)
(*   gifts[vatC][vatA][1] = NoGift   (deposit not yet processed)         *)
(*                                                                         *)
(* The deliver-only is staged at the head of vatB->vatC; the withdraw is  *)
(* behind it.  Because the deliver-only's refId=3 has no entry at vatC,   *)
(* ReceiveNetwork on (vatB, vatC) is disabled until vatA's deposit at the *)
(* head of vatA->vatC is processed.  After deposit, LocalPromise(3) is    *)
(* minted and the deliver-only queues there; withdraw then resolves it.   *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC"}
HeadPeer == "vatB"
ChainLength == 2
MaxGifts == 1
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
                      [] OTHER -> PS!EntryNone]]
    /\ channels =
         [p \in Peers |->
            [q \in Peers |->
               CASE p = "vatA" /\ q = "vatC" ->
                       << [op |-> "op:deposit-gift",
                           giftId |-> 1,
                           recipient |-> "vatB",
                           targetLocalRefId |-> 2,
                           pw |-> 3] >>
                 [] p = "vatB" /\ q = "vatC" ->
                       << [op |-> "op:deliver-only",
                           sender |-> "vatB",
                           sentOnRef |-> 1,
                           seq |-> 1,
                           refId |-> 3],
                          [op |-> "op:withdraw-gift",
                           giftId |-> 1,
                           gifter |-> "vatA",
                           withdrawPromiseRefId |-> 3] >>
                 [] OTHER -> << >>]]
    /\ sent = 1     \* PeerSend already fired (msg now in vatB->vatC wire)
    /\ delivered = << >>
    /\ gifts = [p \in Peers |->
                  [q \in Peers |->
                     [i \in 1..MaxGifts |-> PS!NoGift]]]
    /\ nextGiftId = [p \in Peers |-> IF p = "vatA" THEN 2 ELSE 1]
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
