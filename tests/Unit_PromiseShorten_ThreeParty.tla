------------------------ MODULE Unit_PromiseShorten_ThreeParty ------------------------
(***************************************************************************)
(* Unit: positive witness that ResolverResolve fires desc:handoff-give     *)
(* with a Promise cap when a LocalPromise shortens to a Promise hosted on  *)
(* a vat that is neither the resolver nor the listener (the third-party    *)
(* case modelled in Phase B; see notes/path-changes.md §1.2.b and §3.9). *)
(*                                                                         *)
(* Topology (ChainLength = 3, three peers):                                *)
(*   HeadPeer = vatA                                                       *)
(*   host[1]  = vatB   (LocalPromise p_1; listener {HeadPeer = vatA})      *)
(*   host[2]  = vatC   (LocalPromise p_2; listener {vatB})                 *)
(*   host[3]  = vatC   (LocalTarget T)                                     *)
(*                                                                         *)
(* From the resolver vatB's perspective at r = 1:                          *)
(*   - res = ChainResolutionFor(1) = ResRef(vatC, 2)                       *)
(*   - LocalRef(vatB, 2) = RemotePromise(vatC, 2)  -> isPromise = TRUE     *)
(*   - capHost = TargetHostPeer(vatB, res) = vatC (RemotePromise.resolverPeer arm)
*)
(*   - For the one listener vatA: NeedsHandoffIntro(vatB, vatA, vatC)     *)
(*     = vatC \notin {vatB, vatA} = TRUE -- 3-party.                       *)
(*   - firePromiseShorten3Party fires under NaivePromiseResolution.       *)
(*                                                                         *)
(* The handoff branch in AppendResolveNotifications then emits:           *)
(*   channels[vatB][vatC] += op:deposit-gift(gid, vatA, tlr=2, pw)        *)
(*   channels[vatB][vatA] += op:resolve(1,                               *)
(*                              desc:handoff-give(vatB, vatC, gid, pw))   *)
(*                                                                         *)
(* vatA later issues op:withdraw-gift to vatC; vatC's pre-minted          *)
(* LocalPromise(pw) resolves to ResRef(vatC, 2) (since vats[vatC].refs[2] *)
(* = LocalPromise) and replies                                            *)
(*   channels[vatC][vatA] += op:resolve(pw, desc:import-promise(2))      *)
(* per Phase B's withdraw extension in ReceiveOpWithdrawGift.            *)
(*                                                                         *)
(* The witness invariant NoChainHandoffGiveForPromise_MC is the negation *)
(* of the desc:handoff-give wire shape; TLC's counterexample IS the      *)
(* witness trace.  Wired in scripts/run-tests.sh with `expected =       *)
(* violation`.                                                            *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC"}
HeadPeer == "vatA"
ChainLength == 3
MaxGifts == 1
MaxRefId == ChainLength + MaxGifts
NumMessages == 1
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
RoutingPolicy == "NaivePromiseResolution"
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
    /\ PS!Init
    /\ host = <<"vatB", "vatC", "vatC">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

TypeOK_MC == PS!TypeOK
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
EventualDelivery_MC == PS!EventualDelivery
WireDescriptorContract_MC == PS!WireDescriptorContract
TwoPartyWireDescsOnly_MC == PS!TwoPartyWireDescsOnly
GiftOneShot_MC == PS!GiftOneShot
GiftHasOneRecipient_MC == PS!GiftHasOneRecipient

(* Witness 1: vatB's ResolverResolve fires the chain handoff-give for the
   promise cap on vatC -- proves the cascade-induced handoff path opened
   for promise-shaped resolutions in Phase B. *)
NoChainHandoffGiveForPromise_MC ==
    ~ \E i \in 1..Len(channels["vatB"]["vatA"]) :
        LET m == channels["vatB"]["vatA"][i]
        IN /\ m.op = "op:resolve"
           /\ m.targetRefId = 1
           /\ m.value.desc = "desc:handoff-give"
           /\ m.value.gifter = "vatB"
           /\ m.value.targetHost = "vatC"
============================================================================
