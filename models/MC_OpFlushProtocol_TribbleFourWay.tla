------------- MODULE MC_OpFlushProtocol_TribbleFourWay -------------
(***************************************************************************)
(* Tribble-style crossing promise shortenings under OpFlushProtocol.       *)
(* Same three-peer co-terminal topology as MC_EJavaFlush_TribbleFourWay.   *)
(* Each hop runs local op:flush / probe / resolve when its own predicates  *)
(* hold; no cross-node flush relay. Expected: EndToEndRefFIFO_MC PASS.      *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC"}
HeadPeer == "vatA"
ChainLength == 3
MaxGifts == 3
MaxRefId == ChainLength + MaxGifts
NumMessages == 2
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
EnableHandoffInitiate == FALSE
EnableRepropagate == TRUE
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
TwoPartyWireDescsOnly_MC == PS!TwoPartyWireDescsOnly
GiftOneShot_MC == PS!GiftOneShot
GiftHasOneRecipient_MC == PS!GiftHasOneRecipient

============================================================================
