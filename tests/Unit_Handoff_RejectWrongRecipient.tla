------------------------ MODULE Unit_Handoff_RejectWrongRecipient ------------------------
(***************************************************************************)
(* Unit: a peer that is NOT the named recipient must not be able to       *)
(* withdraw a gift.                                                        *)
(*                                                                         *)
(* Adversarial Init:                                                       *)
(*   - vats[vatC].gifts[vatA][1] = (recipient = vatB,                     *)
(*                                  targetLocalRefId = 2)                 *)
(*   - channels[vatX][vatC] = << op:withdraw-gift(1, vatA, 3) >>          *)
(*     where vatX = "vatD" is NOT the named recipient                     *)
(*                                                                         *)
(* Expected: vatC silently rejects the withdraw (channel drained, no new  *)
(* LocalPromise at vats[vatC].refs[3], gift entry unchanged).  When vatB *)
(* later sends a legitimate withdraw, vatC accepts it.                    *)
(* GiftHasOneRecipient and GiftOneShot hold throughout.                   *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC", "vatD"}
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
                    [] p = "vatB" /\ r = 3 ->
                            PS!MkRemotePromise("vatC", 3, PS!ResNone,
                                FALSE, << >>, TRUE, TRUE)
                    [] p = "vatC" /\ r = 2 ->
                            PS!MkLocalTarget
                    [] p = "vatC" /\ r = 3 ->
                            PS!MkLocalPromise(<< >>, {"vatB"},
                                PS!ResNone, {}, FALSE, "idle", FALSE, {})
                    [] OTHER -> PS!EntryNone],
             gifts |->
               [q \in Peers |->
                  [i \in 1..MaxGifts |->
                     IF p = "vatC" /\ q = "vatA" /\ i = 1
                     THEN [kind |-> "gift",
                           recipient |-> "vatB",
                           targetLocalRefId |-> 2]
                     ELSE PS!NoGift]],
             nextGiftId |-> IF p = "vatA" THEN 2 ELSE 1]]
    /\ channels =
         [p \in Peers |->
            [q \in Peers |->
               CASE p = "vatD" /\ q = "vatC" ->
                       << PS!OpWithdrawGift(1, "vatA", 3) >>
                 [] p = "vatB" /\ q = "vatC" ->
                       << PS!OpWithdrawGift(1, "vatA", 3) >>
                 [] OTHER -> << >>]]
    /\ sent = 0
    /\ delivered = << >>
    /\ nextRefId = ChainLength + 1 + 1
    /\ lastAction = [name |-> "init"]

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

TypeOK_MC == PS!TypeOK
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
GiftOneShot_MC == PS!GiftOneShot
GiftHasOneRecipient_MC == PS!GiftHasOneRecipient
WireDescriptorContract_MC == PS!WireDescriptorContract
OnlyKnownResolveDescriptors_MC == PS!OnlyKnownResolveDescriptors

\* Behavioral check: at quiescence, gift slot is cleared (the legitimate
\* withdraw from vatB succeeded) and the wrong-recipient withdraw never
\* did damage.
GiftEventuallyCleared ==
    [] (   (\A p, q \in Peers : Len(channels[p][q]) = 0)
        => vats["vatC"].gifts["vatA"][1] = PS!NoGift )
============================================================================
