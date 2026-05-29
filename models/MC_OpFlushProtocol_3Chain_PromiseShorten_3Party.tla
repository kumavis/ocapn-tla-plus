-------- MODULE MC_OpFlushProtocol_3Chain_PromiseShorten_3Party --------
(***************************************************************************)
(* 3-party inter-vat promise-to-promise shortening under OpFlushProtocol. *)
(* Same topology as MC_NaivePromiseResolution_3Chain; Phase C extends    *)
(* fireOpFlush / probe / post-flush resolve for 3-party promise caps when  *)
(* ListenersWitnessPipelined holds.  Each peer's flush is local-only.      *)
(* NumMessages=1 (see MC_EJavaFlush_3Chain_PromiseShorten_3Party).         *)
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
RoutingPolicy == "OpFlushProtocol"

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
OnlyKnownResolveDescriptors_MC == PS!OnlyKnownResolveDescriptors
GiftOneShot_MC == PS!GiftOneShot
GiftHasOneRecipient_MC == PS!GiftHasOneRecipient

============================================================================
