--------------------- MODULE Unit_WireDesc_DescriptorChoice ---------------------
(***************************************************************************)
(* Unit: wire descriptor selection for op:resolve introductions.           *)
(*                                                                         *)
(* Pins three representative op:resolve shapes on the wire and checks     *)
(* that each matches the import/export/handoff contract from the         *)
(* receiver's perspective:                                                 *)
(*   - desc:import-target  — capability hosted on the sender             *)
(*   - desc:export-target  — capability hosted on the receiver           *)
(*   - desc:handoff-give   — third-party capability (neither endpoint)     *)
(*                                                                         *)
(* Also exercises the pure WireDescMatches / WireDescTag classifiers.     *)
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
EnableHandoffInitiate == FALSE
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
                  CASE p = "vatA" /\ r = 2 -> PS!MkRemoteTarget("vatC", 2)
                    [] p = "vatB" /\ r = 1 ->
                            PS!MkRemotePromise(
                                "vatA",
                                1,
                                PS!ResNone,
                                {},
                                << >>,
                                TRUE,
                                TRUE,
                                FALSE)
                    [] p = "vatB" /\ r = 3 ->
                            PS!MkRemotePromise(
                                "vatC",
                                3,
                                PS!ResNone,
                                {},
                                << >>,
                                TRUE,
                                TRUE,
                                FALSE)
                    [] p = "vatC" /\ r = 2 -> PS!MkLocalTarget
                    [] p = "vatC" /\ r = 3 ->
                            PS!MkLocalPromise(
                                << >>,
                                {"vatB"},
                                PS!ResRef("vatC", 2),
                                {},
                                TRUE,
                                FALSE,
                                {})
                    [] OTHER -> PS!EntryNone],
             gifts |->
               [q \in Peers |-> [i \in 1..MaxGifts |-> PS!NoGift]],
             nextGiftId |-> 1]]
    /\ channels =
         [p \in Peers |->
            [q \in Peers |->
               CASE p = "vatA" /\ q = "vatB" ->
                       \* 3PHO: vatA introduces vatC's target to vatB.
                       << [op |-> "op:resolve",
                           targetRefId |-> 3,
                           value |-> PS!DescHandoffGive("vatA", "vatC", 1, 3)] >>
                 [] p = "vatB" /\ q = "vatC" ->
                       \* Target hosted on receiver vatC.
                       << [op |-> "op:resolve",
                           targetRefId |-> 1,
                           value |-> PS!DescExportTarget(2)] >>
                 [] p = "vatC" /\ q = "vatB" ->
                       \* Withdraw response: target hosted on sender vatC.
                       << [op |-> "op:resolve",
                           targetRefId |-> 3,
                           value |-> PS!DescImportTarget(2)] >>
                 [] OTHER -> << >>]]
    /\ sent = 0
    /\ delivered = << >>
    /\ nextRefId = ChainLength + MaxGifts + 1
    /\ lastAction = [name |-> "init"]

Stutter ==
    /\ UNCHANGED channels
    /\ UNCHANGED host
    /\ UNCHANGED vats
    /\ UNCHANGED sent
    /\ UNCHANGED delivered
    /\ UNCHANGED nextRefId
    /\ UNCHANGED lastAction

Spec == Init /\ [][Stutter]_vars

TypeOK_MC == PS!TypeOK
WireDescriptorContract_MC == PS!WireDescriptorContract
OnlyKnownResolveDescriptors_MC == PS!OnlyKnownResolveDescriptors

ImportTargetClassified_MC ==
    PS!WireDescMatches("vatC", "vatB", "vatC", "LocalTarget",
        PS!DescImportTarget(2))

ExportTargetClassified_MC ==
    PS!WireDescMatches("vatB", "vatC", "vatC", "LocalTarget",
        PS!DescExportTarget(2))

HandoffOnlyWhenThirdParty_MC ==
    /\ PS!WireDescTag("vatA", "vatB", "vatC", "LocalTarget") = "handoff-give"
    /\ PS!WireDescTag("vatA", "vatB", "vatA", "LocalTarget") = "import-target"
    /\ PS!WireDescTag("vatB", "vatC", "vatC", "LocalTarget") = "export-target"

PinnedImportTarget_MC ==
    channels["vatC"]["vatB"][1].value.desc = "desc:import-target"

PinnedExportTarget_MC ==
    channels["vatB"]["vatC"][1].value.desc = "desc:export-target"

PinnedHandoffGive_MC ==
    /\ channels["vatA"]["vatB"][1].value.desc = "desc:handoff-give"
    /\ channels["vatA"]["vatB"][1].value.targetHost = "vatC"
    /\ channels["vatA"]["vatB"][1].value.targetHost \notin {"vatA", "vatB"}
============================================================================
