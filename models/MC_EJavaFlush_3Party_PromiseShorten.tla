----------- MODULE MC_EJavaFlush_3Party_PromiseShorten -----------
(***************************************************************************)
(* 3-party inter-vat promise-to-promise shortening under EJavaFlush.       *)
(* Same topology as MC_NaivePromiseResolution_3Party (Phase B) but with   *)
(* Phase C 3-party flush: firePromiseShorten3Party under EJavaFlush is     *)
(* gated by ListenersWitnessPipelined; chain-form desc:handoff-give takes  *)
(* the local chainEmbargo + e-flush-probe slow path when fresh=FALSE.      *)
(*                                                                         *)
(* NumMessages = 2 surfaces a real race: the EJavaFlush 3-party flush      *)
(* path does NOT preserve FIFO for two pipelined ref-1 sends.  Previously *)
(* NumMessages = 1 hid this since a single delivery has no FIFO surface.   *)
(* This is a known gap in the 3-party flush; see PR notes for details.    *)
(* Expected: EndToEndRefFIFO_MC violated.                                  *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC"}
HeadPeer == "vatA"
ChainLength == 3
MaxGifts == 2
MaxRefId == ChainLength + MaxGifts
NumMessages == 2
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
EnableShorten == FALSE

CONSTANT DebugTrace

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
    /\ host = <<"vatB", "vatC", "vatC">>

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
