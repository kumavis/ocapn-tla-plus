------------------------ MODULE Unit_EJavaFlush_EmbargoFires ------------------------
(***************************************************************************)
(* Unit: positive witness that EJavaFlush's embargo gate fires when (and   *)
(* only when) it must, on a non-head chain hop.  This is the dual of       *)
(* Unit_EJavaFlush_RefScopedEmbargo (which witnesses *non*-firing on       *)
(* unrelated traffic).                                                     *)
(*                                                                         *)
(* Minimum topology to exercise embargo at a peer other than HeadPeer:     *)
(* three peers, ChainLength 3, terminal looped back to head.               *)
(*   vatA = HeadPeer = host[3] (LocalTarget T)                             *)
(*   vatB = host[1] (LocalPromise p1)                                      *)
(*   vatC = host[2] (LocalPromise p2)                                      *)
(*                                                                         *)
(* Pre-state staged so the only progress-bearing actions are the racing   *)
(* receives.  vatA has already pipelined seq=1 to vatB, vatB has already   *)
(* forwarded it toward vatC (its resolution target), and vatC has already  *)
(* resolved p2 to T@vatA and dispatched op:resolve to its listener vatB:   *)
(*                                                                         *)
(*   channels[vatB][vatC] = << op:deliver-only(sender=vatA, sentOnRef=1,   *)
(*                                              seq=1, refId=2) >>         *)
(*       -- the pipelined forward sits on vatB's wire to its resolver.     *)
(*          Because vatB has pipelined through refs[vatB][2], the          *)
(*          per-ref sticky bit refs[vatB][2].fresh is FALSE in Init.       *)
(*   channels[vatC][vatB] = << op:resolve(targetRefId=2,                   *)
(*                                         desc:remote-target(vatA, 3)) >> *)
(*       -- vatC notifying its listener vatB that p2 resolves to T@vatA.   *)
(*                                                                         *)
(* From this Init the receive of op:resolve at vatB is enabled.  Under     *)
(* faithful EJavaFlush, vatB consults:                                     *)
(*   - refs[vatB][2].fresh = FALSE (the sticky bit was cleared when vatB   *)
(*     pipelined the seq=1 forward).                                       *)
(*   - sameConnection: vatA = refs[vatB][2].resolverPeer = vatC? FALSE.    *)
(* Both fast-path predicates are FALSE, so vatB takes the SLOW PATH:       *)
(* sets embargo = TRUE on refs[vatB][2] and emits op:e-flush-probe on      *)
(* channels[vatB][vatC].  The embargo flip is the witness.                 *)
(*                                                                         *)
(* The invariant EmbargoNeverFires_MC is intentionally the *negation* of   *)
(* the embargo flip.  TLC reports a violation; that violation IS the       *)
(* witness trace.  The unit test is wired in scripts/run-tests.sh with     *)
(* `expected = violation`.                                                 *)
(*                                                                         *)
(* If EJavaFlush ever regresses to never embargoing at a non-head peer    *)
(* (e.g. by accidentally short-circuiting the policy at HeadPeer), this   *)
(* test starts passing and run-tests.sh flags it as a MISMATCH.            *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC"}
HeadPeer == "vatA"
ChainLength == 3
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
    /\ host = <<"vatB", "vatC", "vatA">>
    /\ refs = [p \in Peers |->
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
                            \* notified locally (the op:resolve from vatC is
                            \* still in flight on channels[vatC][vatB]; vatA
                            \* is not a listener in this staged scenario).
                            PS!MkRemotePromise("vatC", 2, PS!ResNone,
                                FALSE, << >>, TRUE, TRUE)
                      [] p = "vatA" /\ r = 3 ->
                            PS!MkLocalTarget
                      [] p = "vatB" /\ r = 1 ->
                            \* p1 on vatB, already resolved to (vatC, 2) and
                            \* listener {vatA} already notified.  Marking
                            \* notified = TRUE keeps ResolverResolve disabled.
                            PS!MkLocalPromise(<< >>, {"vatA"},
                                PS!ResRef("vatC", 2), {}, TRUE, "idle")
                      [] p = "vatB" /\ r = 2 ->
                            \* vatB's view of p2; resolver vatC.  Unresolved
                            \* and un-embargoed at Init.  fresh = FALSE: the
                            \* pre-staged op:deliver-only on channels[vatB]
                            \* [vatC] is the forward vatB performed through
                            \* this ref before the resolve arrived.  Under
                            \* faithful EJavaFlush this kicks the slow path
                            \* (probe + ack) on receive of op:resolve;
                            \* embargo flips TRUE.  listenSent = TRUE so
                            \* SendListen is not enabled.
                            PS!MkRemotePromise("vatC", 2, PS!ResNone,
                                FALSE, << >>, TRUE, FALSE)
                      [] p = "vatB" /\ r = 3 ->
                            PS!MkRemoteTarget("vatA", 3)
                      [] p = "vatC" /\ r = 1 ->
                            PS!MkRemotePromise("vatB", 1, PS!ResNone,
                                FALSE, << >>, TRUE, TRUE)
                      [] p = "vatC" /\ r = 2 ->
                            \* p2 on vatC, already resolved to (vatA, 3) and
                            \* listener {vatB} already dispatched (in-flight
                            \* on channels[vatC][vatB]).
                            PS!MkLocalPromise(<< >>, {"vatB"},
                                PS!ResRef("vatA", 3), {}, TRUE, "idle")
                      [] p = "vatC" /\ r = 3 ->
                            PS!MkRemoteTarget("vatA", 3)
                      [] OTHER -> PS!EntryNone]]
    /\ channels =
         [p \in Peers |->
            [q \in Peers |->
               CASE p = "vatB" /\ q = "vatC" ->
                       \* vatB's previously-forwarded pipelined send to its
                       \* resolver.  refId = refs[vatB][2].resolverRefId = 2;
                       \* sentOnRef = 1 records the original ref vatA sent on.
                       << [op |-> "op:deliver-only",
                           sender |-> "vatA",
                           sentOnRef |-> 1,
                           seq |-> 1,
                           refId |-> 2] >>
                 [] p = "vatC" /\ q = "vatB" ->
                       << [op |-> "op:resolve",
                           targetRefId |-> 2,
                           value |-> PS!DescRemoteTarget("vatA", 3)] >>
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

(* The witness: refs["vatB"][2].embargo MUST flip to TRUE on the
   embargo-firing branch.  Negating that with an invariant gives TLC a
   counterexample trace whose final state has refs["vatB"][2].embargo =
   TRUE -- exactly the firing we want to demonstrate. *)
EmbargoNeverFires_MC ==
    \/ refs["vatB"][2].kind # "RemotePromise"
    \/ refs["vatB"][2].embargo = FALSE
============================================================================
