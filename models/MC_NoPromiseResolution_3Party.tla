--------------------- MODULE MC_NoPromiseResolution_3Party ---------------------
(***************************************************************************)
(* ChainLength = 3 (two promises + terminal), NoPromiseResolution policy. *)
(* host existentially chosen at Init.  Expected: holds.                   *)
(*                                                                         *)
(* NumMessages = 3 (raised from 2) so this single no-path-change baseline *)
(* also covers the deeper-pipeline FIFO surface the former 2-party        *)
(* baseline (MC_NoPromiseResolution_2Party, nm=3) exercised.  Since this  *)
(* policy emits no op:resolve, FIFO holds trivially regardless; the 3-hop *)
(* chain at nm=3 subsumes the 2-hop chain at nm=3.                         *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC"}
HeadPeer == "vatA"
ChainLength == 3
MaxRefId == ChainLength
NumMessages == 3
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

PS == INSTANCE NoPromiseResolution

Init == PS!Init

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
