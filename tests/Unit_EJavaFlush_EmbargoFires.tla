------------------------ MODULE Unit_EJavaFlush_EmbargoFires ------------------------
(***************************************************************************)
(* Unit: positive witness that EJavaFlush's embargo gate fires when (and   *)
(* only when) it must on a non-head chain hop, for the canonical            *)
(* three-party introduction routed via desc:handoff-give.  This is the     *)
(* dual of Unit_EJavaFlush_RefScopedEmbargo (which witnesses *non*-firing   *)
(* on unrelated traffic).                                                  *)
(*                                                                         *)
(* Under the import/export/handoff descriptor contract, a resolver         *)
(* introducing a third-party capability to a listener MUST emit            *)
(* desc:handoff-give (NeedsHandoffIntro holds at the resolver), so the    *)
(* EJavaFlush slow path for a three-party scenario at a non-head chain    *)
(* hop lives in the handoff-give receive branch's chainEmbargo arm rather *)
(* than the import/export-target receive branch.  This unit pins that     *)
(* code path.                                                             *)
(*                                                                         *)
(* Minimum topology: three peers, ChainLength 3, terminal looped back to   *)
(* head.                                                                   *)
(*   vatA = HeadPeer = host[3] (LocalTarget T on refs[3])                  *)
(*   vatB = host[1] (LocalPromise p1)                                      *)
(*   vatC = host[2] (LocalPromise p2)                                      *)
(*                                                                         *)
(* Pre-state staged so the only progress-bearing actions are the racing   *)
(* receives.  vatA has already pipelined seq=1 to vatB, vatB has already   *)
(* forwarded it toward vatC (its resolution target), and vatC has already  *)
(* resolved p2 to T@vatA and dispatched its three-party introduction:     *)
(*                                                                         *)
(*   channels[vatB][vatC] = << op:deliver-only(sender=vatA, sentOnRef=1,   *)
(*                                              seq=1, refId=2) >>         *)
(*       -- vatB's previously-forwarded pipelined send sits on its wire    *)
(*          to its resolver.  Because vatB has pipelined through           *)
(*          vats[vatB].refs[2], the per-ref sticky bit                     *)
(*          vats[vatB].refs[2].fresh is FALSE in Init.                     *)
(*   channels[vatC][vatA] = << op:deposit-gift(giftId=1, recipient=vatB,   *)
(*                                              targetLocalRefId=3, pw=4) >>*)
(*       -- vatC's pre-authorization to the target host vatA, in flight   *)
(*          but not yet processed at vatA.                                 *)
(*   channels[vatC][vatB] = << op:resolve(targetRefId=2,                   *)
(*                                desc:handoff-give(gifter=vatC,           *)
(*                                                  targetHost=vatA,       *)
(*                                                  giftId=1, pw=4)) >>    *)
(*       -- vatC's introduction to its listener vatB.  targetHost = vatA   *)
(*          is a third party from vatB's perspective, so the contract     *)
(*          requires desc:handoff-give rather than desc:import-target.    *)
(*                                                                         *)
(* From this Init the receive of the handoff-give at vatB is enabled.      *)
(* Under faithful EJavaFlush, the chain-form handoff-give branch consults: *)
(*   - chainBindable: vats[vatB].refs[2] is an unresolved RemotePromise.  *)
(*     TRUE.                                                               *)
(*   - chainFresh: chainBindable AND vats[vatB].refs[2].fresh.  Because   *)
(*     fresh was cleared by the pipelined forward, chainFresh = FALSE.    *)
(* Both feed chainEmbargo = isChain AND EJavaFlush AND ~chainFresh = TRUE, *)
(* so vatB takes the SLOW PATH: it sets embargo = TRUE on                  *)
(* vats[vatB].refs[2] AND emits an op:e-flush-probe on                    *)
(* channels[vatB][vatC] (the OLD wire to the resolver).  Both effects     *)
(* happen atomically in the single ReceiveNetwork step.                    *)
(*                                                                         *)
(* The invariant EmbargoNeverFires_MC is intentionally the *negation* of   *)
(* the embargo flip.  TLC reports a violation; that violation IS the       *)
(* witness trace.  The unit test is wired in scripts/run-tests.sh with     *)
(* `expected = violation`.                                                 *)
(*                                                                         *)
(* If the chain-form handoff-give receive ever regresses to never          *)
(* embargoing on the slow path (e.g. by accidentally short-circuiting the *)
(* chainFresh branch), this test starts passing and run-tests.sh flags    *)
(* it as a MISMATCH.  See Unit_EJavaFlush_HandoffChainProbe for the       *)
(* stronger joint witness that also pins the probe emission, and           *)
(* notes/path-changes.md sections 3.5 and 3.7 for the contract and        *)
(* coverage rationale.                                                    *)
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
RoutingPolicy == "EJavaFlush"
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
    /\ host = <<"vatB", "vatC", "vatA">>
    /\ vats =
         [p \in Peers |->
            [refs |->
               [r \in (1..MaxRefId) |->
                  CASE p = "vatA" /\ r = 1 ->
                          \* vatA's view of p1; resolver vatB, already
                          \* notified of resolution to (vatC, 2).  fresh =
                          \* FALSE because the pre-staged op:deliver-only
                          \* below was sent by vatA through this ref.
                          PS!MkRemotePromise("vatB", 1,
                              PS!ResRef("vatC", 2),
                              FALSE, << >>, TRUE, FALSE)
                    [] p = "vatA" /\ r = 2 ->
                            \* vatA's view of p2; resolver vatC.  Not yet
                            \* notified locally (vatA is not a listener in
                            \* this staged scenario).
                            PS!MkRemotePromise("vatC", 2, PS!ResNone,
                                FALSE, << >>, TRUE, TRUE)
                    [] p = "vatA" /\ r = 3 ->
                            \* The terminal target on the head peer.
                            PS!MkLocalTarget
                    [] p = "vatB" /\ r = 1 ->
                            \* p1 on vatB, already resolved to (vatC, 2) and
                            \* listener {vatA} already notified.  Marking
                            \* notified = TRUE keeps ResolverResolve disabled.
                            PS!MkLocalPromise(<< >>, {"vatA"},
                                PS!ResRef("vatC", 2), {}, TRUE, "idle", FALSE, {})
                    [] p = "vatB" /\ r = 2 ->
                            \* vatB's view of p2; resolver vatC.  Unresolved
                            \* and un-embargoed at Init.  fresh = FALSE: the
                            \* pre-staged op:deliver-only on channels[vatB]
                            \* [vatC] is the forward vatB performed through
                            \* this ref before the handoff-give arrived.
                            \* Under faithful EJavaFlush this kicks the
                            \* chain-form slow path (chainEmbargo) on receipt
                            \* of op:resolve(desc:handoff-give); embargo
                            \* flips TRUE and a probe is emitted.
                            PS!MkRemotePromise("vatC", 2, PS!ResNone,
                                FALSE, << >>, TRUE, FALSE)
                    [] p = "vatC" /\ r = 1 ->
                            PS!MkRemotePromise("vatB", 1, PS!ResNone,
                                FALSE, << >>, TRUE, TRUE)
                    [] p = "vatC" /\ r = 2 ->
                            \* p2 on vatC, already resolved to (vatA, 3) and
                            \* listener {vatB} already dispatched (the
                            \* handoff-give is in flight on
                            \* channels[vatC][vatB], paired with the
                            \* deposit-gift on channels[vatC][vatA]).
                            PS!MkLocalPromise(<< >>, {"vatB"},
                                PS!ResRef("vatA", 3), {}, TRUE, "idle", FALSE, {})
                    [] p = "vatC" /\ r = 3 ->
                            PS!MkRemoteTarget("vatA", 3)
                    [] OTHER -> PS!EntryNone],
             gifts |->
               [q \in Peers |-> [i \in 1..MaxGifts |-> PS!NoGift]],
             \* vatC has already allocated giftId=1 for the handoff above;
             \* its next free counter is 2.  vatA and vatB have allocated
             \* none and remain at 1.
             nextGiftId |->
               IF p = "vatC" THEN 2 ELSE 1]]
    /\ channels =
         [p \in Peers |->
            [q \in Peers |->
               CASE p = "vatB" /\ q = "vatC" ->
                       \* vatB's previously-forwarded pipelined send to its
                       \* resolver.  refId = vats[vatB].refs[2].resolverRefId
                       \* = 2; sentOnRef = 1 records the original ref vatA
                       \* sent on.
                       << [op |-> "op:deliver-only",
                           sender |-> "vatA",
                           sentOnRef |-> 1,
                           seq |-> 1,
                           refId |-> 2] >>
                 [] p = "vatC" /\ q = "vatA" ->
                       \* The deposit-gift accompanies the handoff-give.
                       \* Both are emitted atomically by vatC's ResolverResolve
                       \* in the modelled spec; we pre-stage them here as
                       \* in-flight.
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

(* The witness: vats["vatB"].refs[2].embargo MUST flip to TRUE on the
   chainEmbargo branch of the handoff-give receive.  Negating that with an
   invariant gives TLC a counterexample trace whose final state has
   vats["vatB"].refs[2].embargo = TRUE -- exactly the firing we want to
   demonstrate.  Unit_EJavaFlush_HandoffChainProbe pairs this with the
   probe-emission witness for a stronger joint assertion. *)
EmbargoNeverFires_MC ==
    \/ vats["vatB"].refs[2].kind # "RemotePromise"
    \/ vats["vatB"].refs[2].embargo = FALSE
============================================================================
