------------------- MODULE MC_ShorteningUnsafe_4Chain -------------------
(***************************************************************************)
(* ChainLength = 4 (three promises + terminal).  Race actor: host[2]      *)
(* (the only peer that ever installs a localResolution under terminal-    *)
(* only propagation).                                                      *)
(*                                                                         *)
(* host[3] resolves p_3 -> RemoteTarget(host[4], 4); op:resolve fires to  *)
(* host[2] which immediately installs the new path (ShorteningUnsafe =    *)
(* unguarded path change, no flush).  Subsequent pipelined sends from     *)
(* host[2] take the post-resolution path via channels[host[2]][host[4]]   *)
(* while in-flight pre-resolve forwards still travel via                  *)
(* channels[host[2]][host[3]] -> channels[host[3]][host[4]].              *)
(*                                                                         *)
(* "Shortening" in the policy name is OCapN-colloquial for "the act of    *)
(* changing the route" -- see ../README.md "Path changes" and             *)
(* ../notes/path-changes.md.                                               *)
(*                                                                         *)
(* Expected: EndToEndRefFIFO_MC violated.                                  *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC", "vatD", "vatE"}
HeadPeer == "vatA"
ChainLength == 4
MaxGifts == 3
MaxRefId == ChainLength + MaxGifts
NumMessages == 5
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
RoutingPolicy == "ShorteningUnsafe"
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
    /\ host = <<"vatB", "vatC", "vatD", "vatE">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

TypeOK_MC == PS!TypeOK
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EventualDelivery_MC == PS!EventualDelivery
WireDescriptorContract_MC == PS!WireDescriptorContract
TwoPartyWireDescsOnly_MC == PS!TwoPartyWireDescsOnly

============================================================================
