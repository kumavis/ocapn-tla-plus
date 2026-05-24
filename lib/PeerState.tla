----------------------------- MODULE PeerState -----------------------------
(***************************************************************************)
(* Simplified per-peer state after the Phase 1b/1c refactor:               *)
(*   - localQueues collapsed into LocalTarget delivery (apply to sink).    *)
(*   - pending collapsed into LocalPromise.queue.                          *)
(*   - per-RemotePromise flush state lives on the entry itself.            *)
(*                                                                         *)
(* Phase 3 additions:                                                       *)
(*   - gifts[targetHost][gifter][giftId] table of deposited gifts,         *)
(*     atomically created on op:deposit-gift and removed on the matching   *)
(*     op:withdraw-gift.  Keys (gifter, giftId) are gifter-scoped per the  *)
(*     OCapN gift-table model.                                             *)
(*   - nextGiftId[gifter] per-peer monotonic gift counter.                 *)
(*   - nextRefId is a global monotonic refId allocator for handoff         *)
(*     withdraw-promises (chain refs 1..ChainLength are reserved).          *)
(***************************************************************************)

EXTENDS Naturals, Sequences, Network

CONSTANT MaxGifts

ASSUME /\ MaxGifts \in Nat

GiftIds == 1..MaxGifts

NoGift == [kind |-> "none"]

GiftEntry ==
    [kind: {"gift"},
     recipient: Peers,
     targetLocalRefId: Nat]

VARIABLES
    sent,          \* 0..NumMessages (head peer only)
    delivered,     \* Seq of delivery records (see PromiseResolution)
    gifts,         \* [Peers -> [Peers -> [GiftIds -> GiftEntry \cup {NoGift}]]]
    nextGiftId,    \* [Peers -> Nat]; per-gifter counter
    nextRefId      \* Nat; global handoff refId allocator

PeerStateInit ==
    /\ sent = 0
    /\ delivered = << >>
    /\ gifts =
         [t \in Peers |->
            [g \in Peers |->
                [i \in GiftIds |-> NoGift]]]
    /\ nextGiftId = [p \in Peers |-> 1]
    /\ nextRefId = ChainLength + 1

PeerStateTypeOK(DeliveredEntry, NumMessagesArg, MaxRefIdArg) ==
    /\ sent \in 0..NumMessagesArg
    /\ delivered \in Seq(DeliveredEntry)
    /\ gifts \in [Peers -> [Peers -> [GiftIds -> GiftEntry \cup {NoGift}]]]
    /\ nextGiftId \in [Peers -> 0..(MaxGifts + 1)]
    /\ nextRefId \in 0..(MaxRefIdArg + 1)

============================================================================
