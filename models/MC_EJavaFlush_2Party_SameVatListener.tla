------------------ MODULE MC_EJavaFlush_2Party_SameVatListener ------------------
(***************************************************************************)
(* Same-vat listener regression for concern 7 (self-loop on resolve       *)
(* notifications).  Topology host = <<vatA, vatA, vatB>>:                 *)
(*                                                                         *)
(*   refs[1] (LocalPromise) at vatA, listener {vatA} (= HeadPeer)         *)
(*   refs[2] (LocalPromise) at vatA, listener {vatA} (= host[1])          *)
(*   refs[3] (LocalTarget)  at vatB                                       *)
(*                                                                         *)
(* refs[2]'s listener set is {vatA} = {self}.  Pre-fix, ResolverResolve at *)
(* vatA for refs[2] under EJavaFlush would call AppendResolveNotifications *)
(* with listener vatA and capHost vatB (target host).  NeedsHandoffIntro  *)
(* holds (vatB \notin {vatA, vatA}) so the handoff-give branch fires,    *)
(* emitting op:resolve(handoff-give) on channels[vatA][vatA].  The         *)
(* op:resolve receive arm requires entry.kind = "RemotePromise" -- but    *)
(* vatA's refs[2] is a LocalPromise (vatA is the resolver), so the       *)
(* receive is disabled and the self-loop FIFO blocks every subsequent     *)
(* message on channels[vatA][vatA].                                       *)
(*                                                                         *)
(* Post-fix, the listeners set is filtered (listeners \ {self}) before    *)
(* AppendResolveNotifications iterates, so no self-addressed op:resolve   *)
(* is emitted; refs[2] resolves locally without wire traffic.  The       *)
(* q # self filter inside AppendToManyOutboxes is also defensive but is  *)
(* exercised by MC_OpFlushProtocol_2Party_SameVatListener instead (that policy  *)
(* emits op:flush via AppendToManyOutboxes).                              *)
(*                                                                         *)
(* Expected: all invariants hold.                                        *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB"}
HeadPeer == "vatA"
ChainLength == 3
MaxRefId == ChainLength
NumMessages == 2
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

PS == INSTANCE EJavaFlush

Init ==
    /\ PS!Init
    /\ host = <<"vatA", "vatA", "vatB">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

TypeOK_MC == PS!TypeOK
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EventualDelivery_MC == PS!EventualDelivery
WireDescriptorContract_MC == PS!WireDescriptorContract
OnlyKnownResolveDescriptors_MC == PS!OnlyKnownResolveDescriptors
============================================================================
