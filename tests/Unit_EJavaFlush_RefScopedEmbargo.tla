------------------------ MODULE Unit_EJavaFlush_RefScopedEmbargo ------------------------
(***************************************************************************)
(* Unit: EJavaFlush's chainEmbargo trigger is scoped to the chain ref       *)
(* under resolution.  When peer vatA receives a chain-form                  *)
(* op:resolve(targetRefId=1, desc:handoff-give(...)) from its resolver      *)
(* vatB, only the per-ref `fresh` sticky bit on vats[vatA].refs[1]         *)
(* governs whether the slow path engages.  Pre-resolve traffic that vatA   *)
(* has pipelined through a different RemoteTarget on the SAME wire         *)
(* (here: vats[vatA].refs[2] = RemoteTarget(vatC, 2), with a               *)
(* deliver-only sitting on channels[vatA][vatC] keyed by refId=2)          *)
(* is unrelated and must NOT trigger a spurious embargo on refs[1].        *)
(*                                                                         *)
(* This unit was originally written against the old desc:remote-target     *)
(* one-shape descriptor.  Under the import/export/handoff descriptor       *)
(* contract, the three-party case where this scoping question matters     *)
(* lives exclusively in the desc:handoff-give receive branch (a            *)
(* same-host two-party introduction never traverses chainEmbargo).  The   *)
(* test therefore now stages the canonical three-party hop via            *)
(* desc:handoff-give and asserts the same ref-scoped non-firing property. *)
(*                                                                         *)
(* Pre-state:                                                              *)
(*   channels[vatA][vatC] = << op:deliver-only(refId=2) >>                 *)
(*       -- a forward through vatA's RemoteTarget(refs[2]), unrelated to  *)
(*          ref 1.  Does NOT clear vats[vatA].refs[1].fresh.               *)
(*   channels[vatB][vatA] = << op:resolve(1,                               *)
(*                              desc:handoff-give(vatB, vatC, 1, 3)) >>    *)
(*       -- vatB notifying vatA that p_1 resolves to a target on vatC.    *)
(*          targetHost = vatC is a third party from vatA's perspective,   *)
(*          so the wire descriptor MUST be desc:handoff-give per the      *)
(*          contract enforced by WireDescriptorContract.                  *)
(*   channels[vatB][vatC] = << op:deposit-gift(1, vatA, 2, 3) >>           *)
(*       -- the paired deposit accompanying the handoff-give (both are    *)
(*          emitted atomically by vatB's ResolverResolve).                *)
(*                                                                         *)
(*   vats[vatA].refs[1] = RemotePromise(vatB, 1, ResNone,                  *)
(*                                       fresh=TRUE, listenSent=TRUE)      *)
(*   vats[vatA].refs[2] = RemoteTarget(vatC, 2)                            *)
(*   vats[vatB].refs[1] = LocalPromise(resolution=ResRef(vatC, 2),         *)
(*                                     notified=TRUE)                      *)
(*   vats[vatB].refs[2] = RemoteTarget(vatC, 2)                            *)
(*   vats[vatC].refs[2] = LocalTarget                                      *)
(*                                                                         *)
(* Expected behavior under RoutingPolicy = "EJavaFlush":                   *)
(*   vatA receives op:resolve(1, desc:handoff-give(vatB, vatC, 1, 3)).    *)
(*   targetRefId = 1, pw = 3, isChain = TRUE.  Chain-form handoff-give   *)
(*   consults vats[vatA].refs[1].fresh, NOT vats[vatA].refs[2].fresh:    *)
(*     chainBindable = TRUE  (refs[1] is unresolved RemotePromise)        *)
(*     chainEntry    = vats[vatA].refs[1]                                 *)
(*     chainFresh    = chainBindable AND chainEntry.fresh = TRUE          *)
(*     chainEmbargo  = isChain AND EJavaFlush AND ~chainFresh = FALSE     *)
(*   The fast path fires: embargo stays FALSE on vats[vatA].refs[1] and  *)
(*   no flush probe is emitted.  The unrelated deliver-only on            *)
(*   channels[vatA][vatC] cleared vats[vatA].refs[2].fresh -- a per-ref  *)
(*   bit -- not vats[vatA].refs[1].fresh.                                *)
(*                                                                         *)
(* The old "any HeadPeer-originated op:deliver-only anywhere in vatA's     *)
(* outbox" heuristic, and even the intermediate "outbox to immediate       *)
(* resolver" heuristic, would have over-fired here.  The per-RemotePromise *)
(* `fresh` sticky bit is scoped to the specific ref under resolution and   *)
(* is unaffected by traffic on unrelated refs even over the same wire.    *)
(*                                                                         *)
(* INVARIANT NoSpuriousEmbargo_MC catches a spurious embargo on            *)
(* vats[vatA].refs[1] caused by unrelated traffic.                         *)
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
    /\ host = <<"vatB", "vatC">>
    /\ vats =
         [p \in Peers |->
            [refs |->
               [r \in (1..MaxRefId) |->
                  CASE p = "vatA" /\ r = 1 ->
                          \* fresh = TRUE: vatA has never pipelined through
                          \* ref 1.  The unrelated deliver-only below went
                          \* through ref 2.  listenSent = TRUE keeps Listen
                          \* disabled.
                          PS!MkRemotePromise(
                              "vatB",
                              1,
                              PS!ResNone,
                              {},
                              << >>,
                              TRUE,
                              TRUE,
                              FALSE)
                    [] p = "vatA" /\ r = 2 ->
                            PS!MkRemoteTarget("vatC", 2)
                    [] p = "vatB" /\ r = 1 ->
                            \* Resolution already set and listener notified,
                            \* so ResolverResolve cannot re-fire.  The
                            \* op:resolve(desc:handoff-give) below is the
                            \* in-flight notification.
                            PS!MkLocalPromise(
                                << >>,
                                {"vatA"},
                                PS!ResRef("vatC", 2),
                                {},
                                TRUE,
                                FALSE,
                                {})
                    [] p = "vatB" /\ r = 2 ->
                            \* vatB's RemoteTarget pointing at the third
                            \* party vatC.  Required so vatB's resolution
                            \* of p1 to (vatC, 2) is well-typed.
                            PS!MkRemoteTarget("vatC", 2)
                    [] p = "vatC" /\ r = 2 ->
                            PS!MkLocalTarget
                    [] OTHER -> PS!EntryNone],
             gifts |->
               [q \in Peers |-> [i \in 1..MaxGifts |-> PS!NoGift]],
             \* vatB has already allocated giftId=1 for the handoff above;
             \* its next free counter is 2.  vatA and vatC have allocated
             \* none and remain at 1.
             nextGiftId |->
               IF p = "vatB" THEN 2 ELSE 1]]
    /\ channels =
         [p \in Peers |->
            [q \in Peers |->
               CASE p = "vatA" /\ q = "vatC" ->
                       \* Pre-staged unrelated forward via vats[vatA].refs[2].
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
                           value |->
                             PS!DescHandoffGive("vatB", "vatC", 1, 3)] >>
                 [] p = "vatB" /\ q = "vatC" ->
                       \* The deposit-gift paired with the handoff-give.
                       \* Emitted atomically by vatB's ResolverResolve in
                       \* the modelled spec; pre-staged here as in-flight.
                       << [op |-> "op:deposit-gift",
                           giftId |-> 1,
                           recipient |-> "vatA",
                           targetLocalRefId |-> 2,
                           pw |-> 3] >>
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

(* The discriminating safety invariant: with the ref-parameterized
   chainEmbargo gate (chainFresh consults the per-ref fresh bit, not any
   "did this peer ever send anything?" heuristic), the embargo set on
   vats[vatA].refs[1] is never populated. *)
NoSpuriousEmbargo_MC == vats["vatA"].refs[1].embargo = {}
============================================================================
