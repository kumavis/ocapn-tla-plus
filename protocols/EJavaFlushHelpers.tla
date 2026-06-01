----------------------- MODULE EJavaFlushHelpers -----------------------
(***************************************************************************)
(* EJavaFlush-specific code.                                                *)
(*                                                                         *)
(* The `EJavaFlush` routing policy is a faithful model of e-on-java's      *)
(* DelayedRedirector (see notes/flush-protocols.md §10).  This module       *)
(* owns:                                                                    *)
(*                                                                         *)
(*   - the wire ops the EJavaFlush slow path uses                          *)
(*       (`op:e-flush-probe`, `op:e-flush-probe-ack`).                     *)
(*   - the `fresh` sticky-bit helpers MarkRefNonFresh /                    *)
(*     ClearRemotePromiseFresh that maintain it on every wire send.       *)
(*   - the `ProcessHold` action that drains a RemotePromise.pending after  *)
(*     the probe-ack lifts the refid-scoped embargo.                       *)
(*                                                                         *)
(* The receive branches for op:e-flush-probe / op:e-flush-probe-ack and    *)
(* the embargoInstead branch of the op:resolve receive stay inline in     *)
(* spec/PromiseResolution.tla because they are part of the big            *)
(* ReceiveNetwork action body that dispatches across all policies.        *)
(*                                                                         *)
(* Other policies do not read or write the EJavaFlush-specific state      *)
(* fields (`embargo`, `fresh`, `pending`, `pipelinedListeners`); under     *)
(* those policies these fields stay at their constructor defaults.        *)
(***************************************************************************)

EXTENDS Common

----------------------------------------------------------------------------
(* Wire ops *)

(* EJavaFlush downstream sentinel (e-on-java's "second
   __whenMoreResolved", op-shaped).  Sent by the subscriber L on the wire
   to its current resolver when it receives an op:resolve that requires
   flushing; rides the same path as previously-pipelined op:deliver-only
   sends and queues behind them at every hop.

   Fields:
   - originPeer, originRefId: identify which subscriber and which of the
     originator's refs the ack releases.  These two fields are immutable
     as the probe is re-forwarded down the chain (they play the role of
     a return address, the same way op:listen carries its subscriber
     identity).
   - refId: the per-hop wire refId, mutated at each forward by ApplyRoute
     exactly like an op:deliver-only's refId is.  This is what makes the
     probe trace the same chain as user sends. *)
OpEFlushProbe(originPeer, originRefId, refId) ==
    [op |-> "op:e-flush-probe",
     originPeer |-> originPeer,
     originRefId |-> originRefId,
     refId |-> refId]

(* Probe ack: sent by the LocalTarget host (the terminus of the chain)
   directly back to the probe's originPeer.  Carries only the
   originRefId so the originator can match it.  The ack does not
   retrace the chain; it goes peer-to-peer on the direct channel from
   terminal -> originPeer (a normal use of one's own outbox). *)
OpEFlushProbeAck(originRefId) ==
    [op |-> "op:e-flush-probe-ack",
     originRefId |-> originRefId]

----------------------------------------------------------------------------
(* Fresh-bit helpers *)

(* ClearRemotePromiseFresh: this peer has pipelined on its local
   RemotePromise at refId r (e-on-java: myFreshFlag cleared on any send
   through the imported promise handler).  Per-peer write only. *)
ClearRemotePromiseFresh(self, refId, vats0) ==
    LET entry == vats0[self].refs[refId]
    IN IF /\ entry # EntryNone
          /\ entry.kind = "RemotePromise"
       THEN [vats0 EXCEPT ![self].refs[refId].fresh = FALSE]
       ELSE vats0

(* MarkRefNonFresh: locality-preserving sticky update on `fresh`.
   - route.tag = "wire": clear every local RemotePromise whose paired
     resolver wire is (route.peer, route.refId) — the import used for
     this outbound send.
   - route.tag = "hold": clear the RemotePromise at route.refId on self
     (local buffer while embargoed; still "used" per e-on-java).
   Per-peer write: only vats[self].refs. *)
MarkRefNonFresh(self, route, vats0) ==
    IF route.tag = "wire"
    THEN [vats0 EXCEPT
             ![self].refs =
                 [r \in RefIds |->
                     IF /\ vats0[self].refs[r] # EntryNone
                        /\ vats0[self].refs[r].kind = "RemotePromise"
                        /\ vats0[self].refs[r].resolverPeer = route.peer
                        /\ vats0[self].refs[r].resolverRefId = route.refId
                     THEN [vats0[self].refs[r] EXCEPT !.fresh = FALSE]
                     ELSE vats0[self].refs[r]]]
    ELSE IF /\ route.tag = "hold"
            /\ route.peer = self
       THEN ClearRemotePromiseFresh(self, route.refId, vats0)
    ELSE vats0

----------------------------------------------------------------------------
(* ListenersWitnessPipelined: at least one listener has pipelined on its
   local imported RemotePromise (e-on-java: !isFresh on that handler).
   The resolver learns this only from protocol traffic on the pair —
   pipelinedListeners on its LocalPromise — not by reading L's ref table.
   Gates EJavaFlush Phase C 3-party emission only; OpFlushProtocol does
   not use this witness.  See notes/path-changes.md §3.10. *)
ListenersWitnessPipelined(resolver, promiseRefId, listeners) ==
    LocalRef(resolver, promiseRefId).pipelinedListeners \intersect listeners
    # {}

(* Note: ProcessHold (the action that drains RemotePromise.pending after
   embargo lifts) stays in spec/PromiseResolution.tla because it
   references Route and ApplyRoute, which need to be visible to other
   actions (PeerSend, ResolverResolve, ProcessPending, ReceiveNetwork)
   that also live there. *)

============================================================================
