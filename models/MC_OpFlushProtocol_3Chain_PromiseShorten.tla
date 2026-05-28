--------------- MODULE MC_OpFlushProtocol_3Chain_PromiseShorten ---------------
(***************************************************************************)
(* 2-party inter-vat promise-to-promise shortening under OpFlushProtocol.  *)
(* Phase C extensions (notes/path-changes.md §3.10):                       *)
(*   - fireOpFlush gate accepts promise-shaped resolutions (AllListenersTwoParty)
*)
(*   - SendTargetFlushProbe uses Route() so the probe rides through chain   *)
(*     promise hops via the cascading LocalRef resolutions.                 *)
(*   - SendOpResolveAfterFlush also fires for promise-shaped resolutions.   *)
(*                                                                         *)
(* Topology: same as MC_EJavaFlush_3Chain_PromiseShorten (Phase C).        *)
(*   HeadPeer = vatA                                                       *)
(*   host[1]  = vatB   (LocalPromise p_1; listener {HeadPeer = vatA})      *)
(*   host[2]  = vatA   (LocalPromise p_2; listener {vatB})                 *)
(*   host[3]  = vatB   (LocalTarget T)                                     *)
(*                                                                         *)
(* OpFlushProtocol flow at vatB.refs[1] resolution:                        *)
(*   1. fireOpFlush fires (Phase C Promise gate); resolution =             *)
(*      ResRef(vatA, 2); flushPending = {vatA}; emit op:flush(1) on        *)
(*      channels[vatB][vatA].                                              *)
(*   2. vatA receives op:flush(1): refs[1].embargo = TRUE; emit            *)
(*      op:flush-ack(1) on channels[vatA][vatB] (queues behind any         *)
(*      previously-pipelined op:deliver-only sends from vatA).             *)
(*   3. vatB drains channels[vatA][vatB]: forwards each pipelined send    *)
(*      through refs[1].resolution -> refs[2] (RemotePromise embargo not  *)
(*      yet set) -> wire(vatA, 2).  Then receives op:flush-ack(1):        *)
(*      flushPending = {}.                                                 *)
(*   4. vatB SendTargetFlushProbe at refs[1] (Phase C: IsResolutionPromise *)
(*      gate, AllListenersTwoParty satisfied): probe rides via Route        *)
(*      through refs[2] -> wire(vatA, 2); originRefId = 1, refId = 2.     *)
(*      flushPhase = "out".                                                *)
(*   5. vatA receives probe(refId=2): refs[2] LocalPromise queue has the *)
(*      already-forwarded sends; route returns "queue" -> probe enqueued *)
(*      behind them.                                                       *)
(*   6. vatA ProcessPending drains refs[2].queue in FIFO: each send       *)
(*      delivers at refs[3] (RemoteTarget(vatB, 3)) via wire(vatB, 3);    *)
(*      finally probe forwarded via wire(vatB, 3) too.                    *)
(*   7. vatB delivers each send at refs[3] (LocalTarget); probe arrives,  *)
(*      Route -> deliver -> ApplyRoute emits OpEFlushProbeAck back to     *)
(*      originPeer = vatB on channels[vatB][vatB].                        *)
(*   8. vatB receives probe-ack: flushPhase = "acked".  Now               *)
(*      SendOpResolveAfterFlush fires at refs[1]: emit op:resolve(1,      *)
(*      desc:export-promise(2)) to vatA.                                  *)
(*   9. vatA receives op:resolve(1, desc:export-promise(2)): refs[1]      *)
(*      embargo clears (was set by op:flush at step 2);                   *)
(*      localResolution = ResRef(vatA, 2).  ProcessHold drains any        *)
(*      embargoed pending sends.                                          *)
(*                                                                         *)
(* Expected outcome: PASS.  Strong analog of                              *)
(* MC_EJavaFlush_3Chain_PromiseShorten -- the resolver-initiated probe    *)
(* (rather than listener-initiated) makes the same FIFO guarantee.       *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB"}
HeadPeer == "vatA"
ChainLength == 3
MaxGifts == 1
MaxRefId == ChainLength + MaxGifts
NumMessages == 2
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
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
TwoPartyWireDescsOnly_MC == PS!TwoPartyWireDescsOnly
GiftOneShot_MC == PS!GiftOneShot
GiftHasOneRecipient_MC == PS!GiftHasOneRecipient

============================================================================
