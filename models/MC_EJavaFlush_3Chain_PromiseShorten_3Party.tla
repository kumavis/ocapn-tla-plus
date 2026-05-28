----------- MODULE MC_EJavaFlush_3Chain_PromiseShorten_3Party -----------
(***************************************************************************)
(* 3-party inter-vat promise-to-promise shortening under EJavaFlush.       *)
(* Same topology as MC_NaivePromiseResolution_3Chain (Phase B) but with   *)
(* Phase C 3-party flush: firePromiseShorten3Party under EJavaFlush is     *)
(* gated by ListenersWitnessPipelined; chain-form desc:handoff-give takes  *)
(* the local chainEmbargo + e-flush-probe slow path when fresh=FALSE.      *)
(* NumMessages=1: a second post-shorten send (NumMessages=2) is the race   *)
(* exercised by MC_NaivePromiseResolution_3Chain; this MC checks the       *)
(* 3-party flush path does not break FIFO for the single in-flight send.   *)
(* Expected: EndToEndRefFIFO_MC PASSES.                                    *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC"}
HeadPeer == "vatA"
ChainLength == 3
MaxGifts == 2
MaxRefId == ChainLength + MaxGifts
NumMessages == 1
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
RoutingPolicy == "EJavaFlush"

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

PS == INSTANCE PromiseResolution

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
TwoPartyWireDescsOnly_MC == PS!TwoPartyWireDescsOnly
GiftOneShot_MC == PS!GiftOneShot
GiftHasOneRecipient_MC == PS!GiftHasOneRecipient

============================================================================
