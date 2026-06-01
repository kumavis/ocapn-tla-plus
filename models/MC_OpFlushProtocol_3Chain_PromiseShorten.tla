--------------- MODULE MC_OpFlushProtocol_3Chain_PromiseShorten ---------------
(***************************************************************************)
(* 2-party inter-vat promise-to-promise shortening under OpFlushProtocol   *)
(* (faithful Ridley op:flush; ocapn#11; see notes/flush-protocols.md §9). *)
(*                                                                         *)
(* Topology: same as MC_EJavaFlush_3Chain_PromiseShorten.                  *)
(*   HeadPeer = vatA                                                       *)
(*   host[1]  = vatB   (LocalPromise p_1; listener {HeadPeer = vatA})      *)
(*   host[2]  = vatA   (LocalPromise p_2; listener {vatB})                 *)
(*   host[3]  = vatB   (LocalTarget T)                                     *)
(*                                                                         *)
(* Expected outcome: EndToEndRefFIFO_MC violated.  See                    *)
(* notes/path-changes.md §4.7 for the trace and root cause -- the         *)
(* shortest counterexample never fires InitiateFlush; the race surfaces  *)
(* purely from OpFlushProtocol's immediate-install arm of                 *)
(* fireOpResolveNow racing the chain drain.                                *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB"}
HeadPeer == "vatA"
ChainLength == 3
MaxGifts == 1
MaxRefId == ChainLength + MaxGifts + 6  \* +6 for flush-minted refIds (Ridley)
NumMessages == 2
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
EnableShorten == TRUE
RoutingPolicy == "OpFlushProtocol"

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

PS == INSTANCE PromiseResolution

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
