------------------------ MODULE Unit_Handoff_DepositWithdraw ------------------------
(***************************************************************************)
(* Unit: minimal opaque 3PHO round-trip.                                  *)
(*                                                                         *)
(* Topology:                                                               *)
(*   vatA = gifter (holds RemoteTarget to vatC[2])                        *)
(*   vatB = recipient                                                      *)
(*   vatC = target host (LocalTarget at refId 2)                          *)
(*                                                                         *)
(* HandoffInitiate fires once, then the three wire messages (deposit-     *)
(* gift, op:resolve(desc:handoff-give), withdraw-gift) get processed in   *)
(* any FIFO-respecting order.  At quiescence:                              *)
(*   - vats[vatC].gifts[vatA][1] is cleared (NoGift)                      *)
(*   - vats[vatC].refs[3] is LocalPromise resolved to ResRef(vatC, 2)     *)
(*   - vats[vatB].refs[3] is RemotePromise(vatC, 3) with                  *)
(*     localResolution = ResRef(vatC, 2)                                  *)
(*                                                                         *)
(* PairingInvariant, GiftOneShot, GiftHasOneRecipient hold throughout.    *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC"}
HeadPeer == "vatA"
ChainLength == 2
MaxGifts == 1
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
    /\ host = <<"vatA", "vatC">>
    /\ vats =
         [p \in Peers |->
            [refs |->
               [r \in (1..MaxRefId) |->
                  CASE p = "vatA" /\ r = 1 ->
                          PS!MkLocalPromise(<< >>, {},
                              PS!ResNone, {}, FALSE, "idle", FALSE, {})
                    [] p = "vatA" /\ r = 2 ->
                            PS!MkRemoteTarget("vatC", 2)
                    [] p = "vatB" /\ r = 1 ->
                            PS!MkRemotePromise("vatA", 1, PS!ResNone,
                                FALSE, << >>, TRUE, TRUE)
                    [] p = "vatC" /\ r = 2 ->
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
