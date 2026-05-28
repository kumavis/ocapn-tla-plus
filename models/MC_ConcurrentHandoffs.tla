------------------------- MODULE MC_ConcurrentHandoffs -------------------------
(***************************************************************************)
(* Gift-table sanity probe: two concurrent gifters allocate              *)
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
EnableHandoffInitiate == TRUE
EnableRepropagate == FALSE
RoutingPolicy == "NoPromiseResolution"
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

PS == INSTANCE PromiseResolution

Init ==
    /\ host = <<"vatC", "vatC">>
    /\ vats =
         [p \in Peers |->
            [refs |->
               [r \in (1..MaxRefId) |->
                  CASE p = "vatA" /\ r = 1 ->
                          PS!MkRemoteTarget("vatC", 1)
                    [] p = "vatB" /\ r = 1 ->
                            PS!MkRemoteTarget("vatC", 1)
                    [] p = "vatC" /\ r = 1 ->
                            PS!MkLocalTarget
                    [] OTHER -> PS!EntryNone],
             gifts |->
               [q \in Peers |-> [i \in 1..MaxGifts |-> PS!NoGift]],
             nextGiftId |-> 1]]
    /\ channels = [p \in Peers |-> [q \in Peers |-> << >>]]
    /\ sent = 0
    /\ delivered = << >>
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
WireDescriptorContract_MC == PS!WireDescriptorContract
TwoPartyWireDescsOnly_MC == PS!TwoPartyWireDescsOnly
============================================================================
