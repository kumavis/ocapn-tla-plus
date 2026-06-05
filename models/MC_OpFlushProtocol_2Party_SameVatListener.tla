--------------- MODULE MC_OpFlushProtocol_2Party_SameVatListener ---------------
(***************************************************************************)
(* Same-vat listener regression under OpFlushProtocol.  Topology and       *)
(* rationale mirror MC_EJavaFlush_2Party_SameVatListener.                         *)
(*                                                                         *)
(* Pre-fix path: ResolverResolve at vatA for refs[2] would take fireOpFlush *)
(* and call AppendToManyOutboxes(channels, vatA, {vatA}, OpFlush(2)),     *)
(* enqueuing op:flush on channels[vatA][vatA].  The op:flush receive arm  *)
(* requires entry.kind = "RemotePromise" but vatA's refs[2] is a          *)
(* LocalPromise, so the receive is disabled and the self-loop FIFO blocks *)
(* every subsequent message on channels[vatA][vatA].                       *)
(*                                                                         *)
(* Post-fix, the listeners filter at the call site (listeners \ {self})  *)
(* strips vatA before fireOpFlush evaluates, so fireOpFlush is FALSE      *)
(* (OpFlushCoversPromise requires listeners # {}) and the action falls   *)
(* into OTHER (silent install).  Even if a future caller bypassed the    *)
(* filter, AppendToManyOutboxes's own q # self guard would still prevent *)
(* the self-loop enqueue.                                                 *)
(*                                                                         *)
(* Expected: all invariants hold.                                         *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB"}
HeadPeer == "vatA"
ChainLength == 3
MaxRefId == ChainLength + 6  \* +6 for flush-minted refIds (Ridley)
NumMessages == 2
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == FALSE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
EnableShorten == TRUE
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

PS == INSTANCE OpFlushProtocol

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
