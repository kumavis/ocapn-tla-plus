------------------------ MODULE Unit_EJavaFlush_RefScopedEmbargo ------------------------
(***************************************************************************)
(* Unit: EJavaFlush's embargo trigger is scoped to the ref under           *)
(* resolution.  When peer vatA receives op:resolve(targetRefId=1, _) from  *)
(* vatB, only in-flight forwards on channels[vatA][vatB] with              *)
(* refId=resolverRefId(1) are racy.  Pre-resolve traffic on a different    *)
(* ref / wire (here: forwards via refs[vatA][2] = RemoteTarget(vatC, 2),   *)
(* sitting on channels[vatA][vatC] with refId=2) is unrelated and must     *)
(* NOT trigger a spurious embargo.                                         *)
(*                                                                         *)
(* Pre-state:                                                              *)
(*   channels[vatA][vatC] = << op:deliver-only(seq=1, refId=2) >>          *)
(*       -- a forward through vatA's RemoteTarget(2), unrelated to ref 1   *)
(*   channels[vatB][vatA] = << op:resolve(1, desc:remote-target(vatC, 2)) >>*)
(*       -- vatB notifying vatA that p_1 resolves to T@vatC                *)
(*   refs[vatA][1] = RemotePromise(vatB, 1, ResNone, embargo=FALSE)        *)
(*   refs[vatA][2] = RemoteTarget(vatC, 2)                                 *)
(*   refs[vatB][1] = LocalPromise(resolution=ResRef(vatC,2), notified=TRUE)*)
(*   refs[vatC][2] = LocalTarget                                           *)
(*                                                                         *)
(* Expected behavior under RoutingPolicy = "EJavaFlush" (faithful           *)
(* DelayedRedirector):                                                     *)
(*   vatA receives op:resolve(1, desc:remote-target(vatC, 2)).             *)
(*   refs[vatA][1].fresh = TRUE (vatA has never pipelined through ref 1;   *)
(*   the unrelated forward on channels[vatA][vatC] went through ref 2,    *)
(*   which clears refs[vatA][2].fresh -- a per-ref bit -- not              *)
(*   refs[vatA][1].fresh).  Therefore the fast path fires, embargo stays   *)
(*   FALSE on refs[vatA][1], and no flush probe is emitted.                *)
(*                                                                         *)
(* The old "any HeadPeer-originated op:deliver-only anywhere in vatA's     *)
(* outbox" heuristic, and even the intermediate "outbox to immediate       *)
(* resolver" heuristic, would have over- or under-fired here.  The         *)
(* per-RemotePromise `fresh` sticky bit is scoped to the specific ref       *)
(* under resolution and is unaffected by traffic on unrelated refs even    *)
(* over the same wire.                                                     *)
(*                                                                         *)
(* INVARIANT NoSpuriousEmbargo_MC catches a spurious embargo on            *)
(* refs[vatA][1] caused by unrelated traffic.                              *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC"}
HeadPeer == "vatA"
ChainLength == 2
MaxGifts == 0
MaxRefId == ChainLength
NumMessages == 1
EmptyInitialListeners == TRUE
EnableDynamicListen == FALSE
EnableHandoff == FALSE
RoutingPolicy == "EJavaFlush"
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

PS == INSTANCE PromiseResolution

Init ==
    /\ host = <<"vatB", "vatC">>
    /\ refs = [p \in Peers |->
                 [r \in (1..MaxRefId) |->
                    CASE p = "vatA" /\ r = 1 ->
                            PS!MkRemotePromise("vatB", 1, PS!ResNone,
                                FALSE, << >>, TRUE, TRUE)
                      [] p = "vatA" /\ r = 2 ->
                            PS!MkRemoteTarget("vatC", 2)
                      [] p = "vatB" /\ r = 1 ->
                            \* Resolution already set and listener notified,
                            \* so ResolverResolve cannot re-fire.  The
                            \* op:resolve below is the in-flight notification.
                            PS!MkLocalPromise(<< >>, {"vatA"},
                                PS!ResRef("vatC", 2), {}, TRUE, "idle")
                      [] p = "vatB" /\ r = 2 ->
                            PS!MkRemoteTarget("vatC", 2)
                      [] p = "vatC" /\ r = 2 ->
                            PS!MkLocalTarget
                      [] OTHER -> PS!EntryNone]]
    /\ channels =
         [p \in Peers |->
            [q \in Peers |->
               CASE p = "vatA" /\ q = "vatC" ->
                       \* Pre-staged unrelated forward via refs[vatA][2].
                       \* sentOnRef=1 matches PeerSend's convention; the
                       \* old heuristic would key on this and over-fire.
                       << [op |-> "op:deliver-only",
                           sender |-> "vatA",
                           sentOnRef |-> 1,
                           seq |-> 1,
                           refId |-> 2] >>
                 [] p = "vatB" /\ q = "vatA" ->
                       << [op |-> "op:resolve",
                           targetRefId |-> 1,
                           value |-> PS!DescRemoteTarget("vatC", 2)] >>
                 [] OTHER -> << >>]]
    /\ sent = 1
    /\ delivered = << >>
    /\ gifts = [p \in Peers |->
                  [q \in Peers |->
                     [i \in 1..MaxGifts |-> PS!NoGift]]]
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

(* The discriminating safety invariant: with the ref-parameterized
   EJavaFlush gate, the embargo bit on refs["vatA"][1] is never set. *)
NoSpuriousEmbargo_MC == refs["vatA"][1].embargo = FALSE
============================================================================
