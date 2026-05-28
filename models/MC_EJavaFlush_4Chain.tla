---------------------- MODULE MC_EJavaFlush_4Chain ----------------------
(***************************************************************************)
(* CANONICAL EJavaFlush on a 4-chain (faithful DelayedRedirector model).   *)
(* On op:resolve at host[2] for vats[host[2]].refs[3], if `fresh = FALSE`   *)
(* (i.e., host[2] has previously pipelined sends through this ref) and    *)
(* the new target is not in the same vat as the current resolver, host[2] *)
(* takes the slow path: stage localResolution, set embargo, and emit       *)
(* op:e-flush-probe on the wire to host[3].  The probe rides the          *)
(* pipelined chain through host[3] to host[4]; host[4] returns            *)
(* op:e-flush-probe-ack directly to host[2]; on ack receipt host[2] lifts *)
(* the embargo and ProcessHold drains the locally-buffered pending.       *)
(*                                                                         *)
(* Expected: EndToEndRefFIFO_MC PASSES.  The downstream sentinel queues   *)
(* behind any in-flight ref-1 traffic the probe encounters, so the ack    *)
(* only returns after every previously-pipelined send has reached         *)
(* host[4].                                                               *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC", "vatD", "vatE"}
HeadPeer == "vatA"
ChainLength == 4
MaxGifts == 3
MaxRefId == ChainLength + MaxGifts
NumMessages == 3
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
RoutingPolicy == "EJavaFlush"

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
TwoPartyWireDescsOnly_MC == PS!TwoPartyWireDescsOnly

\* Debug-only forced violation: see MC_EJavaFlush_3Chain.tla for the
\* rationale; identical predicate, also scoped to chain refs only.
NoSlowPathCompletion_MC ==
    ~( /\ Len(delivered) = NumMessages
       /\ \E p \in Peers : \E r \in 1..ChainLength :
            /\ r \in {ri \in 1..ChainLength : vats[p].refs[ri] # PS!EntryNone}
            /\ vats[p].refs[r].kind = "RemotePromise"
            /\ vats[p].refs[r].localResolution # PS!ResNone
            /\ vats[p].refs[r].fresh = FALSE
            /\ vats[p].refs[r].embargo = FALSE )

============================================================================
