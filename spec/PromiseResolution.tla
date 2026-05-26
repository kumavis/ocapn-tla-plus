------------------------- MODULE PromiseResolution -------------------------
(***************************************************************************)
(* OCapN-flavored reference taxonomy with kind-discriminated dispatch.    *)
(*                                                                         *)
(* Per-peer refs[p][r] entries (one of):                                   *)
(*   LocalTarget    -- a sink owned by p                                   *)
(*   RemoteTarget   -- presence for someone else's LocalTarget             *)
(*   LocalPromise   -- p is the resolver; holds queue, listeners,         *)
(*                     resolution, flushPending, notified, flushPhase      *)
(*   RemotePromise  -- presence for someone else's LocalPromise; holds     *)
(*                     localResolution, embargo, pending, listenSent,      *)
(*                     fresh                                               *)
(*                                                                         *)
(* Routing is a single dispatch over refs[self][r].kind plus send-time     *)
(* recursion through any installed resolution                              *)
(* (LocalPromise.resolution / RemotePromise.localResolution) so a sender   *)
(* that has already learned a downstream target skips the resolved hop.   *)
(* See notes/path-changes.md for the precise taxonomy of path changes     *)
(* (promise resolution vs intra-vat promise shortening) that produce      *)
(* those installed resolutions in the first place.                         *)
(*                                                                         *)
(* RoutingPolicy:                                                          *)
(*   "NaivePromiseResolution"  listener installs localResolution on        *)
(*                              op:resolve; canonical naive 1-promise      *)
(*                              chain that violates because HeadPeer's     *)
(*                              pipelined ref-1 sends and HeadPeer's       *)
(*                              direct delivery race.                      *)
(*   "NoPromiseResolution"     no op:resolve ever fires (gated by policy); *)
(*                              every ref-1 send rides the wire through    *)
(*                              the chain.                                 *)
(*   "ShorteningUnsafe"        install localResolution immediately on      *)
(*                              op:resolve; no flush; race on long chains. *)
(*                              ("Shortening" here is OCapN-colloquial    *)
(*                              for "the act of changing a ref's route";  *)
(*                              this policy commits to the new path with   *)
(*                              no synchronisation against the old one,    *)
(*                              regardless of which kind of path change    *)
(*                              -- see notes/path-changes.md.)             *)
(*   "EJavaFlush"              Faithful model of e-on-java's              *)
(*                              DelayedRedirector mechanism.  On           *)
(*                              op:resolve(r, _) at L:                     *)
(*                                FAST PATH: refs[L][r].fresh OR           *)
(*                                  msg.value.peer = resolverPeer (same    *)
(*                                  connection) -> install immediately.    *)
(*                                SLOW PATH: stage localResolution, set    *)
(*                                  embargo = TRUE, emit op:e-flush-probe  *)
(*                                  on the wire to the current resolver.   *)
(*                                  The probe rides the same path as       *)
(*                                  previously-pipelined deliver-only      *)
(*                                  sends and triggers an end-to-end ack   *)
(*                                  back to L.  On op:e-flush-probe-ack    *)
(*                                  receipt, lift embargo and let          *)
(*                                  pending drain.  See the "EJavaFlush    *)
(*                                  protocol" documentation block below    *)
(*                                  for source-link citations and the      *)
(*                                  locality contract.                     *)
(*                              The Tribble four-way scenario is a known   *)
(*                              limitation inherited from the underlying   *)
(*                              protocol; see "OpFlushProtocol" for an     *)
(*                              alternative design that addresses it.      *)
(*   "OpFlushProtocol"         resolver-initiated alternative (Ridley     *)
(*                              proposal, ocapn#11).  ResolverResolve      *)
(*                              sends op:flush(r) to all listeners         *)
(*                              instead of op:resolve.  Locality-clean:    *)
(*                                1. Listener L receives op:flush,         *)
(*                                   atomically sets embargo on its        *)
(*                                   RemotePromise AND enqueues            *)
(*                                   op:flush-ack on the same channel      *)
(*                                   back to the resolver R.  Because      *)
(*                                   channels[L][R] is p2p FIFO, the       *)
(*                                   ack queues behind any of L's          *)
(*                                   pre-flush op:deliver-only sends, so   *)
(*                                   R is guaranteed to have processed     *)
(*                                   them all before dequeuing the ack.    *)
(*                                   No "is my outbox empty?" inference    *)
(*                                   is needed; FIFO does the work.        *)
(*                                2. Once R has received op:flush-ack      *)
(*                                   from every listener AND R's own       *)
(*                                   LocalPromise.queue is drained, R      *)
(*                                   emits op:e-flush-probe on its own     *)
(*                                   outbox to the eventual target via     *)
(*                                   its RemoteTarget                      *)
(*                                   (SendTargetFlushProbe).  The probe    *)
(*                                   rides channels[R][target] AFTER all   *)
(*                                   of R's previously-forwarded           *)
(*                                   op:deliver-only sends.                *)
(*                                3. Target receives op:e-flush-probe at   *)
(*                                   its LocalTarget terminus and emits    *)
(*                                   op:e-flush-probe-ack back to R on     *)
(*                                   channels[target][R].                  *)
(*                                4. R receives op:e-flush-probe-ack;      *)
(*                                   the LocalPromise's flushPhase         *)
(*                                   transitions "out" -> "acked".  Only   *)
(*                                   then does SendOpResolveAfterFlush     *)
(*                                   fire and emit op:resolve to listeners.*)
(*                              No action infers downstream delivery from  *)
(*                              "my outbox is empty"; every state          *)
(*                              transition is driven by an explicit        *)
(*                              protocol message (op:flush, op:flush-ack,  *)
(*                              op:e-flush-probe, op:e-flush-probe-ack).   *)
(*                              The probe + ack mechanism is shared with   *)
(*                              EJavaFlush; only the originator's entry    *)
(*                              kind (RemotePromise vs LocalPromise)       *)
(*                              differs in the ack-receive dispatch.       *)
(***************************************************************************)

EXTENDS Naturals, Sequences, TLC, References, Network, PeerState

VARIABLE lastAction

CONSTANT
    NumMessages,
    RoutingPolicy,
    DebugTrace,
    EmptyInitialListeners,
    EnableDynamicListen,
    EnableHandoff

ASSUME NumMessages \in Nat \ {0}
ASSUME RoutingPolicy \in {
    "NaivePromiseResolution",
    "NoPromiseResolution",
    "ShorteningUnsafe",
    "EJavaFlush",
    "OpFlushProtocol"
}
ASSUME DebugTrace \in BOOLEAN
ASSUME EmptyInitialListeners \in BOOLEAN
ASSUME EnableDynamicListen \in BOOLEAN
ASSUME EnableHandoff \in BOOLEAN

----------------------------------------------------------------------------
(* Wire messages. *)

OpDeliverOnly(sender, sentOnRef, seq, refId) ==
    [op |-> "op:deliver-only",
     sender |-> sender,
     sentOnRef |-> sentOnRef,
     seq |-> seq,
     refId |-> refId]

OpResolve(targetRefId, value) ==
    [op |-> "op:resolve",
     targetRefId |-> targetRefId,
     value |-> value]

OpFlush(refId) ==
    [op |-> "op:flush",
     refId |-> refId]

OpFlushAck(refId) ==
    [op |-> "op:flush-ack",
     refId |-> refId]

(* v0 globally-shared refIds: subscriber and resolver name the same logical
   refId, so op:listen carries only one. *)
OpListen(refId) ==
    [op |-> "op:listen",
     refId |-> refId]

(* EJavaFlush downstream sentinel (e-on-java's "second
   __whenMoreResolved", op-shaped).  Sent by the subscriber L on the wire
   to its current resolver when it receives an op:resolve that requires
   flushing; rides the same path as previously-pipelined op:deliver-only
   sends and queues behind them at every hop.

   - originPeer / originRefId: where the ack must travel back to and
     which of the originator's refs the ack releases.  These two fields
     are immutable as the probe is re-forwarded down the chain (they
     play the role of a return address, the same way op:listen carries
     its subscriber identity).  Used by both EJavaFlush (originator is
     a subscriber holding a RemotePromise; ack lifts that promise's
     embargo) and OpFlushProtocol (originator is a resolver holding a
     LocalPromise; ack advances that promise's flushPhase from "out"
     to "acked").
   - refId: the per-hop wire refId, mutated at each forward by
     ApplyRoute exactly like an op:deliver-only's refId is.  This is
     what makes the probe trace the same chain as user sends. *)
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

(* Opaque 3PHO wire messages. *)

(* op:deposit-gift: gifter -> targetHost.  Pre-authorize a withdraw.  The
   gift slot is keyed by (gifter, giftId) on the target host.  The pw
   refId is carried so the target host can pre-mint a LocalPromise at pw
   into which pipelined sends on the recipient's RemotePromise(pw) can
   queue before the recipient's op:withdraw-gift arrives. *)
OpDepositGift(giftId, recipient, targetLocalRefId, pw) ==
    [op |-> "op:deposit-gift",
     giftId |-> giftId,
     recipient |-> recipient,
     targetLocalRefId |-> targetLocalRefId,
     pw |-> pw]

(* op:withdraw-gift: recipient -> targetHost.  Claim the gift; on success
   the target host mints a LocalPromise at withdrawPromiseRefId and resolves
   it to the deposited target. *)
OpWithdrawGift(giftId, gifter, withdrawPromiseRefId) ==
    [op |-> "op:withdraw-gift",
     giftId |-> giftId,
     gifter |-> gifter,
     withdrawPromiseRefId |-> withdrawPromiseRefId]

(* Resolution descriptor carried in op:resolve.value.
   - desc:remote-target carries a plain (peer, refId) and is what the
     listener installs as localResolution.
   - desc:handoff-give is the opaque 3PHO introduction: gifter, targetHost,
     and giftId; the recipient mints a withdraw-promise pw using its own
     refId namespace, treats pw as a RemotePromise to targetHost, and learns
     the actual ref only later when the target host's op:resolve carrying
     desc:remote-target on pw arrives. *)

DescRemoteTarget(peer, refId) ==
    [desc |-> "desc:remote-target",
     peer |-> peer,
     refId |-> refId]

(* pw is the new refId the gifter allocates for the recipient's withdraw-
   promise.  Carrying it inside the descriptor decouples it from
   targetRefId: targetRefId may be (a) an existing RemotePromise at the
   recipient (chain case -- the recipient installs that promise's
   localResolution pointing at pw) or (b) pw itself (standalone case --
   the recipient mints a brand-new ref). *)

DescHandoffGive(gifter, targetHost, giftId, pw) ==
    [desc |-> "desc:handoff-give",
     gifter |-> gifter,
     targetHost |-> targetHost,
     giftId |-> giftId,
     pw |-> pw]

DescValues ==
    {DescRemoteTarget(p, r) : p \in Peers, r \in RefIds}
    \cup {DescHandoffGive(g, h, i, w) :
            g \in Peers, h \in Peers, i \in GiftIds, w \in RefIds}

Messages ==
    { OpDeliverOnly(HeadPeer, 1, n, r) :
        n \in 1..NumMessages, r \in RefIds }
    \cup { OpResolve(r, v) : r \in RefIds, v \in DescValues }
    \cup { OpFlush(r) : r \in RefIds }
    \cup { OpFlushAck(r) : r \in RefIds }
    \cup { OpListen(r) : r \in RefIds }
    \cup { OpEFlushProbe(o, r0, r) :
            o \in Peers, r0 \in RefIds, r \in RefIds }
    \cup { OpEFlushProbeAck(r0) : r0 \in RefIds }
    \cup { OpDepositGift(i, q, r, pw) :
            i \in GiftIds, q \in Peers, r \in RefIds, pw \in RefIds }
    \cup { OpWithdrawGift(i, g, r) :
            i \in GiftIds, g \in Peers, r \in RefIds }

DeliveredEntry ==
    [sender : Peers, ref : {1}, seq : 1..NumMessages]

----------------------------------------------------------------------------
(* Chain-listener function: who listens on which LocalPromise.  Pinned at
   chain bootstrap (the upstream peer subscribes to the downstream
   promise).  Gated by policy: NoPromiseResolution clears all listeners so
   no op:resolve ever fires. *)

ChainListenersFor[r \in ChainRefs] ==
    IF EmptyInitialListeners THEN {}
    ELSE IF RoutingPolicy = "NoPromiseResolution" THEN {}
    ELSE IF r = TerminalPos THEN {}
    ELSE IF r = 1 THEN {HeadPeer}
    ELSE {host[r - 1]}

vars ==
    << channels, host, refs, sent, delivered,
       gifts, nextGiftId, nextRefId, lastAction >>

----------------------------------------------------------------------------
(* Initialization: pin host, build refs from MkChainRefs(host, listeners). *)

PromiseResolutionInit ==
    /\ host \in [ChainRefs -> Peers]
    /\ refs = MkChainRefs(host, ChainListenersFor)
    /\ NetworkInit
    /\ PeerStateInit
    /\ lastAction = [name |-> "init"]

----------------------------------------------------------------------------
(* Routing dispatch.  Returns one of:
     [tag |-> "deliver", peer, refId]      apply locally (LocalTarget sink)
     [tag |-> "wire",    peer, refId]      append op:deliver-only on
                                           channels[self][peer] with refId
     [tag |-> "queue",   peer, refId]      enqueue into local LocalPromise.queue
     [tag |-> "hold",    peer, refId]      enqueue into local RemotePromise.pending
                                           (OpFlushProtocol embargo)
     [tag |-> "deadEnd"]                   unallocated; shouldn't happen *)

RECURSIVE Route(_, _)
Route(self, r) ==
    LET entry == refs[self][r]
    IN IF entry = EntryNone THEN [tag |-> "deadEnd"]
       ELSE IF entry.kind = "LocalTarget"
            THEN [tag |-> "deliver", peer |-> self, refId |-> r]
       ELSE IF entry.kind = "RemoteTarget"
            THEN [tag |-> "wire",
                  peer |-> entry.targetPeer,
                  refId |-> entry.targetRefId]
       ELSE IF entry.kind = "LocalPromise"
            THEN IF \/ entry.resolution = ResNone
                    \/ Len(entry.queue) > 0
                 THEN [tag |-> "queue", peer |-> self, refId |-> r]
                 ELSE Route(self, entry.resolution.refId)
       ELSE (* RemotePromise *)
            \* EJavaFlush and OpFlushProtocol both buffer new sends locally
            \* in pending while the embargo is up.  For EJavaFlush this
            \* models e-on-java's `myOptResolver.resolve(p_new)` step that
            \* redirects the proxy to a fresh local promise; for
            \* OpFlushProtocol it's the resolver-initiated equivalent.
            \* Either way, once a pending entry exists or embargo is set,
            \* subsequent sends queue behind whatever's already there.
            IF /\ RoutingPolicy \in {"EJavaFlush", "OpFlushProtocol"}
               /\ \/ entry.embargo
                  \/ Len(entry.pending) > 0
            THEN [tag |-> "hold", peer |-> self, refId |-> r]
            ELSE IF entry.localResolution = ResNone
                 THEN [tag |-> "wire",
                       peer |-> entry.resolverPeer,
                       refId |-> entry.resolverRefId]
                 ELSE Route(self, entry.localResolution.refId)

(* ------------------------------------------------------------------------
   EJavaFlush protocol (faithful to e-on-java's DelayedRedirector).
   ------------------------------------------------------------------------
   This block documents the locality contract and the two-path dispatch
   that the "EJavaFlush" policy implements.  See the in-spec wire
   constructors OpEFlushProbe / OpEFlushProbeAck above, the op:resolve
   receive branch in ReceiveNetwork further below, and the dedicated
   op:e-flush-probe / op:e-flush-probe-ack ReceiveNetwork branches.

   Source citations (permalinked at kpreid/e-on-java@a0b3b59):
   [1] RemotePromiseHandler.isFresh sticky bit (per-RemotePromise flag,
       cleared first time anything is pipelined through the proxy):
       https://github.com/kpreid/e-on-java/blob/a0b3b599cf267b3138eea5f5fb83f27cebd28373/src/jsrc/net/captp/jcomm/RemotePromiseHandler.java#L40-L66
   [2] DelayedRedirector.run: the dispatch on incoming redirection that
       picks fast vs slow path:
       https://github.com/kpreid/e-on-java/blob/a0b3b599cf267b3138eea5f5fb83f27cebd28373/src/jsrc/org/erights/e/elib/ref/DelayedRedirector.java#L50-L107
   [3] Fast-path predicate (isFresh OR sameConnection OR isDeepFrozen):
       https://github.com/kpreid/e-on-java/blob/a0b3b599cf267b3138eea5f5fb83f27cebd28373/src/jsrc/org/erights/e/elib/ref/DelayedRedirector.java#L63
   [4] Slow-path body (sends a SECOND __whenMoreResolved downstream on
       the existing proxy, then resolves the proxy to a new local
       promise that will be filled when the ack returns):
       https://github.com/kpreid/e-on-java/blob/a0b3b599cf267b3138eea5f5fb83f27cebd28373/src/jsrc/org/erights/e/elib/ref/DelayedRedirector.java#L88
   [5] kumavis summary of e-on-java's mechanism on ocapn#11:
       https://github.com/ocapn/ocapn/issues/11#issuecomment-4524938147
   [6] EProxyHandler interface (sameConnection / isFresh contract):
       https://github.com/kpreid/e-on-java/blob/a0b3b599cf267b3138eea5f5fb83f27cebd28373/src/jsrc/org/erights/e/elib/ref/EProxyHandler.java
   [7] Tribble 4-way caveat (ocapn#11):
       https://github.com/ocapn/ocapn/issues/11#issuecomment-1492469923

   Mechanism in this spec
   ----------------------
   When subscriber L receives op:resolve(r, desc:remote-target(p,r')) on
   a RemotePromise refs[L][r]:

   FAST PATH (no flush) -- locally decidable at L, no remote read:
     fastPath := refs[L][r].fresh \/ msg.value.peer = refs[L][r].resolverPeer
     If fastPath, set localResolution = ResRef(p, r'); embargo stays
     FALSE.  Subsequent sends route directly through the installed
     localResolution via the normal Route recursion.

       - `fresh` (per-RemotePromise sticky bit defined in
         lib/References.tla; mirrors e-on-java's isFresh [1]): TRUE
         while nothing has ever been pipelined through this proxy;
         cleared FALSE by ApplyRoute the first time route.tag = "wire"
         is taken with this RemotePromise as the wire source
         (MarkRefNonFresh).  Once fresh is FALSE it stays FALSE, even
         after the local outbox drains.  This is what distinguishes
         the e-on-java semantic from the strictly-weaker "is anything
         currently in my outbox" heuristic.
       - `sameConnection`: the new target is in the same vat as the
         current resolver.  Any new send arrives behind prior sends by
         p2p FIFO on that single wire, so no flush is needed (e-on-java
         [3]; DeepFrozen target is out of scope for this spec).

   SLOW PATH (downstream flush + ack) -- L sends one protocol message,
   awaits one protocol message:
     embargoInstead := EJavaFlush /\ ~fastPath /\ ~isHandoffPw
     If embargoInstead: set localResolution = ResRef(p, r') (staged);
     set embargo = TRUE; append OpEFlushProbe(L, r, resolverRefId) to
     L's own outbox channels[L][resolverPeer].

     The probe rides the same wire as previously-pipelined deliver-only
     sends and is re-forwarded by every intermediate hop exactly like a
     deliver-only would be (probe routing == deliver-only routing, see
     the op:e-flush-probe ReceiveNetwork branch).  At the eventual
     LocalTarget host X, ApplyRoute (polymorphic on msg.op) emits
     OpEFlushProbeAck(originRefId) on X's own outbox channels[X][L].
     The ack travels directly back to L without retracing the chain --
     it carries originRefId so L can match it without any side-channel
     state, and originPeer (carried in the probe) is the only piece
     of routing information X needs.

     While embargo is set, Route returns "hold" for L's new sends, so
     they buffer locally in refs[L][r].pending (mirroring e-on-java's
     "resolve myOptResolver to p_new" step [4] -- p_new acts as the
     local buffer).  On ack receipt, the op:e-flush-probe-ack branch
     clears embargo; ProcessHold then drains pending to the now-
     committed post-resolution path.

   Locality contract (this is the principle that motivates the
   downstream sentinel in the first place)
   -------------------------------------------------------------------
   No action under EJavaFlush reads any peer's state other than its
   own.  No action infers downstream delivery from "my outbox is
   empty"; the only signal that releases the embargo is the ack
   message itself.  The `fresh` bit is per-peer per-ref local state
   updated in lockstep with the local send that clears it.
   sameConnection compares two fields both held by L.  The probe and
   ack are ordinary protocol messages with their routing information
   embedded inline (return address on the probe, refId match on the
   ack).

   Tribble 4-way limitation
   ------------------------
   Even a faithful DelayedRedirector implementation does not handle
   the four-party scenario where intermediate hops are themselves
   concurrently undergoing a path change [7].  The probe rides a
   single linear path; parallel path changes on the same path can
   race past it.  This spec inherits that limitation by design (we
   are modelling e-on-java faithfully, not fixing it).  The
   "OpFlushProtocol" policy is an exploration of a different design
   (resolver-initiated, ocapn#11 RidleyWrites) that the proposal
   claims addresses the four-party case; the spec currently models
   only its three-party form.  Reproducing the four-way race in a
   model check additionally requires the distributed-inter-vat
   promise-shortening machinery (see notes/path-changes.md §3.1).
   ------------------------------------------------------------------------ *)

(* DeliveredRecord: canonical (sender, ref, seq) record appended to
   `delivered` when an op:deliver-only reaches a LocalTarget sink. *)
DeliveredRecord(msg) ==
    [sender |-> msg.sender,
     ref |-> msg.sentOnRef,
     seq |-> msg.seq]

(* MarkRefNonFresh: locality-preserving sticky update on `fresh`.  When a
   wire route is taken at peer p, the originating RemotePromise on p
   (the one whose (resolverPeer, resolverRefId) matches the wire target)
   has anything-ever-pipelined-through-me set; we clear `fresh` to FALSE
   on all such RemotePromise entries.  Pairing usually means at most one
   match; we tolerate more.

   This is a per-peer operation: peer p only mutates its own refs[p][_]
   in response to its own send. *)
MarkRefNonFresh(p, route, refs0) ==
    [refs0 EXCEPT
        ![p] =
            [r \in RefIds |->
                IF /\ refs0[p][r] # EntryNone
                   /\ refs0[p][r].kind = "RemotePromise"
                   /\ refs0[p][r].resolverPeer = route.peer
                   /\ refs0[p][r].resolverRefId = route.refId
                THEN [refs0[p][r] EXCEPT !.fresh = FALSE]
                ELSE refs0[p][r]]]

(* ApplyRoute: layer the route.tag effects atop a starting
   (ch0, refs0, delivered0) triple, returning a record with the next
   channels / refs / delivered.  Source-side mutations (channel head
   dequeue, LocalPromise.queue tail, RemotePromise.pending tail) must
   already be baked into ch0 / refs0 by the caller.  The caller is also
   responsible for guarding route.tag with the allowed subset for its
   specific call site (some sites disallow "hold").

   ApplyRoute is polymorphic on msg.op for the terminal "deliver" tag:
     - op:deliver-only at a LocalTarget       -> append delivery record.
     - op:e-flush-probe at a LocalTarget      -> emit OpEFlushProbeAck
       back to the probe's originPeer on p's own outbox.  The ack is
       the end-to-end signal that all messages routed before the probe
       on this chain have been processed at the terminal.  The
       originPeer field on the probe carries the originator's identity
       the same way a return address does, so terminal X does not need
       any prior knowledge of the originator.
   For non-terminal route tags (wire/queue/hold) the message is
   forwarded uniformly regardless of its op; the polymorphism on op
   only matters at the sink. *)
ApplyRoute(p, route, msg, ch0, refs0, delivered0) ==
    LET m2 == [msg EXCEPT !.refId = route.refId]
        refs1 ==
            IF route.tag = "wire"
            THEN MarkRefNonFresh(p, route, refs0)
            ELSE refs0
    IN CASE route.tag = "deliver"
            -> IF msg.op = "op:deliver-only"
               THEN [channels  |-> ch0,
                     refs      |-> refs1,
                     delivered |-> Append(delivered0, DeliveredRecord(msg))]
               ELSE \* op:e-flush-probe terminates: emit ack to originPeer
                    [channels  |->
                        NetworkAppend(ch0, p, msg.originPeer,
                            OpEFlushProbeAck(msg.originRefId)),
                     refs      |-> refs1,
                     delivered |-> delivered0]
         [] route.tag = "wire"
            -> [channels  |-> NetworkAppend(ch0, p, route.peer, m2),
                refs      |-> refs1,
                delivered |-> delivered0]
         [] route.tag = "queue"
            -> [channels  |-> ch0,
                refs      |->
                    [refs1 EXCEPT
                        ![route.peer][route.refId].queue =
                            Append(@, msg)],
                delivered |-> delivered0]
         [] route.tag = "hold"
            -> [channels  |-> ch0,
                refs      |->
                    [refs1 EXCEPT
                        ![route.peer][route.refId].pending =
                            Append(@, msg)],
                delivered |-> delivered0]

----------------------------------------------------------------------------
Mark(rec) ==
    IF DebugTrace THEN lastAction' = rec ELSE UNCHANGED lastAction

HandoffVarsUnchanged ==
    UNCHANGED << gifts, nextGiftId, nextRefId >>

----------------------------------------------------------------------------
(* PeerSend (HeadPeer only): originates a fresh op:deliver-only on ref 1. *)

PeerSend ==
    LET sender == HeadPeer
        seqN == sent + 1
        route == Route(sender, 1)
        msg == OpDeliverOnly(sender, 1, seqN, route.refId)
        after == ApplyRoute(sender, route, msg, channels, refs, delivered)
    IN
        /\ sent < NumMessages
        /\ route.tag \in {"deliver", "wire", "queue", "hold"}
        /\ sent' = seqN
        /\ channels' = after.channels
        /\ refs' = after.refs
        /\ delivered' = after.delivered
        /\ UNCHANGED << host >>
        /\ HandoffVarsUnchanged
        /\ Mark([name |-> "PeerSend",
                 actor |-> sender,
                 seq |-> seqN,
                 ref |-> 1,
                 tag |-> route.tag,
                 toPeer |-> route.peer,
                 toRefId |-> route.refId])

----------------------------------------------------------------------------
(* ProcessPending: drain one message from a resolved LocalPromise.queue. *)

ProcessPending ==
    \E p \in Peers : \E r \in DOMrefs(p) :
        /\ refs[p][r].kind = "LocalPromise"
        /\ refs[p][r].resolution # ResNone
        /\ Len(refs[p][r].queue) > 0
        /\ LET msg == Head(refs[p][r].queue)
               restQueue == Tail(refs[p][r].queue)
               nextR == refs[p][r].resolution.refId
               route == Route(p, nextR)
               refsSrc == [refs EXCEPT ![p][r].queue = restQueue]
               after == ApplyRoute(p, route, msg, channels, refsSrc, delivered)
           IN
              /\ route.tag \in {"deliver", "wire", "queue", "hold"}
              /\ channels' = after.channels
              /\ refs' = after.refs
              /\ delivered' = after.delivered
              /\ UNCHANGED << host, sent >>
              /\ HandoffVarsUnchanged
              /\ Mark([name |-> "ProcessPending",
                       actor |-> p,
                       fromRefId |-> r,
                       nextRefId |-> nextR,
                       tag |-> route.tag,
                       op |-> msg.op,
                       seq |-> IF "seq" \in DOMAIN msg
                               THEN msg.seq
                               ELSE 0])

----------------------------------------------------------------------------
(* ProcessHold: drain one message from a RemotePromise.pending whose
   embargo has been lifted (OpFlushProtocol: after op:resolve installs
   localResolution and clears embargo). *)

ProcessHold ==
    \E p \in Peers : \E r \in DOMrefs(p) :
        /\ refs[p][r].kind = "RemotePromise"
        /\ ~refs[p][r].embargo
        /\ Len(refs[p][r].pending) > 0
        /\ LET msg == Head(refs[p][r].pending)
               restPending == Tail(refs[p][r].pending)
               route ==
                   IF refs[p][r].localResolution # ResNone
                   THEN Route(p, refs[p][r].localResolution.refId)
                   ELSE [tag |-> "wire",
                         peer |-> refs[p][r].resolverPeer,
                         refId |-> refs[p][r].resolverRefId]
               refsSrc == [refs EXCEPT ![p][r].pending = restPending]
               after == ApplyRoute(p, route, msg, channels, refsSrc, delivered)
           IN
              \* Disallow "hold" here: if localResolution chains into another
              \* embargoed RemotePromise we keep the action disabled (the
              \* outer embargo will lift first).
              /\ route.tag \in {"deliver", "wire", "queue"}
              /\ channels' = after.channels
              /\ refs' = after.refs
              /\ delivered' = after.delivered
              /\ UNCHANGED << host, sent >>
              /\ HandoffVarsUnchanged
              /\ Mark([name |-> "ProcessHold",
                       actor |-> p,
                       refId |-> r,
                       tag |-> route.tag,
                       op |-> msg.op,
                       seq |-> IF "seq" \in DOMAIN msg
                               THEN msg.seq
                               ELSE 0])

----------------------------------------------------------------------------
(* ResolverResolve: peer p (= host[r]) resolves its LocalPromise at refId r.
   Behavior depends on the resolution's kind (Target vs Promise),
   RoutingPolicy, and listener set. *)

ChainResolutionFor(r) ==
    IF r >= TerminalPos THEN ResNone
    ELSE ResRef(host[r + 1], r + 1)

IsResolutionTarget(p, res) ==
    /\ res # ResNone
    /\ res.refId \in DOMrefs(p)
    /\ refs[p][res.refId].kind \in {"LocalTarget", "RemoteTarget"}

ResolveValueFor(p, res) ==
    LET targetEntry == refs[p][res.refId]
    IN IF targetEntry.kind = "LocalTarget"
       THEN DescRemoteTarget(p, res.refId)
       ELSE \* RemoteTarget
            DescRemoteTarget(targetEntry.targetPeer, targetEntry.targetRefId)

(* Append `msg` to channels[p][q] for each q in `qs`. *)
AppendToMany(ch, p, qs, msg) ==
    [ch EXCEPT ![p] =
        [q \in Peers |->
            IF q \in qs THEN Append(ch[p][q], msg) ELSE ch[p][q]]]

ResolverResolve ==
    \E p \in Peers : \E r \in DOMrefs(p) :
        /\ refs[p][r].kind = "LocalPromise"
        /\ refs[p][r].resolution = ResNone
        /\ r \in ChainRefs   \* handoff LocalPromises (pw > ChainLength) are
                              \* resolved exclusively by ReceiveOpWithdrawGift
        /\ host[r] = p
        /\ LET res == ChainResolutionFor(r)
               listeners == refs[p][r].listeners
               isTarget == IsResolutionTarget(p, res)
               fireOpResolveNow ==
                   /\ isTarget
                   /\ listeners # {}
                   /\ RoutingPolicy \in
                          {"NaivePromiseResolution",
                           "ShorteningUnsafe",
                           "EJavaFlush"}
               fireOpFlush ==
                   /\ isTarget
                   /\ listeners # {}
                   /\ RoutingPolicy = "OpFlushProtocol"
               value ==
                   IF isTarget THEN ResolveValueFor(p, res) ELSE ResNone
           IN
              /\ res # ResNone
              /\ (CASE fireOpResolveNow
                       -> /\ refs' =
                              [refs EXCEPT
                                  ![p][r].resolution = res,
                                  ![p][r].notified = TRUE]
                          /\ channels' =
                              AppendToMany(channels, p, listeners,
                                  OpResolve(r, value))
                   [] fireOpFlush
                       -> /\ refs' =
                              [refs EXCEPT
                                  ![p][r].resolution = res,
                                  ![p][r].flushPending = listeners]
                          /\ channels' =
                              AppendToMany(channels, p, listeners,
                                  OpFlush(r))
                   [] OTHER
                       -> /\ refs' =
                              [refs EXCEPT ![p][r].resolution = res]
                          /\ UNCHANGED channels)
              /\ UNCHANGED << host, sent, delivered >>
              /\ HandoffVarsUnchanged
              /\ Mark([name |-> "ResolverResolve",
                       actor |-> p,
                       refId |-> r,
                       resKind |-> IF isTarget THEN "Target" ELSE "Promise",
                       notified |-> fireOpResolveNow,
                       flushed |-> fireOpFlush])

----------------------------------------------------------------------------
(* SendTargetFlushProbe: at resolver R holding a target-bearing            *)
(* LocalPromise whose listeners have all acked the op:flush round (i.e.    *)
(* flushPending = {}), emit an op:e-flush-probe through R's chain to the   *)
(* eventual target.  The probe rides channels[R][targetPeer] AFTER all of  *)
(* R's previously-forwarded op:deliver-only sends (channel FIFO); the      *)
(* ack returns directly from target -> R and advances R's LocalPromise     *)
(* flushPhase from "out" to "acked" so SendOpResolveAfterFlush can fire.   *)
(*                                                                         *)
(* Preconditions:                                                          *)
(*   - resolution set, target-bearing                                      *)
(*   - flushPending = {}     (all listener acks already received)          *)
(*   - notified = FALSE      (op:resolve not yet sent)                     *)
(*   - flushPhase = "idle"   (probe not yet sent for this round)           *)
(*   - resolver's own LocalPromise.queue is empty (all pre-flush local    *)
(*     pipelined sends forwarded)                                          *)
(*                                                                         *)
(* This action is enabled exactly once per resolution: it transitions      *)
(* flushPhase "idle" -> "out" (or directly "idle" -> "acked" for the      *)
(* local-target shortcut), and the receive of op:e-flush-probe-ack         *)
(* transitions "out" -> "acked", which enables SendOpResolveAfterFlush. *)

SendTargetFlushProbe ==
    \E p \in Peers : \E r \in DOMrefs(p) :
        /\ RoutingPolicy = "OpFlushProtocol"
        /\ refs[p][r].kind = "LocalPromise"
        /\ refs[p][r].resolution # ResNone
        /\ IsResolutionTarget(p, refs[p][r].resolution)
        /\ refs[p][r].flushPending = {}
        /\ ~refs[p][r].notified
        /\ refs[p][r].flushPhase = "idle"
        /\ Len(refs[p][r].queue) = 0
        /\ LET res == refs[p][r].resolution
               targetEntry == refs[p][res.refId]
               targetPeer ==
                   IF targetEntry.kind = "RemoteTarget"
                   THEN targetEntry.targetPeer
                   ELSE p
               targetRefId ==
                   IF targetEntry.kind = "RemoteTarget"
                   THEN targetEntry.targetRefId
                   ELSE res.refId
               probe == OpEFlushProbe(p, r, targetRefId)
           IN
              \* Local target (p itself is the target host): no
              \* cross-vat flush needed, so the transition is "idle"
              \* -> "acked" without any wire message.  Remote target:
              \* emit the probe on p's own outbox to targetPeer and
              \* transition "idle" -> "out"; the ack receive below
              \* transitions "out" -> "acked".
              (CASE targetPeer = p
                       -> /\ refs' =
                              [refs EXCEPT
                                  ![p][r].flushPhase = "acked"]
                          /\ UNCHANGED channels
                          /\ Mark([name |-> "SendTargetFlushProbe",
                                   actor |-> p, refId |-> r,
                                   targetPeer |-> p,
                                   phase |-> "acked"])
                 [] OTHER
                       -> /\ refs' =
                              [refs EXCEPT
                                  ![p][r].flushPhase = "out"]
                          /\ channels' =
                              NetworkAppend(channels, p, targetPeer, probe)
                          /\ Mark([name |-> "SendTargetFlushProbe",
                                   actor |-> p, refId |-> r,
                                   targetPeer |-> targetPeer,
                                   phase |-> "out"]))
        /\ UNCHANGED << host, sent, delivered >>
        /\ HandoffVarsUnchanged

----------------------------------------------------------------------------
(* Send op:resolve to listeners after the resolver-to-target flush probe   *)
(* round-trip has completed.  Preconditions:                               *)
(*   - resolution set, target-bearing                                      *)
(*   - flushPending = {}     (all listener acks received)                  *)
(*   - notified = FALSE      (op:resolve not yet sent)                     *)
(*   - flushPhase = "acked"  (target acked our probe, so all of our        *)
(*                            forwards on channels[R][target] have been    *)
(*                            processed at target)                         *)
(*                                                                         *)
(* The combination of these preconditions, together with the listeners'    *)
(* embargo + flush-ack handshake, gives us an end-to-end protocol-level    *)
(* guarantee that no pre-flush sends can race the post-flush direct path:  *)
(* every state transition is driven by an explicit protocol message; no    *)
(* peer reads another peer's channel state.  See                           *)
(* notes/flush-protocols.md section 9 for the full locality contract. *)

SendOpResolveAfterFlush ==
    \E p \in Peers : \E r \in DOMrefs(p) :
        /\ RoutingPolicy = "OpFlushProtocol"
        /\ refs[p][r].kind = "LocalPromise"
        /\ refs[p][r].resolution # ResNone
        /\ IsResolutionTarget(p, refs[p][r].resolution)
        /\ refs[p][r].flushPending = {}
        /\ refs[p][r].flushPhase = "acked"
        /\ ~refs[p][r].notified
        /\ Len(refs[p][r].queue) = 0
        /\ LET res == refs[p][r].resolution
               value == ResolveValueFor(p, res)
               listeners == refs[p][r].listeners
           IN
              /\ refs' =
                   [refs EXCEPT ![p][r].notified = TRUE]
              /\ channels' =
                   AppendToMany(channels, p, listeners,
                       OpResolve(r, value))
              /\ UNCHANGED << host, sent, delivered >>
              /\ HandoffVarsUnchanged
              /\ Mark([name |-> "SendOpResolveAfterFlush",
                       actor |-> p,
                       refId |-> r])

----------------------------------------------------------------------------
(* ReceiveNetwork: dispatch on the head of channels[from][to]. *)

ReceiveNetwork ==
    \E from, to \in Peers :
        /\ NetworkNonEmpty(channels, from, to)
        /\ LET msg == NetworkHead(channels, from, to)
               ch0 == NetworkTail(channels, from, to)
           IN
              \/ \* op:deliver-only
                 /\ msg.op = "op:deliver-only"
                 /\ LET r == msg.refId
                        entry == refs[to][r]
                    IN
                       /\ entry # EntryNone
                       /\ (CASE entry.kind = "LocalTarget"
                                -> /\ delivered' =
                                         Append(delivered,
                                                [sender |-> msg.sender,
                                                 ref |-> msg.sentOnRef,
                                                 seq |-> msg.seq])
                                   /\ channels' = ch0
                                   /\ UNCHANGED refs
                                   /\ Mark([name |-> "ReceiveNetwork",
                                            kind |-> "deliver-terminal",
                                            from |-> from,
                                            to |-> to,
                                            seq |-> msg.seq,
                                            refId |-> r])
                            [] entry.kind = "LocalPromise"
                                -> IF \/ entry.resolution = ResNone
                                      \/ Len(entry.queue) > 0
                                   THEN /\ refs' =
                                            [refs EXCEPT
                                                ![to][r].queue =
                                                    Append(@, msg)]
                                        /\ channels' = ch0
                                        /\ UNCHANGED delivered
                                        /\ Mark([name |-> "ReceiveNetwork",
                                                 kind |-> "enqueue-pending",
                                                 from |-> from,
                                                 to |-> to,
                                                 seq |-> msg.seq,
                                                 refId |-> r])
                                   ELSE LET nextR ==
                                                entry.resolution.refId
                                            route == Route(to, nextR)
                                            after ==
                                                ApplyRoute(to, route, msg,
                                                    ch0, refs, delivered)
                                            markKind ==
                                                CASE route.tag = "deliver"
                                                        -> "forward-deliver"
                                                  [] route.tag = "wire"
                                                        -> "forward-wire"
                                                  [] route.tag = "queue"
                                                        -> "forward-queue"
                                            markRec ==
                                                IF route.tag = "wire"
                                                THEN [name |-> "ReceiveNetwork",
                                                      kind |-> markKind,
                                                      from |-> from, to |-> to,
                                                      seq |-> msg.seq, refId |-> r,
                                                      nextRefId |-> route.refId]
                                                ELSE [name |-> "ReceiveNetwork",
                                                      kind |-> markKind,
                                                      from |-> from, to |-> to,
                                                      seq |-> msg.seq, refId |-> r]
                                        IN
                                           /\ route.tag \in {"deliver", "wire", "queue"}
                                           /\ channels' = after.channels
                                           /\ refs' = after.refs
                                           /\ delivered' = after.delivered
                                           /\ Mark(markRec)
                            [] entry.kind = "RemotePromise"
                                -> LET route == Route(to, r)
                                       after ==
                                           ApplyRoute(to, route, msg,
                                               ch0, refs, delivered)
                                       markKind ==
                                           CASE route.tag = "deliver"
                                                   -> "forward-remote-deliver"
                                             [] route.tag = "wire"
                                                   -> "forward-remote"
                                             [] route.tag = "queue"
                                                   -> "forward-remote-queue"
                                             [] route.tag = "hold"
                                                   -> "forward-remote-hold"
                                   IN
                                      /\ route.tag \in {"deliver", "wire",
                                                        "queue", "hold"}
                                      /\ channels' = after.channels
                                      /\ refs' = after.refs
                                      /\ delivered' = after.delivered
                                      /\ Mark([name |-> "ReceiveNetwork",
                                               kind |-> markKind,
                                               from |-> from, to |-> to,
                                               seq |-> msg.seq, refId |-> r])
                            [] entry.kind = "RemoteTarget"
                                -> LET route == Route(to, r)
                                   IN /\ route.tag = "wire"
                                      /\ channels' =
                                           NetworkAppend(ch0, to, route.peer,
                                               [msg EXCEPT !.refId = route.refId])
                                      /\ UNCHANGED << refs, delivered >>
                                      /\ Mark([name |-> "ReceiveNetwork",
                                               kind |-> "forward-remote-target",
                                               from |-> from,
                                               to |-> to,
                                               seq |-> msg.seq,
                                               refId |-> r])
                            [] OTHER -> FALSE)
                       /\ UNCHANGED << host, sent >>
                       /\ HandoffVarsUnchanged
              \/ \* op:resolve carrying desc:remote-target.
                 \*
                 \* Under EJavaFlush this dispatches to one of two paths
                 \* (faithful to e-on-java's DelayedRedirector.run):
                 \*
                 \*   FAST PATH (installNow): take when refs[to][r].fresh
                 \*     OR sameConnection(newTarget, current resolver).
                 \*     `fresh` is the local sticky bit asserting no
                 \*     message has ever been pipelined through this
                 \*     RemotePromise; `sameConnection` is the local check
                 \*     that the new target is in the same vat as the
                 \*     current resolver (so any new send arrives behind
                 \*     prior sends by p2p FIFO on that single wire).
                 \*     Either is sufficient to skip the flush; both are
                 \*     locally observable at `to` without any global
                 \*     state.
                 \*
                 \*   SLOW PATH (embargoInstead): emit an OpEFlushProbe on
                 \*     the wire to the current resolver
                 \*     (channels[to][resolverPeer]), buffer subsequent
                 \*     sends locally (Route returns "hold" while
                 \*     embargo is up; messages queue in
                 \*     refs[to][r].pending), and lift embargo only on
                 \*     receipt of the matching OpEFlushProbeAck.  The
                 \*     probe rides the same channel as prior pipelined
                 \*     sends and is re-forwarded by every intermediate
                 \*     hop exactly like a deliver-only, so when the ack
                 \*     returns from the eventual target we know all
                 \*     prior sends have been delivered there.  No peer
                 \*     reads a remote channel or another peer's refs.
                 /\ msg.op = "op:resolve"
                 /\ msg.value.desc = "desc:remote-target"
                 /\ LET r == msg.targetRefId
                        v == msg.value
                        entry == refs[to][r]
                        newLocalRes == ResRef(v.peer, v.refId)
                        \* EJavaFlush fast-path predicates.  Both are
                        \* purely local at `to`.
                        isFreshHere ==
                            entry.kind = "RemotePromise" /\ entry.fresh
                        sameConn ==
                            entry.kind = "RemotePromise"
                            /\ v.peer = entry.resolverPeer
                        fastPath == isFreshHere \/ sameConn
                        \* Handoff withdraw-promise responses (refId allocated
                        \* by HandoffInitiate above ChainLength) always
                        \* install: the listener is the recipient and has no
                        \* race-surface for the policy gating that applies to
                        \* chain promise resolution.
                        isHandoffPw == r > ChainLength
                        installNow ==
                            \/ isHandoffPw
                            \/ RoutingPolicy = "NaivePromiseResolution"
                            \/ RoutingPolicy = "ShorteningUnsafe"
                            \/ /\ RoutingPolicy = "EJavaFlush"
                               /\ fastPath
                            \/ RoutingPolicy = "OpFlushProtocol"
                        embargoInstead ==
                            /\ ~isHandoffPw
                            /\ RoutingPolicy = "EJavaFlush"
                            /\ ~fastPath
                        \* Slow path: emit downstream probe on the wire
                        \* to the current resolver.  refId starts at
                        \* the resolverRefId (mirroring how a fresh
                        \* op:deliver-only is wire-tagged); ApplyRoute
                        \* would mutate it at each forward.
                        probeMsg ==
                            OpEFlushProbe(to, r, entry.resolverRefId)
                    IN
                       /\ entry # EntryNone
                       /\ entry.kind = "RemotePromise"
                       /\ (CASE installNow
                                -> /\ refs' =
                                       [refs EXCEPT
                                           \* OpFlushProtocol path: clear
                                           \* embargo (was set by op:flush);
                                           \* now pending can drain.  Other
                                           \* policies fall through here too;
                                           \* embargo was already FALSE.
                                           ![to][r].localResolution = newLocalRes,
                                           ![to][r].embargo = FALSE]
                                   /\ channels' = ch0
                            [] embargoInstead
                                -> /\ refs' =
                                       [refs EXCEPT
                                           ![to][r].localResolution = newLocalRes,
                                           ![to][r].embargo = TRUE]
                                   /\ channels' =
                                        NetworkAppend(ch0, to,
                                            entry.resolverPeer, probeMsg)
                            [] OTHER -> FALSE)
                       /\ UNCHANGED << host, sent, delivered >>
                       /\ HandoffVarsUnchanged
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "resolve",
                                from |-> from,
                                to |-> to,
                                refId |-> r,
                                installed |-> installNow,
                                embargoed |-> embargoInstead,
                                fastPath |-> fastPath])
              \/ \* op:resolve carrying desc:handoff-give (3PHO).
                 \* Two cases dispatched by targetRefId vs pw:
                 \*   - chain (forwarder): targetRefId is an existing
                 \*     RemotePromise whose localResolution is now
                 \*     installed pointing at pw; both refs[pw] (new)
                 \*     and refs[targetRefId].localResolution are
                 \*     written.
                 \*   - standalone: targetRefId == pw; the recipient
                 \*     just mints the new RemotePromise at pw.
                 /\ msg.op = "op:resolve"
                 /\ msg.value.desc = "desc:handoff-give"
                 /\ EnableHandoff
                 /\ LET v == msg.value
                        targetRefId == msg.targetRefId
                        pw == v.pw
                        gifter == v.gifter
                        tgtHost == v.targetHost
                        gid == v.giftId
                        isChain == targetRefId # pw
                    IN
                       /\ refs[to][pw] = EntryNone
                       /\ (CASE isChain
                                -> /\ targetRefId \in DOMrefs(to)
                                   /\ refs[to][targetRefId].kind = "RemotePromise"
                                   /\ refs[to][targetRefId].localResolution = ResNone
                                   /\ refs' =
                                        [refs EXCEPT
                                            ![to][pw] =
                                                MkRemotePromise(tgtHost, pw,
                                                    ResNone, FALSE,
                                                    << >>, TRUE, TRUE),
                                            ![to][targetRefId].localResolution =
                                                ResRef(to, pw)]
                            [] OTHER
                                -> /\ refs' =
                                        [refs EXCEPT
                                            ![to][pw] =
                                                MkRemotePromise(tgtHost, pw,
                                                    ResNone, FALSE,
                                                    << >>, TRUE, TRUE)])
                       /\ channels' =
                            NetworkAppend(ch0, to, tgtHost,
                                OpWithdrawGift(gid, gifter, pw))
                       /\ UNCHANGED << host, sent, delivered >>
                       /\ HandoffVarsUnchanged
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "resolve-handoff",
                                from |-> from,
                                to |-> to,
                                targetRefId |-> targetRefId,
                                pw |-> pw,
                                gifter |-> gifter,
                                targetHost |-> tgtHost,
                                giftId |-> gid,
                                chain |-> isChain])
              \/ \* op:flush  (OpFlushProtocol only).  Listener sets
                 \* embargo on its RemotePromise AND immediately
                 \* enqueues op:flush-ack on the same channel back to
                 \* the resolver.  Because channels[to][from] is p2p
                 \* FIFO, any previously-pipelined op:deliver-only
                 \* sends from `to` to `from` are already in the
                 \* channel and queue behind the ack -- the resolver
                 \* therefore receives (and forwards) all of `to`'s
                 \* pre-flush sends before it dequeues the ack.  No
                 \* "is my outbox empty?" inference is needed.
                 /\ msg.op = "op:flush"
                 /\ RoutingPolicy = "OpFlushProtocol"
                 /\ LET r == msg.refId
                        entry == refs[to][r]
                    IN
                       /\ entry # EntryNone
                       /\ entry.kind = "RemotePromise"
                       /\ refs' =
                            [refs EXCEPT ![to][r].embargo = TRUE]
                       /\ channels' =
                            NetworkAppend(ch0, to, from, OpFlushAck(r))
                       /\ UNCHANGED << host, sent, delivered >>
                       /\ HandoffVarsUnchanged
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "flush",
                                from |-> from,
                                to |-> to,
                                refId |-> r])
              \/ \* op:flush-ack  (OpFlushProtocol only)
                 /\ msg.op = "op:flush-ack"
                 /\ RoutingPolicy = "OpFlushProtocol"
                 /\ LET r == msg.refId
                        entry == refs[to][r]
                    IN
                       /\ entry # EntryNone
                       /\ entry.kind = "LocalPromise"
                       /\ from \in entry.flushPending
                       /\ refs' =
                            [refs EXCEPT
                                ![to][r].flushPending = entry.flushPending \ {from}]
                       /\ channels' = ch0
                       /\ UNCHANGED << host, sent, delivered >>
                       /\ HandoffVarsUnchanged
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "flush-ack",
                                from |-> from,
                                to |-> to,
                                refId |-> r])
              \/ \* op:e-flush-probe.  End-to-end sentinel used by both
                 \* EJavaFlush (subscriber-initiated slow path) and
                 \* OpFlushProtocol (resolver-initiated target flush).
                 \* It rides the pipelined path exactly like an
                 \* op:deliver-only would: dispatch by Route over
                 \* refs[to][r], then ApplyRoute.  Terminal "deliver"
                 \* tag at a LocalTarget is intercepted by ApplyRoute
                 \* (polymorphic on msg.op) to emit OpEFlushProbeAck
                 \* back to msg.originPeer on `to`'s own outbox, rather
                 \* than appending to `delivered`.  Probes that hit an
                 \* unresolved LocalPromise or an embargoed
                 \* RemotePromise correctly queue/hold and are later
                 \* drained by ProcessPending / ProcessHold.
                 /\ msg.op = "op:e-flush-probe"
                 /\ RoutingPolicy \in {"EJavaFlush", "OpFlushProtocol"}
                 /\ LET r == msg.refId
                        entry == refs[to][r]
                        route == Route(to, r)
                        after ==
                            ApplyRoute(to, route, msg, ch0, refs, delivered)
                    IN
                       /\ entry # EntryNone
                       /\ route.tag \in {"deliver", "wire", "queue", "hold"}
                       /\ channels' = after.channels
                       /\ refs' = after.refs
                       /\ delivered' = after.delivered
                       /\ UNCHANGED << host, sent >>
                       /\ HandoffVarsUnchanged
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "e-flush-probe",
                                from |-> from,
                                to |-> to,
                                refId |-> r,
                                tag |-> route.tag,
                                originPeer |-> msg.originPeer,
                                originRefId |-> msg.originRefId])
              \/ \* op:e-flush-probe-ack.  Returned by the eventual
                 \* target back to the probe's originPeer on the direct
                 \* channel from terminal -> originPeer.  Dispatch on
                 \* the originator's entry kind at originRefId:
                 \*   - EJavaFlush: originator is a subscriber holding
                 \*     a RemotePromise; ack lifts that promise's
                 \*     embargo so ProcessHold can drain the
                 \*     locally-buffered pending sends to the newly
                 \*     committed post-resolution path.
                 \*   - OpFlushProtocol: originator is a resolver
                 \*     holding a LocalPromise; ack advances that
                 \*     promise's flushPhase from "out" to "acked", so
                 \*     SendOpResolveAfterFlush becomes enabled.
                 /\ msg.op = "op:e-flush-probe-ack"
                 /\ RoutingPolicy \in {"EJavaFlush", "OpFlushProtocol"}
                 /\ LET r == msg.originRefId
                        entry == refs[to][r]
                    IN
                       /\ entry # EntryNone
                       /\ (CASE entry.kind = "RemotePromise"
                                -> /\ RoutingPolicy = "EJavaFlush"
                                   /\ entry.embargo
                                   /\ refs' =
                                        [refs EXCEPT
                                            ![to][r].embargo = FALSE]
                            [] entry.kind = "LocalPromise"
                                -> /\ RoutingPolicy = "OpFlushProtocol"
                                   /\ entry.flushPhase = "out"
                                   /\ refs' =
                                        [refs EXCEPT
                                            ![to][r].flushPhase = "acked"]
                            [] OTHER -> FALSE)
                       /\ channels' = ch0
                       /\ UNCHANGED << host, sent, delivered >>
                       /\ HandoffVarsUnchanged
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "e-flush-probe-ack",
                                from |-> from,
                                to |-> to,
                                refId |-> r,
                                originKind |-> entry.kind])
              \/ \* op:listen  (dynamic subscription)
                 /\ msg.op = "op:listen"
                 /\ LET r == msg.refId
                        entry == refs[to][r]
                        res ==
                            IF entry # EntryNone /\ entry.kind = "LocalPromise"
                            THEN entry.resolution
                            ELSE ResNone
                        alreadyResolvedToTarget ==
                            /\ res # ResNone
                            /\ IsResolutionTarget(to, res)
                    IN
                       /\ entry # EntryNone
                       /\ entry.kind = "LocalPromise"
                       /\ (CASE alreadyResolvedToTarget
                                -> \* Subscribe-to-already-resolved with a
                                   \* terminal value: immediate op:resolve reply.
                                   \* Listener is also recorded for bookkeeping.
                                   LET value == ResolveValueFor(to, res)
                                   IN /\ refs' =
                                           [refs EXCEPT
                                               ![to][r].listeners = @ \cup {from},
                                               ![to][r].notified = TRUE]
                                      /\ channels' =
                                           NetworkAppend(ch0, to, from,
                                               OpResolve(r, value))
                            [] OTHER
                                -> \* Unresolved, or resolution is a Promise
                                   \* (terminal-only propagation: no immediate
                                   \* op:resolve sent in this case).
                                   /\ refs' =
                                        [refs EXCEPT
                                            ![to][r].listeners = @ \cup {from}]
                                   /\ channels' = ch0)
                       /\ UNCHANGED << host, sent, delivered >>
                       /\ HandoffVarsUnchanged
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "listen",
                                from |-> from,
                                to |-> to,
                                refId |-> r,
                                replied |-> alreadyResolvedToTarget])
              \/ \* op:deposit-gift (target host).  In addition to
                 \* recording the gift, the target host pre-mints a
                 \* LocalPromise at pw so that pipelined sends from the
                 \* recipient on RemotePromise(pw) have somewhere to queue
                 \* before op:withdraw-gift arrives.  This is consistent with
                 \* the OCapN opaque model: the target host knows pw via the
                 \* deposit but does not learn the underlying target until
                 \* the withdraw resolves the promise.
                 /\ msg.op = "op:deposit-gift"
                 /\ EnableHandoff
                 /\ LET gid == msg.giftId
                        rcp == msg.recipient
                        tlr == msg.targetLocalRefId
                        pw == msg.pw
                        entry ==
                            [kind |-> "gift",
                             recipient |-> rcp,
                             targetLocalRefId |-> tlr]
                    IN
                       /\ gifts[to][from][gid] = NoGift
                       /\ refs[to][pw] = EntryNone
                       /\ gifts' =
                            [gifts EXCEPT ![to][from][gid] = entry]
                       /\ refs' =
                            [refs EXCEPT
                                ![to][pw] =
                                    MkLocalPromise(<< >>, {rcp}, ResNone, {},
                                                   FALSE, "idle")]
                       /\ channels' = ch0
                       /\ UNCHANGED << host, sent, delivered,
                                       nextGiftId, nextRefId >>
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "deposit-gift",
                                from |-> from,
                                to |-> to,
                                giftId |-> gid,
                                recipient |-> rcp,
                                targetLocalRefId |-> tlr,
                                pw |-> pw])
              \/ \* op:withdraw-gift (target host).  Two outcomes:
                 \*   (1) entry present and recipient matches: resolve the
                 \*       pre-minted LocalPromise(pw) to T_local, send
                 \*       op:resolve(pw, desc:remote-target), clear the gift.
                 \*   (2) entry present but recipient mismatch: silently drop
                 \*       (wrong-recipient rejection; gift stays intact for
                 \*       the legitimate recipient).
                 \* If the entry is NOT yet present (the deposit hasn't been
                 \* processed at this target host yet because deposit and
                 \* withdraw arrive on different channels), the action is
                 \* disabled and the message stays at the head of the queue;
                 \* this is the natural serialization point the plan calls
                 \* out, and prevents a withdraw from being lost when it
                 \* races the deposit.
                 /\ msg.op = "op:withdraw-gift"
                 /\ EnableHandoff
                 /\ LET gid == msg.giftId
                        gifter == msg.gifter
                        pw == msg.withdrawPromiseRefId
                        entry == gifts[to][gifter][gid]
                        depositSeen == entry # NoGift
                        recipientOK ==
                            /\ depositSeen
                            /\ entry.recipient = from
                        tlr == IF recipientOK THEN entry.targetLocalRefId ELSE 0
                        resVal == DescRemoteTarget(to, tlr)
                    IN
                       /\ depositSeen
                       /\ (CASE recipientOK
                                -> \* All steps fused atomically so the
                                   \* PairingInvariant is satisfied at the
                                   \* state boundary.  The LocalPromise(pw)
                                   \* was pre-minted on deposit; we now only
                                   \* install its resolution.
                                   /\ refs[to][tlr].kind = "LocalTarget"
                                   /\ refs[to][pw].kind = "LocalPromise"
                                   /\ refs' =
                                        [refs EXCEPT
                                            ![to][pw].resolution =
                                                ResRef(to, tlr),
                                            ![to][pw].notified = TRUE]
                                   /\ channels' =
                                        NetworkAppend(ch0, to, from,
                                            OpResolve(pw, resVal))
                                   /\ gifts' =
                                        [gifts EXCEPT ![to][gifter][gid] = NoGift]
                            [] OTHER
                                -> \* Wrong-recipient: silent drop, gift
                                   \* entry preserved for the legitimate
                                   \* recipient (GiftHasOneRecipient).
                                   /\ channels' = ch0
                                   /\ UNCHANGED << refs, gifts >>)
                       /\ UNCHANGED << host, sent, delivered,
                                       nextGiftId, nextRefId >>
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "withdraw-gift",
                                from |-> from,
                                to |-> to,
                                giftId |-> gid,
                                gifter |-> gifter,
                                pw |-> pw,
                                accepted |-> recipientOK])

----------------------------------------------------------------------------
(* Listen: peer p holding a RemotePromise sends op:listen to the
   resolver to dynamically subscribe.  Gated by EnableDynamicListen so we
   don't pollute the chain-MC state spaces unnecessarily. *)

Listen ==
    \E p \in Peers : \E r \in DOMrefs(p) :
        /\ EnableDynamicListen
        /\ refs[p][r].kind = "RemotePromise"
        /\ ~refs[p][r].listenSent
        /\ LET resolverPeer == refs[p][r].resolverPeer
               resolverR == refs[p][r].resolverRefId
           IN
              /\ p # resolverPeer
              /\ channels' =
                   NetworkAppend(channels, p, resolverPeer, OpListen(resolverR))
              /\ refs' =
                   [refs EXCEPT ![p][r].listenSent = TRUE]
              /\ UNCHANGED << host, sent, delivered >>
              /\ HandoffVarsUnchanged
              /\ Mark([name |-> "Listen",
                       actor |-> p,
                       resolver |-> resolverPeer,
                       refId |-> resolverR])

----------------------------------------------------------------------------
(* HandoffInitiate: gifter packages the gifter-side of a 3PHO
   without a preceding promise resolution.  Modeled as an atomic step that
   allocates (giftId, pw), appends op:deposit-gift to channels[gifter][
   targetHost], and appends op:resolve(pw, desc:handoff-give(...)) to
   channels[gifter][recipient].

   pw is allocated from the global nextRefId counter so it does not collide
   with chain refs or other handoffs.  The gifter must already hold a
   RemoteTarget for the target so the deposit's targetLocalRefId is
   meaningful. *)

(* `existingRefId` selects between:
     0  -- standalone case (no preceding promise; recipient just gets pw).
     r  -- chain (forwarder) case (recipient already holds RemotePromise r;
           the handoff installs r.localResolution = ResRef(_, pw) so
           subsequent sends through r route via pw, and once pw itself
           resolves the recipient can dispatch r -> pw -> wire to
           targetHost).  *)
HandoffInitiate ==
    \E gifter, recipient \in Peers :
      \E srcRef \in DOMrefs(gifter) :
        \E existingRefId \in {0} \cup (DOMrefs(recipient)) :
            /\ EnableHandoff
            /\ gifter # recipient
            /\ refs[gifter][srcRef].kind = "RemoteTarget"
            /\ LET targetHost == refs[gifter][srcRef].targetPeer
                   targetLocalRef == refs[gifter][srcRef].targetRefId
                   gid == nextGiftId[gifter]
                   pw == nextRefId
                   targetRefIdToSend ==
                       IF existingRefId = 0 THEN pw ELSE existingRefId
               IN
                  /\ gifter # targetHost
                  /\ recipient # targetHost
                  /\ gid \in GiftIds
                  /\ pw \in RefIds
                  /\ refs[recipient][pw] = EntryNone
                  /\ \/ existingRefId = 0
                     \/ /\ existingRefId \in DOMrefs(recipient)
                        /\ refs[recipient][existingRefId].kind = "RemotePromise"
                        /\ refs[recipient][existingRefId].localResolution = ResNone
                  /\ channels' =
                       LET ch1 ==
                               NetworkAppend(channels, gifter, targetHost,
                                   OpDepositGift(gid, recipient, targetLocalRef, pw))
                       IN NetworkAppend(ch1, gifter, recipient,
                              OpResolve(targetRefIdToSend,
                                  DescHandoffGive(gifter, targetHost, gid, pw)))
                  /\ nextGiftId' =
                       [nextGiftId EXCEPT ![gifter] = gid + 1]
                  /\ nextRefId' = pw + 1
                  /\ UNCHANGED << host, refs, sent, delivered, gifts >>
                  /\ Mark([name |-> "HandoffInitiate",
                           gifter |-> gifter,
                           recipient |-> recipient,
                           targetHost |-> targetHost,
                           existingRefId |-> existingRefId,
                           giftId |-> gid,
                           pw |-> pw])

----------------------------------------------------------------------------
Init == PromiseResolutionInit

Next ==
    \/ PeerSend
    \/ ResolverResolve
    \/ ReceiveNetwork
    \/ ProcessPending
    \/ ProcessHold
    \/ SendTargetFlushProbe
    \/ SendOpResolveAfterFlush
    \/ Listen
    \/ HandoffInitiate

(* Fairness: weak fairness on every action that can move a message toward
   delivery.  Exposed as a named operator so MCs that override Init can
   still pick up the same fairness assumptions (via PS!Fairness) without
   restating them. *)
Fairness ==
    /\ WF_vars(PeerSend)
    /\ WF_vars(ResolverResolve)
    /\ WF_vars(ReceiveNetwork)
    /\ WF_vars(ProcessPending)
    /\ WF_vars(SendTargetFlushProbe)
    /\ WF_vars(SendOpResolveAfterFlush)
    /\ WF_vars(ProcessHold)
    /\ WF_vars(Listen)
    /\ WF_vars(HandoffInitiate)

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ Fairness

----------------------------------------------------------------------------
TypeOK ==
    /\ channels \in NetworkChannelsType(Messages)
    /\ refs \in [Peers -> [RefIds -> RefEntryType(Messages)]]
    /\ PeerStateTypeOK(DeliveredEntry, NumMessages, MaxRefId)
    /\ host \in [ChainRefs -> Peers]

----------------------------------------------------------------------------
EndToEndRefFIFO ==
    \A sender \in Peers, ref \in {1} :
        LET seqs ==
            SelectSeq(delivered,
                LAMBDA d : d.sender = sender /\ d.ref = ref)
        IN
            \A i \in 1..(Len(seqs) - 1) : seqs[i].seq < seqs[i + 1].seq

----------------------------------------------------------------------------
(* Completeness invariants. *)

NoInFlightDeliverOnly ==
    /\ \A p, q \in Peers :
            \A i \in 1..Len(channels[p][q]) :
                channels[p][q][i].op # "op:deliver-only"
    /\ \A p \in Peers : \A r \in DOMrefs(p) :
            refs[p][r].kind = "LocalPromise" =>
                Len(refs[p][r].queue) = 0
    /\ \A p \in Peers : \A r \in DOMrefs(p) :
            refs[p][r].kind = "RemotePromise" =>
                Len(refs[p][r].pending) = 0

NoMessageLost ==
    (sent = NumMessages /\ NoInFlightDeliverOnly)
        => (Len(delivered) = NumMessages)

EventualDelivery ==
    <>(Len(delivered) = NumMessages)

----------------------------------------------------------------------------
(* Gift-table invariants.                                                   *)

(* GiftOneShot: nextGiftId monotonicity (per-gifter counter strictly
   increasing on every HandoffInitiate) ensures no (gifter, giftId) pair is
   re-deposited.  At any state, the depositions that ever occurred at
   gifts[targetHost][gifter] are confined to giftIds < nextGiftId[gifter],
   and once cleared (on withdraw) they never become a gift again because
   no action mutates a gifts[*][*][*] slot besides the deposit (NoGift ->
   entry) and withdraw (entry -> NoGift) atomic transitions. *)

GiftOneShot ==
    /\ \A p \in Peers : nextGiftId[p] \in 1..(MaxGifts + 1)
    /\ \A target, gifter \in Peers : \A gid \in GiftIds :
         gifts[target][gifter][gid] # NoGift =>
            gid < nextGiftId[gifter]

(* GiftHasOneRecipient: as long as the gift entry exists, only the named
   recipient may successfully withdraw it.  The ReceiveOpWithdrawGift
   handler enforces this at the action level (silently rejecting other
   peers).  The state invariant here just records that the recipient field
   is a single Peer. *)

GiftHasOneRecipient ==
    \A target, gifter \in Peers : \A gid \in GiftIds :
        LET e == gifts[target][gifter][gid]
        IN e # NoGift => e.recipient \in Peers

============================================================================
