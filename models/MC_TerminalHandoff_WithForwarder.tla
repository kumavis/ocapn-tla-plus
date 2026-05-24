------------------------- MODULE MC_TerminalHandoff_WithForwarder -------------------------
(***************************************************************************)
(* Phase 3 forwarder-race scenario: vatA is a forwarder for vatC; vatB    *)
(* holds a RemotePromise to vatA's forwarder; concurrently vatA runs the  *)
(* 3PHO to shorten vatB's ref directly to vatC.                          *)
(*                                                                         *)
(* Topology (pinned at Init, bypasses MkChainRefs):                       *)
(*   vatA: refs[1] = LocalPromise(queue=<>, listeners={vatB},             *)
(*                                resolution=ResRef(vatA, 2))             *)
(*         refs[2] = RemoteTarget(vatC, 2)                                *)
(*   vatB: refs[1] = RemotePromise(vatA, 1, localResolution=ResNone)      *)
(*   vatC: refs[2] = LocalTarget                                          *)
(*                                                                         *)
(* Race: vatB pipelines op:deliver-only on ref 1 (routed via vatA to     *)
(* vatC); concurrently HandoffInitiate(vatA, vatB, srcRef=2,             *)
(* existingRefId=1) installs the shorten.  After the withdraw-gift       *)
(* round-trip completes, vatB's localResolution on ref 1 routes future   *)
(* sends directly to vatC, bypassing vatA.  In-flight pre-shorten        *)
(* messages may arrive after later direct sends.                          *)
(*                                                                         *)
(* Expected: EndToEndRefFIFO violation; NoMessageLost, PairingInvariant, *)
(* GiftOneShot, GiftHasOneRecipient all hold.                            *)
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
                    CASE p = "vatA" /\ r = 1 ->
                            PS!MkLocalPromise(<< >>, {"vatB"},
                                PS!ResRef("vatA", 2), {}, FALSE)
                      [] p = "vatA" /\ r = 2 ->
                            PS!MkRemoteTarget("vatC", 2)
                      [] p = "vatB" /\ r = 1 ->
                            PS!MkRemotePromise("vatA", 1, PS!ResNone,
                                FALSE, "idle", << >>, TRUE)
                      [] p = "vatC" /\ r = 2 ->
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
