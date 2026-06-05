------------------------ MODULE Unit_PromiseShorten_TwoParty ------------------------
(***************************************************************************)
(* Unit: positive witness that ResolverResolve fires an op:resolve         *)
(* carrying a two-party promise descriptor (desc:export-promise) when a    *)
(* LocalPromise shortens to a Promise hosted on a different vat AND that  *)
(* host happens to be the listener (so no handoff-give is required).      *)
(* This is the inter-vat promise-shortening case modelled in Phase A; see *)
(* notes/path-changes.md §1.2.b and the Phase A delta in §3.8.            *)
(*                                                                         *)
(* Topology (ChainLength = 3, two peers):                                  *)
(*   host[1] = vatB (LocalPromise p_1, listener {HeadPeer = vatA})         *)
(*   host[2] = vatA (LocalPromise p_2, listener {vatB})                    *)
(*   host[3] = vatA (LocalTarget T)                                        *)
(*                                                                         *)
(* From the resolver vatB's perspective at r=1:                            *)
(*   - res = ChainResolutionFor(1) = ResRef(vatA, 2)                       *)
(*   - LocalRef(vatB, 2) = RemotePromise(vatA, 2)  -> isTarget = FALSE,   *)
(*     isPromise = TRUE.                                                   *)
(*   - TargetHostPeer(vatB, res) = vatA (RemotePromise.resolverPeer arm). *)
(*   - For the one listener vatA: NeedsHandoffIntro(vatB, vatA, vatA)    *)
(*     = FALSE, so AllListenersTwoParty holds.                            *)
(*   - WireDescTag(vatB, vatA, vatA, "RemotePromise") = "export-promise"  *)
(*     (capHost = receiver = vatA, kind not in target set).                *)
(*                                                                         *)
(* Under the NaivePromiseResolution policy, firePromiseShorten is TRUE on *)
(* the very first ResolverResolve step at r=1, and the resulting          *)
(* op:resolve(1, desc:export-promise(2)) lands on channels[vatB][vatA].   *)
(*                                                                         *)
(* The invariant NoExportPromiseEmitted_MC is the negation of that wire   *)
(* shape.  TLC reports a violation; that violation IS the witness trace.  *)
(* Wired in scripts/run-tests.sh with `expected = violation`.             *)
(*                                                                         *)
(* If the Phase A emission ever regresses (e.g. fireOpResolveNow is       *)
(* tightened back to isTarget-only, or AllListenersTwoParty silently     *)
(* fails for this two-party shape), this unit starts passing and          *)
(* run-tests.sh flags it as a MISMATCH.                                   *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB"}
HeadPeer == "vatA"
ChainLength == 3
MaxRefId == ChainLength
NumMessages == 1
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == FALSE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
EnableShorten == FALSE
MaxGifts == 0

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

PS == INSTANCE NaivePromiseResolution

Init ==
    /\ PS!Init
    /\ host = <<"vatB", "vatA", "vatA">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

TypeOK_MC == PS!TypeOK
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
EventualDelivery_MC == PS!EventualDelivery
WireDescriptorContract_MC == PS!WireDescriptorContract
OnlyKnownResolveDescriptors_MC == PS!OnlyKnownResolveDescriptors

(* The witness: vatB's ResolverResolve at r=1 MUST append
   op:resolve(targetRefId=1, desc:export-promise(refId=2)) on
   channels[vatB][vatA].  Negating that with an invariant makes TLC
   render a counterexample whose terminal state contains exactly the
   wire shape we want to demonstrate. *)
NoExportPromiseEmitted_MC ==
    ~ \E i \in 1..Len(channels["vatB"]["vatA"]) :
        LET m == channels["vatB"]["vatA"][i]
        IN /\ m.op = "op:resolve"
           /\ m.targetRefId = 1
           /\ m.value.desc = "desc:export-promise"
           /\ m.value.refId = 2
============================================================================
