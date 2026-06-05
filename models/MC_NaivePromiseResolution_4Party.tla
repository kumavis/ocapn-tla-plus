------------------- MODULE MC_NaivePromiseResolution_4Party -------------------
(***************************************************************************)
(* Unguarded path change on a 4-party linear chain (ChainLength = 3, two   *)
(* promises + terminal).  Race actor: host[2] (the only peer that installs *)
(* a localResolution under terminal-only propagation).                     *)
(*                                                                         *)
(* host[2] resolves p_2 -> RemoteTarget(host[3], 3); op:resolve fires to  *)
(* host[1] which immediately installs the new path (Naive = unguarded     *)
(* path change, no flush).  Subsequent pipelined sends from               *)
(* host[1] take the post-resolution path via channels[host[1]][host[3]]   *)
(* while in-flight pre-resolve forwards still travel via                  *)
(* channels[host[1]][host[2]] -> channels[host[2]][host[3]].              *)
(*                                                                         *)
(* Formerly MC_ShorteningUnsafe_4Party.  The `ShorteningUnsafe` policy    *)
(* was a byte-for-byte alias of NaivePromiseResolution (identical hooks); *)
(* it was merged into Naive and this MC now INSTANCEs NaivePromiseResolution *)
(* directly, retaining the unique 4-party unguarded-race linear coverage. *)
(*                                                                         *)
(* Expected: EndToEndRefFIFO_MC violated.                                  *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC", "vatD"}
HeadPeer == "vatA"
ChainLength == 3
\* 4 peers / ChainLength=3 / NumMessages=2.  The unguarded race is
\* reachable: vatB pipelines toward vatC, vatC resolves p2 to a Target
\* on vatD and tells vatB; vatB takes the post-resolution shortcut to
\* vatD while in-flight forwards still travel via vatC.  Handoff stays
\* enabled so 3-party listener notifications still emit normally
\* (concern 8 gate).
MaxGifts == 2
MaxRefId == ChainLength + MaxGifts
NumMessages == 2
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
EnableShorten == FALSE

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

PS == INSTANCE NaivePromiseResolution

Init ==
    /\ PS!Init
    /\ host = <<"vatB", "vatC", "vatD">>

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
