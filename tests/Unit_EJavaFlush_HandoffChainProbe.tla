------------------------ MODULE Unit_EJavaFlush_HandoffChainProbe ------------------------
(***************************************************************************)
(* Unit: joint witness for the chain-form desc:handoff-give slow path     *)
(* under RoutingPolicy = "EJavaFlush", per notes/path-changes.md §3.7.    *)
(*                                                                         *)
(* Unit_EJavaFlush_EmbargoFires already witnesses that the embargo bit    *)
(* on vats[recipient].refs[targetRefId] flips to TRUE on this branch.    *)
(* This unit goes one step further and pins BOTH effects of the slow path *)
(* in a single state:                                                     *)
(*                                                                         *)
(*   (1) vats[recipient].refs[targetRefId].embargo := TRUE                *)
(*   (2) channels[recipient][resolverPeer] appends an op:e-flush-probe    *)
(*       carrying (originPeer = recipient, originRefId = targetRefId,    *)
(*                 refId = chainEntry.resolverRefId)                      *)
(*                                                                         *)
(* The conjunction must hold in the SAME ReceiveNetwork step: the spec's *)
(* chain-form handoff-give receive applies the embargo flip and appends   *)
(* the probe atomically, so any regression that decouples them (e.g.     *)
(* keeps the embargo flip but forgets to emit the probe, or vice versa)  *)
(* would surface here while Unit_EJavaFlush_EmbargoFires (which only      *)
(* watches the embargo bit) would miss the asymmetric break.             *)
(*                                                                         *)
(* Topology, pre-state and dynamics are identical to                      *)
(* Unit_EJavaFlush_EmbargoFires (see that module's preamble for the      *)
(* three-peer chain and the rationale for each refs / channels entry).   *)
(* The only difference is the witness invariant.                          *)
(*                                                                         *)
(* HandoffChainNoSlowPath_MC asserts the NEGATION of the joint slow-path *)
(* witness.  TLC reports a violation; the violation trace's terminal     *)
(* state has embargo = TRUE AND the probe sitting in                     *)
(* channels["vatB"]["vatC"] — exactly the joint effect we want to       *)
(* demonstrate.  Wired in scripts/run-tests.sh with `expected =          *)
(* violation`.                                                           *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC"}
HeadPeer == "vatA"
ChainLength == 3
MaxGifts == 1
MaxRefId == ChainLength + MaxGifts
NumMessages == 1
EmptyInitialListeners == TRUE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
EnableShorten == FALSE

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

PS == INSTANCE EJavaFlush

Init ==
    /\ host = <<"vatB", "vatC", "vatA">>
    /\ vats =
         [p \in Peers |->
            [refs |->
               [r \in (1..MaxRefId) |->
                  CASE p = "vatA" /\ r = 1 ->
                          PS!MkRemotePromise(
                              "vatB",
                              1,
                              PS!ResRef("vatC", 2),
                              {},
                              << >>,
                              TRUE,
                              FALSE,
                              FALSE)
                    [] p = "vatA" /\ r = 2 ->
                            PS!MkRemotePromise(
                                "vatC",
                                2,
                                PS!ResNone,
                                {},
                                << >>,
                                TRUE,
                                TRUE,
                                FALSE)
                    [] p = "vatA" /\ r = 3 ->
                            PS!MkLocalTarget
                    [] p = "vatB" /\ r = 1 ->
                            PS!MkLocalPromise(
                                << >>,
                                {"vatA"},
                                PS!ResRef("vatC", 2),
                                {},
                                TRUE,
                                FALSE,
                                {})
                    [] p = "vatB" /\ r = 2 ->
                            \* fresh = FALSE: vatB has already pipelined
                            \* a forward through ref 2 (pre-staged on
                            \* channels[vatB][vatC] below).  This drives
                            \* chainFresh = FALSE on the handoff-give
                            \* receive and so chainEmbargo = TRUE under
                            \* EJavaFlush.
                            PS!MkRemotePromise(
                                "vatC",
                                2,
                                PS!ResNone,
                                {},
                                << >>,
                                TRUE,
                                FALSE,
                                FALSE)
                    [] p = "vatC" /\ r = 1 ->
                            PS!MkRemotePromise(
                                "vatB",
                                1,
                                PS!ResNone,
                                {},
                                << >>,
                                TRUE,
                                TRUE,
                                FALSE)
                    [] p = "vatC" /\ r = 2 ->
                            PS!MkLocalPromise(
                                << >>,
                                {"vatB"},
                                PS!ResRef("vatA", 3),
                                {},
                                TRUE,
                                FALSE,
                                {})
                    [] p = "vatC" /\ r = 3 ->
                            PS!MkRemoteTarget("vatA", 3)
                    [] OTHER -> PS!EntryNone],
             gifts |->
               [q \in Peers |-> [i \in 1..MaxGifts |-> PS!NoGift]],
             nextGiftId |->
               IF p = "vatC" THEN 2 ELSE 1]]
    /\ channels =
         [p \in Peers |->
            [q \in Peers |->
               CASE p = "vatB" /\ q = "vatC" ->
                       << [op |-> "op:deliver-only",
                           sender |-> "vatA",
                           sentOnRef |-> 1,
                           seq |-> 1,
                           refId |-> 2] >>
                 [] p = "vatC" /\ q = "vatA" ->
                       << [op |-> "op:deposit-gift",
                           giftId |-> 1,
                           recipient |-> "vatB",
                           targetLocalRefId |-> 3,
                           pw |-> 4] >>
                 [] p = "vatC" /\ q = "vatB" ->
                       << [op |-> "op:resolve",
                           targetRefId |-> 2,
                           value |->
                             PS!DescHandoffGive("vatC", "vatA", 1, 4)] >>
                 [] OTHER -> << >>]]
    /\ sent = 1
    /\ delivered = << >>
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
WireDescriptorContract_MC == PS!WireDescriptorContract
OnlyKnownResolveDescriptors_MC == PS!OnlyKnownResolveDescriptors

(* Witness predicates -- factored out for clarity in the invariant. *)
RecipientEmbargoed ==
    /\ vats["vatB"].refs[2].kind = "RemotePromise"
    /\ vats["vatB"].refs[2].embargo # {}

(* The probe must originate at the recipient (vatB), be tagged with the
   recipient's targetRefId (=2), and carry chainEntry.resolverRefId (=2,
   the wire refId of the existing RemotePromise pointing at the resolver).
   It must sit on channels[recipient][resolverPeer] = channels[vatB][vatC]. *)
ProbeEnqueuedOnOldWire ==
    \E i \in 1..Len(channels["vatB"]["vatC"]) :
        LET msg == channels["vatB"]["vatC"][i]
        IN /\ msg.op = "op:e-flush-probe"
           /\ msg.originPeer = "vatB"
           /\ msg.originRefId = 2
           /\ msg.refId = 2

(* Negation of the joint witness; TLC's counterexample IS the demonstration
   that the chain-form slow path fires both effects atomically. *)
HandoffChainNoSlowPath_MC ==
    ~(RecipientEmbargoed /\ ProbeEnqueuedOnOldWire)
============================================================================
