------------------------- MODULE Unit_Listen_Subscribe_Unresolved -------------------------
(***************************************************************************)
(* op:listen unit test: op:listen arrives at the resolver BEFORE the promise *)
(* has been resolved.                                                      *)
(*                                                                         *)
(*   Peers     = {vatA, vatB}                                              *)
(*   host      = <<vatA, vatA>>     (LocalPromise p_1 AND LocalTarget T    *)
(*                                   both hosted at vatA)                  *)
(*   HeadPeer  = vatA                                                      *)
(*                                                                         *)
(* Expected behavior:                                                      *)
(*   - vatB Listens -> vatA receives op:listen while LocalPromise[1] is    *)
(*     still unresolved.                                                   *)
(*   - vatA adds vatB to listeners; no immediate op:resolve reply.         *)
(*   - vatA later ResolverResolves; with vatB in listeners, op:resolve     *)
(*     fires (NaivePromiseResolution path).                                *)
(*   - vatB receives op:resolve, installs localResolution.                 *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB"}
HeadPeer == "vatA"
ChainLength == 2
MaxRefId == ChainLength
NumMessages == 1
EmptyInitialListeners == TRUE
EnableDynamicListen == TRUE
EnableHandoff == FALSE
EnableHandoffInitiate == FALSE
MaxGifts == 0
RoutingPolicy == "NaivePromiseResolution"
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

PS == INSTANCE PromiseResolution

Init ==
    /\ PS!Init
    /\ host = <<"vatA", "vatA">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

TypeOK_MC == PS!TypeOK
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EventualDelivery_MC == PS!EventualDelivery
============================================================================
