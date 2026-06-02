-------------------- MODULE MC_OpFlushProtocol_4Party --------------------
(***************************************************************************)
(* Length-3 linear chain under OpFlushProtocol (broader resolver-side      *)
(* op:flush trigger; ocapn#11; see notes/flush-protocols.md §9 and §9.1).  *)
(* The OpFlushProtocol parallel of MC_EJavaFlush_4Party: same topology     *)
(* (4 distinct peers, ChainLength=3, NumMessages=3, EnableRepropagate=     *)
(* FALSE).  HeadPeer vatA holds the top RemotePromise; the resolution      *)
(* chain is hosted one ref per peer across vatB -> vatC -> vatD, so every   *)
(* hop is a distinct wire link (head + 3 hosts = 4 nodes).                  *)
(*                                                                         *)
(* This is the linear-depth probe for the resolver-initiated flush         *)
(* handshake (op:flush -> op:flush-ack -> op:resolve) with atomic queue/    *)
(* pending drains.  It is NOT the crossing/simultaneous-shortening case --  *)
(* that is MC_OpFlushProtocol_TribbleFourWay (EnableRepropagate=TRUE).      *)
(*                                                                         *)
(* Reduced from the former 5-peer / ChainLength=4 MC_OpFlushProtocol_4Chain *)
(* (the canonical Tribble four-way is itself only four-party, so the extra  *)
(* hop added state-space cost without exercising new structure -- see the   *)
(* §3.1 / TribbleFourWay discussion).                                       *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC", "vatD"}
HeadPeer == "vatA"
ChainLength == 3
MaxGifts == 3
MaxRefId == ChainLength + MaxGifts + 6  \* +6 for flush-minted refIds (Ridley)
NumMessages == 3
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
EnableShorten == TRUE

CONSTANT DebugTrace  \* set in .cfg: FALSE for normal run, TRUE for _Debug.cfg

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
    /\ host = <<"vatB", "vatC", "vatD">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

\* SpecDebug: same Init/Next but no fairness; used by _Debug.cfg to render
\* a single counterexample trace without TLC trying to satisfy liveness.
SpecDebug == Init /\ [][Next]_vars

TypeOK_MC == PS!TypeOK
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EventualDelivery_MC == PS!EventualDelivery
WireDescriptorContract_MC == PS!WireDescriptorContract
OnlyKnownResolveDescriptors_MC == PS!OnlyKnownResolveDescriptors

\* Debug-only forced violation: trips when the OpFlushProtocol round
\* (op:flush -> op:flush-ack -> op:e-flush-probe -> op:e-flush-probe-ack
\* -> op:resolve) has completed for the target-bearing LocalPromise AND
\* every send has been delivered.  Detected by the post-ack signature on
\* a LocalPromise (resolution != ResNone, flushPhase = "acked",
\* notified = TRUE, flushPending = {}).  BFS picks the shortest such
\* path, so the rendered debug trace exercises the full protocol
\* (pipelining -> op:flush -> embargo+ack-back -> resolver drains queue
\* -> SendTargetFlushProbe -> probe traverses chain -> probe-ack lifts
\* flushPhase -> SendOpResolveAfterFlush -> ProcessHold drains pending).
\* Under faithful Ridley op:flush, OpFlushProtocol no longer has a
\* multi-phase resolver-side state machine.  The slow-path debug
\* witness now uses the shortener-side flushSent bit on a RemotePromise.
NoSlowPathCompletion_MC ==
    ~( /\ Len(delivered) = NumMessages
       /\ \E p \in Peers : \E r \in 1..MaxRefId :
            /\ r \in {ri \in 1..MaxRefId : vats[p].refs[ri] # PS!EntryNone}
            /\ vats[p].refs[r].kind = "RemotePromise"
            /\ vats[p].refs[r].flushSent )

============================================================================
