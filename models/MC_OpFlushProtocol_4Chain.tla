-------------------- MODULE MC_OpFlushProtocol_4Chain --------------------
(***************************************************************************)
(* 4-chain OpFlushProtocol (faithful Ridley op:flush; ocapn#11; see       *)
(* notes/flush-protocols.md §9 and §9.1).  Shortener-initiated:           *)
(* a peer X that has learned its local RemotePromise resolves to a       *)
(* third party may fire InitiateFlush; the resolver-holder mints a       *)
(* fresh p' and replies with desc:import-promise(p').  No probe, no      *)
(* listener-side flush-ack handshake.                                     *)
(*                                                                         *)
(* Expected: EndToEndRefFIFO_MC violated.  Faithful Ridley does not      *)
(* preserve FIFO on 4-chain.  See notes/path-changes.md §4.7.            *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC", "vatD", "vatE"}
HeadPeer == "vatA"
ChainLength == 4
MaxGifts == 3
MaxRefId == ChainLength + MaxGifts + 6  \* +6 for flush-minted refIds (Ridley)
NumMessages == 3
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
EnableShorten == TRUE
RoutingPolicy == "OpFlushProtocol"

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

PS == INSTANCE PromiseResolution

Init ==
    /\ PS!Init
    /\ host = <<"vatB", "vatC", "vatD", "vatE">>

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
