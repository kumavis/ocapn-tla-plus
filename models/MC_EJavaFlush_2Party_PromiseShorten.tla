--------------- MODULE MC_EJavaFlush_2Party_PromiseShorten ---------------
(***************************************************************************)
(* 2-party inter-vat promise-to-promise shortening under EJavaFlush.       *)
(* Same topology as MC_NaivePromiseResolution_2Party_PromiseShorten (Phase A)     *)
(* but with the EJavaFlush slow-path embargo + e-flush-probe handshake     *)
(* extended in Phase C to fire on promise-shaped resolutions               *)
(* (notes/path-changes.md §3.10).                                          *)
(*                                                                         *)
(* Topology (ChainLength = 3, two peers):                                  *)
(*   HeadPeer = vatA                                                       *)
(*   host[1]  = vatB   (LocalPromise p_1; listener {HeadPeer = vatA})      *)
(*   host[2]  = vatA   (LocalPromise p_2; listener {vatB})                 *)
(*   host[3]  = vatB   (LocalTarget T)                                     *)
(*                                                                         *)
(* From vatB's perspective at r=1:                                         *)
(*   - res = ChainResolutionFor(1) = ResRef(vatA, 2)                       *)
(*   - LocalRef(vatB, 2) = RemotePromise(vatA, 2)  -> isPromise = TRUE     *)
(*   - capHost = TargetHostPeer(vatB, res) = vatA                          *)
(*   - listeners = {vatA}; capHost = listener -> 2-party                   *)
(*   - firePromiseShorten fires under EJavaFlush (Phase C 2-party gate)   *)
(*                                                                         *)
(* From vatA's perspective at r=2:                                         *)
(*   - res = ChainResolutionFor(2) = ResRef(vatB, 3)                       *)
(*   - isTarget = TRUE; listener {vatB}; capHost = vatB = listener        *)
(*   - 2-party desc:export-target (cap on receiver), which is NOT          *)
(*     covered by the EJavaFlush sameConn fast path (sameConn is          *)
(*     restricted to desc:import-target in Phase C, see                   *)
(*     notes/path-changes.md §3.10).  The receiver's prior chain          *)
(*     forwards (fresh=FALSE) therefore take the slow path: set           *)
(*     embargo on refs[2] AND emit op:e-flush-probe.  This protects       *)
(*     the chain intermediary race that import-target's same-connection  *)
(*     fast path would otherwise expose.                                  *)
(*                                                                         *)
(* What we expect: EndToEndRefFIFO_MC PASSES.                              *)
(*   - vatA's refs[1] receive embargoes (Phase C: desc:export-promise    *)
(*     is no longer in sameConn).                                         *)
(*   - vatB's refs[2] receive embargoes (desc:export-target was never    *)
(*     in sameConn).                                                      *)
(*   - Both flush probes ride channels FIFO behind in-flight forwards;   *)
(*     ack-driven embargo release plus ProcessHold drainage ensure       *)
(*     no message reaches the terminal LocalTarget out of order.         *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB"}
HeadPeer == "vatA"
ChainLength == 3
MaxGifts == 1
MaxRefId == ChainLength + MaxGifts
NumMessages == 2
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
EnableShorten == FALSE

CONSTANT DebugTrace  \* set in .cfg

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
    /\ PS!Init
    /\ host = <<"vatB", "vatA", "vatB">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

SpecDebug == Init /\ [][Next]_vars

TypeOK_MC == PS!TypeOK
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
EventualDelivery_MC == PS!EventualDelivery
WireDescriptorContract_MC == PS!WireDescriptorContract
OnlyKnownResolveDescriptors_MC == PS!OnlyKnownResolveDescriptors
GiftOneShot_MC == PS!GiftOneShot
GiftHasOneRecipient_MC == PS!GiftHasOneRecipient

============================================================================
