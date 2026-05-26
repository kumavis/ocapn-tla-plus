-------------------- MODULE MC_OpFlushProtocol_4Chain --------------------
(***************************************************************************)
(* 4-chain OpFlushProtocol (Ridley op:flush proposal, locality-clean       *)
(* model).  On promise resolution at host[3], emit op:flush(p_3) to all   *)
(* listeners; each listener atomically sets embargo and enqueues          *)
(* op:flush-ack on the same FIFO channel (the channel ordering carries    *)
(* the pre-flush draining, so no peer infers anything from the other      *)
(* end's channel state).  Once all flush-acks are in and the resolver's   *)
(* own queue is drained, host[3] emits op:e-flush-probe to host[4]; the   *)
(* terminal acks with op:e-flush-probe-ack, advancing the resolver's     *)
(* flushPhase to "acked" and enabling SendOpResolveAfterFlush.  Only      *)
(* then does op:resolve fire to listeners.  See                            *)
(* ../notes/flush-protocols.md section 9 and ../README.md "Routing        *)
(* policies".                                                              *)
(*                                                                         *)
(* Expected: EndToEndRefFIFO_MC holds.                                    *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC", "vatD", "vatE"}
HeadPeer == "vatA"
ChainLength == 4
MaxRefId == ChainLength
NumMessages == 3
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == FALSE
MaxGifts == 0
RoutingPolicy == "OpFlushProtocol"

CONSTANT DebugTrace  \* set in .cfg: FALSE for normal run, TRUE for _Debug.cfg

VARIABLES
    channels,
    host,
    refs,
    sent,
    delivered,
    gifts,
    nextGiftId,
    nextRefId,
    lastAction

vars == << channels, host, refs, sent, delivered, gifts, nextGiftId, nextRefId, lastAction >>

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
NoSlowPathCompletion_MC ==
    ~( /\ Len(delivered) = NumMessages
       /\ \E p \in Peers : \E r \in 1..MaxRefId :
            /\ r \in {ri \in 1..MaxRefId : refs[p][ri] # PS!EntryNone}
            /\ refs[p][r].kind = "LocalPromise"
            /\ refs[p][r].resolution # PS!ResNone
            /\ refs[p][r].flushPhase = "acked"
            /\ refs[p][r].notified
            /\ refs[p][r].flushPending = {} )

============================================================================
