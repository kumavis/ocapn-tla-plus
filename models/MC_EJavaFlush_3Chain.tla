---------------------- MODULE MC_EJavaFlush_3Chain ----------------------
(***************************************************************************)
(* EJavaFlush on a 3-hop chain.                                            *)
(*                                                                         *)
(*   Peers   = {vatA, vatB, vatC, vatD}                                    *)
(*   HeadPeer= vatA                                                        *)
(*   host    = << "vatB", "vatC", "vatD" >>  (terminal at vatD)            *)
(*                                                                         *)
(* On op:resolve at vatB (the only resolver under terminal-only            *)
(* propagation), the slow-path probe + ack ride end-to-end through         *)
(* vatC to vatD and back, guaranteeing that any pre-resolve forwards       *)
(* have been processed at vatD before vatB commits to the post-resolution  *)
(* path.  Expected to pass; the 3-chain is the smallest scope where a     *)
(* purely local "outbox empty" embargo signal would fail (see              *)
(* ../notes/flush-protocols.md section 10.3).  See                         *)
(* MC_EJavaFlush_4Chain for the Tribble-style race that remains a          *)
(* tracked limitation of the EJavaFlush family.                            *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC", "vatD"}
HeadPeer == "vatA"
ChainLength == 3
MaxGifts == 2
MaxRefId == ChainLength + MaxGifts
NumMessages == 3
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
EnableHandoffInitiate == FALSE
RoutingPolicy == "EJavaFlush"

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
    /\ host = <<"vatB", "vatC", "vatD">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

SpecDebug == Init /\ [][Next]_vars

TypeOK_MC == PS!TypeOK
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EventualDelivery_MC == PS!EventualDelivery
WireDescriptorContract_MC == PS!WireDescriptorContract
TwoPartyWireDescsOnly_MC == PS!TwoPartyWireDescsOnly

\* Debug-only forced violation: trips when the EJavaFlush slow path has
\* completed for at least one chain RemotePromise AND every send has
\* been delivered.  The slow-path completion is detected by the
\* post-ack signature on a RemotePromise (localResolution != ResNone,
\* fresh = FALSE because something was pipelined through it, embargo =
\* FALSE because the ack arrived and cleared it).  BFS picks the
\* shortest such path, so the rendered trace exercises pipelining ->
\* op:resolve -> probe -> ack -> ProcessHold drain.
\*
\* IMPORTANT: the existential is scoped to chain refs (r <= ChainLength)
\* only.  Handoff withdraw-promises (r > ChainLength) take the
\* isHandoffPw -> installNow branch in ReceiveNetwork, which writes
\* embargo := FALSE without ever sending a probe.  Letting them satisfy
\* the predicate causes BFS to render a happy-path 3PHO trace instead of
\* the intended EJavaFlush probe round-trip.  See
\* ../notes/path-changes.md section 3.6.
NoSlowPathCompletion_MC ==
    ~( /\ Len(delivered) = NumMessages
       /\ \E p \in Peers : \E r \in 1..ChainLength :
            /\ r \in {ri \in 1..ChainLength : vats[p].refs[ri] # PS!EntryNone}
            /\ vats[p].refs[r].kind = "RemotePromise"
            /\ vats[p].refs[r].localResolution # PS!ResNone
            /\ vats[p].refs[r].fresh = FALSE
            /\ vats[p].refs[r].embargo = FALSE )

============================================================================
