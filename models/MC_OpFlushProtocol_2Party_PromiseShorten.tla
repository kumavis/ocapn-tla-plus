--------------- MODULE MC_OpFlushProtocol_2Party_PromiseShorten ---------------
(***************************************************************************)
(* 2-party inter-vat promise-to-promise shortening under OpFlushProtocol.  *)
(* Wire form is the broader-trigger handshake                              *)
(* (op:flush(targetRefId) / op:flush-ack(targetRefId)) with listener-side  *)
(* embargo on the RemotePromise mirror; see notes/flush-protocols.md §9.1.*)
(*                                                                         *)
(* Topology: same as MC_EJavaFlush_2Party_PromiseShorten.                  *)
(*   HeadPeer = vatA                                                       *)
(*   host[1]  = vatB   (LocalPromise p_1; listener {HeadPeer = vatA})      *)
(*   host[2]  = vatA   (LocalPromise p_2; listener {vatB})                 *)
(*   host[3]  = vatB   (LocalTarget T)                                     *)
(*                                                                         *)
(* Expected outcome: EndToEndRefFIFO_MC PASSES.  Under the broader-trigger *)
(* implementation, the resolver-side flush handshake plus the atomic       *)
(* LocalPromise.queue drain inside ResolverResolve, plus the listener-side *)
(* embargo and atomic pending drain inside the op:resolve install branch,  *)
(* eliminate the cascade-shortcut race.                                    *)
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

PS == INSTANCE OpFlushProtocol

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
