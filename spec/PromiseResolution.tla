------------------------- MODULE PromiseResolution -------------------------
(***************************************************************************)
(* OCapN-flavored reference taxonomy with kind-discriminated dispatch.    *)
(*                                                                         *)
(* Per-peer vats[p].refs[r] entries (one of):                              *)
(*   LocalTarget    -- a sink owned by p                                   *)
(*   RemoteTarget   -- presence for someone else's LocalTarget             *)
(*   LocalPromise   -- p is the resolver; holds queue, listeners,         *)
(*                     resolution, flushPending, notified, flushPhase      *)
(*   RemotePromise  -- presence for someone else's LocalPromise; holds     *)
(*                     localResolution, embargo, pending, listenSent,      *)
(*                     fresh                                               *)
(*                                                                         *)
(* Routing is a single dispatch over LocalRef(self, r).kind plus send-time *)
(* recursion through any installed resolution                              *)
(* (LocalPromise.resolution / RemotePromise.localResolution) so a sender   *)
(* that has already learned a downstream target skips the resolved hop.   *)
(* See notes/path-changes.md for the precise taxonomy of path changes     *)
(* (promise resolution vs intra-vat promise shortening) that produce      *)
(* those installed resolutions in the first place.                         *)
(*                                                                         *)
(* LOCALITY CONTRACT.  Every action below binds its acting peer as `self`  *)
(* and is required to read/write only `self`'s slice of state.  Reads go   *)
(* through the per-actor accessors LocalRef(self, r) / Inbox(self, from)   *)
(* / InboxHead(self, from) / InboxNonEmpty(self, from); writes go through  *)
(* AppendToOutbox(_, self, to, msg) and                                    *)
(* [vats EXCEPT ![self].refs[r]... = ...] (or .gifts[...], .nextGiftId).  *)
(* No action may infer "the recipient has processed" from its own outbox   *)
(* state, peek at another peer's refs, or use any signal that would not be *)
(* available to a real OCapN implementation talking over TCP sessions.     *)
(* Every state transition is driven by either the acting peer's own state  *)
(* or an explicit incoming protocol message.                                *)
(*                                                                          *)
(* The precise contract, per-action audit, accessor reference, and known   *)
(* modeling shortcuts (e.g. globally-shared refIds, the HandoffInitiate    *)
(* existingRefId quantifier) are documented in                              *)
(* ../notes/locality-contract.md; that note also lists the patterns that  *)
(* are explicitly forbidden and the reviewer checklist for new actions.   *)
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
(*                                FAST PATH: vats[L].refs[r].fresh OR      *)
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
    << channels, host, vats, sent, delivered,
       nextRefId, lastAction >>

----------------------------------------------------------------------------
(* Initialization: pin host, build the refs slice of each vat from        *)
(* MkChainRefs(host, listeners), then bundle into vats via PeerStateInit. *)

PromiseResolutionInit ==
    /\ host \in [ChainRefs -> Peers]
    /\ NetworkInit
    /\ PeerStateInit(MkChainRefs(host, ChainListenersFor))
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

(* Route: pure (no state mutation) dispatch on `self`'s own ref table.
   `self` is the acting peer; every read goes through LocalRef(self, _) so
   the locality scope is visually explicit.  See
   ../notes/locality-contract.md section 3. *)
RECURSIVE Route(_, _)
Route(self, r) ==
    LET entry == LocalRef(self, r)
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
   a RemotePromise vats[L].refs[r]:

   FAST PATH (no flush) -- locally decidable at L, no remote read:
     fastPath := LocalRef(L,r).fresh \/ msg.value.peer = LocalRef(L,r).resolverPeer
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
     they buffer locally in vats[L].refs[r].pending (mirroring e-on-java's
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
   wire route is taken at `self`, the originating RemotePromise on `self`
   (the one whose (resolverPeer, resolverRefId) matches the wire target)
   has anything-ever-pipelined-through-me set; we clear `fresh` to FALSE
   on all such RemotePromise entries.  Pairing usually means at most one
   match; we tolerate more.

   Per-peer write: only `self`'s own vats[self].refs slice is mutated. *)
MarkRefNonFresh(self, route, vats0) ==
    [vats0 EXCEPT
        ![self].refs =
            [r \in RefIds |->
                IF /\ vats0[self].refs[r] # EntryNone
                   /\ vats0[self].refs[r].kind = "RemotePromise"
                   /\ vats0[self].refs[r].resolverPeer = route.peer
                   /\ vats0[self].refs[r].resolverRefId = route.refId
                THEN [vats0[self].refs[r] EXCEPT !.fresh = FALSE]
                ELSE vats0[self].refs[r]]]

(* ApplyRoute: layer the route.tag effects atop a starting
   (ch0, refs0, delivered0) triple, returning a record with the next
   channels / refs / delivered.  Source-side mutations (channel head
   dequeue, LocalPromise.queue tail, RemotePromise.pending tail) must
   already be baked into ch0 / refs0 by the caller.  The caller is also
   responsible for guarding route.tag with the allowed subset for its
   specific call site (some sites disallow "hold").

   `self` is the acting peer.  All channel writes go through
   AppendToOutbox(_, self, _, _) (own outbox); all ref writes are scoped
   to vats[self].refs[] either directly (queue/hold tags, where
   route.peer is constructed by Route as `self`) or via
   MarkRefNonFresh(self, _, _).
   See ../notes/locality-contract.md sections 2-3.

   ApplyRoute is polymorphic on msg.op for the terminal "deliver" tag:
     - op:deliver-only at a LocalTarget       -> append delivery record.
     - op:e-flush-probe at a LocalTarget      -> emit OpEFlushProbeAck
       back to the probe's originPeer on self's own outbox.  The ack is
       the end-to-end signal that all messages routed before the probe
       on this chain have been processed at the terminal.  The
       originPeer field on the probe carries the originator's identity
       the same way a return address does, so terminal `self` does not
       need any prior knowledge of the originator.
   For non-terminal route tags (wire/queue/hold) the message is
   forwarded uniformly regardless of its op; the polymorphism on op
   only matters at the sink. *)
ApplyRoute(self, route, msg, ch0, vats0, delivered0) ==
    LET m2 == [msg EXCEPT !.refId = route.refId]
        vats1 ==
            IF route.tag = "wire"
            THEN MarkRefNonFresh(self, route, vats0)
            ELSE vats0
    IN CASE route.tag = "deliver"
            -> IF msg.op = "op:deliver-only"
               THEN [channels  |-> ch0,
                     vats      |-> vats1,
                     delivered |-> Append(delivered0, DeliveredRecord(msg))]
               ELSE \* op:e-flush-probe terminates: emit ack to originPeer
                    [channels  |->
                        AppendToOutbox(ch0, self, msg.originPeer,
                            OpEFlushProbeAck(msg.originRefId)),
                     vats      |-> vats1,
                     delivered |-> delivered0]
         [] route.tag = "wire"
            -> [channels  |-> AppendToOutbox(ch0, self, route.peer, m2),
                vats      |-> vats1,
                delivered |-> delivered0]
         [] route.tag = "queue"
            -> [channels  |-> ch0,
                vats      |->
                    [vats1 EXCEPT
                        ![route.peer].refs[route.refId].queue =
                            Append(@, msg)],
                delivered |-> delivered0]
         [] route.tag = "hold"
            -> [channels  |-> ch0,
                vats      |->
                    [vats1 EXCEPT
                        ![route.peer].refs[route.refId].pending =
                            Append(@, msg)],
                delivered |-> delivered0]

----------------------------------------------------------------------------
Mark(rec) ==
    IF DebugTrace THEN lastAction' = rec ELSE UNCHANGED lastAction

(* Sentinel for actions that don't touch handoff-only state.  Under the    *)
(* vats consolidation, gifts and nextGiftId are vat fields, so a handoff- *)
(* free action implicitly leaves them alone whenever it writes to vats    *)
(* via an EXCEPT chain that only touches refs.  This operator now only    *)
(* covers the truly top-level nextRefId counter.                          *)
HandoffVarsUnchanged ==
    UNCHANGED nextRefId

----------------------------------------------------------------------------
(* PeerSend (HeadPeer only): originates a fresh op:deliver-only on ref 1. *)
(* Actor: self = HeadPeer.  Reads LocalRef(self, 1) (via Route) and `sent`;*)
(* writes via ApplyRoute (own outbox / own refs / delivered).  Locality:   *)
(* contract upheld -- see ../notes/locality-contract.md section 3.         *)

PeerSend ==
    LET self == HeadPeer
        seqN == sent + 1
        route == Route(self, 1)
        msg == OpDeliverOnly(self, 1, seqN, route.refId)
        after == ApplyRoute(self, route, msg, channels, vats, delivered)
    IN
        /\ sent < NumMessages
        /\ route.tag \in {"deliver", "wire", "queue", "hold"}
        /\ sent' = seqN
        /\ channels' = after.channels
        /\ vats' = after.vats
        /\ delivered' = after.delivered
        /\ UNCHANGED << host >>
        /\ HandoffVarsUnchanged
        /\ Mark([name |-> "PeerSend",
                 actor |-> self,
                 seq |-> seqN,
                 ref |-> 1,
                 tag |-> route.tag,
                 toPeer |-> route.peer,
                 toRefId |-> route.refId])

----------------------------------------------------------------------------
(* ProcessPending: drain one message from a resolved LocalPromise.queue.   *)
(* Actor: self.  Reads LocalRef(self, r); writes vats[self].refs (queue), *)
(* then routes via ApplyRoute (own outbox / own refs / delivered).        *)
(* Locality contract upheld -- see ../notes/locality-contract.md.          *)

ProcessPending ==
    \E self \in Peers : \E r \in DOMrefs(self) :
        /\ LocalRef(self, r).kind = "LocalPromise"
        /\ LocalRef(self, r).resolution # ResNone
        /\ Len(LocalRef(self, r).queue) > 0
        /\ LET entry == LocalRef(self, r)
               msg == Head(entry.queue)
               restQueue == Tail(entry.queue)
               nextR == entry.resolution.refId
               route == Route(self, nextR)
               vatsSrc == [vats EXCEPT ![self].refs[r].queue = restQueue]
               after == ApplyRoute(self, route, msg, channels, vatsSrc, delivered)
           IN
              /\ route.tag \in {"deliver", "wire", "queue", "hold"}
              /\ channels' = after.channels
              /\ vats' = after.vats
              /\ delivered' = after.delivered
              /\ UNCHANGED << host, sent >>
              /\ HandoffVarsUnchanged
              /\ Mark([name |-> "ProcessPending",
                       actor |-> self,
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
    \E self \in Peers : \E r \in DOMrefs(self) :
        /\ LocalRef(self, r).kind = "RemotePromise"
        /\ ~LocalRef(self, r).embargo
        /\ Len(LocalRef(self, r).pending) > 0
        /\ LET entry == LocalRef(self, r)
               msg == Head(entry.pending)
               restPending == Tail(entry.pending)
               route ==
                   IF entry.localResolution # ResNone
                   THEN Route(self, entry.localResolution.refId)
                   ELSE [tag |-> "wire",
                         peer |-> entry.resolverPeer,
                         refId |-> entry.resolverRefId]
               vatsSrc == [vats EXCEPT ![self].refs[r].pending = restPending]
               after == ApplyRoute(self, route, msg, channels, vatsSrc, delivered)
           IN
              \* Disallow "hold" here: if localResolution chains into another
              \* embargoed RemotePromise we keep the action disabled (the
              \* outer embargo will lift first).
              /\ route.tag \in {"deliver", "wire", "queue"}
              /\ channels' = after.channels
              /\ vats' = after.vats
              /\ delivered' = after.delivered
              /\ UNCHANGED << host, sent >>
              /\ HandoffVarsUnchanged
              /\ Mark([name |-> "ProcessHold",
                       actor |-> self,
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

(* IsResolutionTarget / ResolveValueFor: pure functions over `self`'s
   own ref table.  Both look up res.refId via LocalRef(self, _) --
   locality: own state only. *)
IsResolutionTarget(self, res) ==
    /\ res # ResNone
    /\ res.refId \in DOMrefs(self)
    /\ LocalRef(self, res.refId).kind \in {"LocalTarget", "RemoteTarget"}

ResolveValueFor(self, res) ==
    LET targetEntry == LocalRef(self, res.refId)
    IN IF targetEntry.kind = "LocalTarget"
       THEN DescRemoteTarget(self, res.refId)
       ELSE \* RemoteTarget
            DescRemoteTarget(targetEntry.targetPeer, targetEntry.targetRefId)

(* Append `msg` to channels[self][q] for each q in `qs`.  Locality: the
   acting peer `self` only mutates its own outbox; `qs` is the actor's
   own LocalPromise.listeners set, part of vats[self].refs[r]. *)
AppendToManyOutboxes(ch, self, qs, msg) ==
    [ch EXCEPT ![self] =
        [q \in Peers |->
            IF q \in qs THEN Append(ch[self][q], msg) ELSE ch[self][q]]]

(* ResolverResolve: actor = self = host[r] (the resolver of LocalPromise *)
(* vats[self].refs[r]).  All reads via LocalRef(self, _); all writes    *)
(* scoped to vats[self].refs[r] and self's own outboxes.  Locality      *)
(* contract upheld.                                                     *)
ResolverResolve ==
    \E self \in Peers : \E r \in DOMrefs(self) :
        /\ LocalRef(self, r).kind = "LocalPromise"
        /\ LocalRef(self, r).resolution = ResNone
        /\ r \in ChainRefs   \* handoff LocalPromises (pw > ChainLength) are
                              \* resolved exclusively by ReceiveOpWithdrawGift
        /\ host[r] = self
        /\ LET entry == LocalRef(self, r)
               res == ChainResolutionFor(r)
               listeners == entry.listeners
               isTarget == IsResolutionTarget(self, res)
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
                   IF isTarget THEN ResolveValueFor(self, res) ELSE ResNone
           IN
              /\ res # ResNone
              /\ (CASE fireOpResolveNow
                       -> /\ vats' =
                              [vats EXCEPT
                                  ![self].refs[r].resolution = res,
                                  ![self].refs[r].notified = TRUE]
                          /\ channels' =
                              AppendToManyOutboxes(channels, self, listeners,
                                  OpResolve(r, value))
                   [] fireOpFlush
                       -> /\ vats' =
                              [vats EXCEPT
                                  ![self].refs[r].resolution = res,
                                  ![self].refs[r].flushPending = listeners]
                          /\ channels' =
                              AppendToManyOutboxes(channels, self, listeners,
                                  OpFlush(r))
                   [] OTHER
                       -> /\ vats' =
                              [vats EXCEPT ![self].refs[r].resolution = res]
                          /\ UNCHANGED channels)
              /\ UNCHANGED << host, sent, delivered >>
              /\ HandoffVarsUnchanged
              /\ Mark([name |-> "ResolverResolve",
                       actor |-> self,
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
    \E self \in Peers : \E r \in DOMrefs(self) :
        /\ RoutingPolicy = "OpFlushProtocol"
        /\ LocalRef(self, r).kind = "LocalPromise"
        /\ LocalRef(self, r).resolution # ResNone
        /\ IsResolutionTarget(self, LocalRef(self, r).resolution)
        /\ LocalRef(self, r).flushPending = {}
        /\ ~LocalRef(self, r).notified
        /\ LocalRef(self, r).flushPhase = "idle"
        /\ Len(LocalRef(self, r).queue) = 0
        /\ LET entry == LocalRef(self, r)
               res == entry.resolution
               targetEntry == LocalRef(self, res.refId)
               targetPeer ==
                   IF targetEntry.kind = "RemoteTarget"
                   THEN targetEntry.targetPeer
                   ELSE self
               targetRefId ==
                   IF targetEntry.kind = "RemoteTarget"
                   THEN targetEntry.targetRefId
                   ELSE res.refId
               probe == OpEFlushProbe(self, r, targetRefId)
           IN
              \* Local target (self IS the target host): no
              \* cross-vat flush needed, so the transition is "idle"
              \* -> "acked" without any wire message.  Remote target:
              \* emit the probe on self's own outbox to targetPeer and
              \* transition "idle" -> "out"; the ack receive below
              \* transitions "out" -> "acked".
              (CASE targetPeer = self
                       -> /\ vats' =
                              [vats EXCEPT
                                  ![self].refs[r].flushPhase = "acked"]
                          /\ UNCHANGED channels
                          /\ Mark([name |-> "SendTargetFlushProbe",
                                   actor |-> self, refId |-> r,
                                   targetPeer |-> self,
                                   phase |-> "acked"])
                 [] OTHER
                       -> /\ vats' =
                              [vats EXCEPT
                                  ![self].refs[r].flushPhase = "out"]
                          /\ channels' =
                              AppendToOutbox(channels, self, targetPeer, probe)
                          /\ Mark([name |-> "SendTargetFlushProbe",
                                   actor |-> self, refId |-> r,
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
    \E self \in Peers : \E r \in DOMrefs(self) :
        /\ RoutingPolicy = "OpFlushProtocol"
        /\ LocalRef(self, r).kind = "LocalPromise"
        /\ LocalRef(self, r).resolution # ResNone
        /\ IsResolutionTarget(self, LocalRef(self, r).resolution)
        /\ LocalRef(self, r).flushPending = {}
        /\ LocalRef(self, r).flushPhase = "acked"
        /\ ~LocalRef(self, r).notified
        /\ Len(LocalRef(self, r).queue) = 0
        /\ LET entry == LocalRef(self, r)
               res == entry.resolution
               value == ResolveValueFor(self, res)
               listeners == entry.listeners
           IN
              /\ vats' =
                   [vats EXCEPT ![self].refs[r].notified = TRUE]
              /\ channels' =
                   AppendToManyOutboxes(channels, self, listeners,
                       OpResolve(r, value))
              /\ UNCHANGED << host, sent, delivered >>
              /\ HandoffVarsUnchanged
              /\ Mark([name |-> "SendOpResolveAfterFlush",
                       actor |-> self,
                       refId |-> r])

----------------------------------------------------------------------------
(* ReceiveNetwork: dispatch on the head of self's inbox from `from`.       *)
(* Actor: self (the receiver).  Reads Inbox(self, from) head and consumes  *)
(* it; reads LocalRef(self, _); writes vats[self].refs[_], own outbox via  *)
(* AppendToOutbox(_, self, _, _), and (for handoff)                        *)
(* vats[self].gifts[from][_].                                              *)
(* `from` is the sender's peer identity, used only as a channel index and  *)
(* as a destination for ack/reply messages -- never to read `from`'s ref   *)
(* table or state.  Locality contract upheld -- see                        *)
(* ../notes/locality-contract.md sections 2-3.                             *)

ReceiveNetwork ==
    \E self, from \in Peers :
        /\ InboxNonEmpty(self, from)
        /\ LET msg == InboxHead(self, from)
               ch0 == InboxTail(channels, self, from)
           IN
              \/ \* op:deliver-only
                 /\ msg.op = "op:deliver-only"
                 /\ LET r == msg.refId
                        entry == LocalRef(self, r)
                    IN
                       /\ entry # EntryNone
                       /\ (CASE entry.kind = "LocalTarget"
                                -> /\ delivered' =
                                         Append(delivered,
                                                [sender |-> msg.sender,
                                                 ref |-> msg.sentOnRef,
                                                 seq |-> msg.seq])
                                   /\ channels' = ch0
                                   /\ UNCHANGED vats
                                   /\ Mark([name |-> "ReceiveNetwork",
                                            kind |-> "deliver-terminal",
                                            from |-> from,
                                            to |-> self,
                                            seq |-> msg.seq,
                                            refId |-> r])
                            [] entry.kind = "LocalPromise"
                                -> IF \/ entry.resolution = ResNone
                                      \/ Len(entry.queue) > 0
                                   THEN /\ vats' =
                                            [vats EXCEPT
                                                ![self].refs[r].queue =
                                                    Append(@, msg)]
                                        /\ channels' = ch0
                                        /\ UNCHANGED delivered
                                        /\ Mark([name |-> "ReceiveNetwork",
                                                 kind |-> "enqueue-pending",
                                                 from |-> from,
                                                 to |-> self,
                                                 seq |-> msg.seq,
                                                 refId |-> r])
                                   ELSE LET nextR ==
                                                entry.resolution.refId
                                            route == Route(self, nextR)
                                            after ==
                                                ApplyRoute(self, route, msg,
                                                    ch0, vats, delivered)
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
                                                      from |-> from, to |-> self,
                                                      seq |-> msg.seq, refId |-> r,
                                                      nextRefId |-> route.refId]
                                                ELSE [name |-> "ReceiveNetwork",
                                                      kind |-> markKind,
                                                      from |-> from, to |-> self,
                                                      seq |-> msg.seq, refId |-> r]
                                        IN
                                           /\ route.tag \in {"deliver", "wire", "queue"}
                                           /\ channels' = after.channels
                                           /\ vats' = after.vats
                                           /\ delivered' = after.delivered
                                           /\ Mark(markRec)
                            [] entry.kind = "RemotePromise"
                                -> LET route == Route(self, r)
                                       after ==
                                           ApplyRoute(self, route, msg,
                                               ch0, vats, delivered)
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
                                      /\ vats' = after.vats
                                      /\ delivered' = after.delivered
                                      /\ Mark([name |-> "ReceiveNetwork",
                                               kind |-> markKind,
                                               from |-> from, to |-> self,
                                               seq |-> msg.seq, refId |-> r])
                            [] entry.kind = "RemoteTarget"
                                -> LET route == Route(self, r)
                                   IN /\ route.tag = "wire"
                                      /\ channels' =
                                           AppendToOutbox(ch0, self, route.peer,
                                               [msg EXCEPT !.refId = route.refId])
                                      /\ UNCHANGED << vats, delivered >>
                                      /\ Mark([name |-> "ReceiveNetwork",
                                               kind |-> "forward-remote-target",
                                               from |-> from,
                                               to |-> self,
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
                 \*   FAST PATH (installNow): take when LocalRef(self,r).fresh
                 \*     OR sameConnection(newTarget, current resolver).
                 \*     `fresh` is the local sticky bit asserting no
                 \*     message has ever been pipelined through this
                 \*     RemotePromise; `sameConnection` is the local check
                 \*     that the new target is in the same vat as the
                 \*     current resolver (so any new send arrives behind
                 \*     prior sends by p2p FIFO on that single wire).
                 \*     Either is sufficient to skip the flush; both are
                 \*     locally observable at `self` without any global
                 \*     state.
                 \*
                 \*   SLOW PATH (embargoInstead): emit an OpEFlushProbe on
                 \*     self's own outbox to the current resolver, buffer
                 \*     subsequent sends locally (Route returns "hold"
                 \*     while embargo is up; messages queue in
                 \*     vats[self].refs[r].pending), and lift embargo only on
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
                        entry == LocalRef(self, r)
                        newLocalRes == ResRef(v.peer, v.refId)
                        \* EJavaFlush fast-path predicates.  Both are
                        \* purely local at `self`.
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
                        \* Slow path: emit downstream probe on self's own
                        \* outbox to the current resolver.  refId starts at
                        \* the resolverRefId (mirroring how a fresh
                        \* op:deliver-only is wire-tagged); ApplyRoute
                        \* would mutate it at each forward.
                        probeMsg ==
                            OpEFlushProbe(self, r, entry.resolverRefId)
                    IN
                       /\ entry # EntryNone
                       /\ entry.kind = "RemotePromise"
                       /\ (CASE installNow
                                -> /\ vats' =
                                       [vats EXCEPT
                                           \* OpFlushProtocol path: clear
                                           \* embargo (was set by op:flush);
                                           \* now pending can drain.  Other
                                           \* policies fall through here too;
                                           \* embargo was already FALSE.
                                           ![self].refs[r].localResolution = newLocalRes,
                                           ![self].refs[r].embargo = FALSE]
                                   /\ channels' = ch0
                            [] embargoInstead
                                -> /\ vats' =
                                       [vats EXCEPT
                                           ![self].refs[r].localResolution = newLocalRes,
                                           ![self].refs[r].embargo = TRUE]
                                   /\ channels' =
                                        AppendToOutbox(ch0, self,
                                            entry.resolverPeer, probeMsg)
                            [] OTHER -> FALSE)
                       /\ UNCHANGED << host, sent, delivered >>
                       /\ HandoffVarsUnchanged
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "resolve",
                                from |-> from,
                                to |-> self,
                                refId |-> r,
                                installed |-> installNow,
                                embargoed |-> embargoInstead,
                                fastPath |-> fastPath])
              \/ \* op:resolve carrying desc:handoff-give (3PHO).
                 \* Two cases dispatched by targetRefId vs pw:
                 \*   - chain (forwarder): targetRefId is an existing
                 \*     RemotePromise whose localResolution is now
                 \*     installed pointing at pw; both
                 \*     vats[self].refs[pw] (new) and
                 \*     vats[self].refs[targetRefId].localResolution
                 \*     are written.
                 \*   - standalone: targetRefId == pw; the recipient
                 \*     just mints the new RemotePromise at pw.
                 \*
                 \* Validation is fully recipient-side: the gifter does
                 \* NOT inspect the recipient's ref table when initiating
                 \* (see HandoffInitiate's LOCALITY comment).  An invalid
                 \* combination -- pw collides with an existing entry, or
                 \* the chain-form targetRefId does not point at an
                 \* unresolved RemotePromise on self -- is silently
                 \* dropped: the inbox head is consumed, no other state
                 \* changes, and no op:withdraw-gift is emitted to the
                 \* target host (since the handoff at this recipient
                 \* never took effect).
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
                        pwFree == ~LocalRefAllocated(self, pw)
                        chainBindable ==
                            /\ targetRefId \in DOMrefs(self)
                            /\ LocalRef(self, targetRefId).kind = "RemotePromise"
                            /\ LocalRef(self, targetRefId).localResolution = ResNone
                        accept ==
                            /\ pwFree
                            /\ (isChain => chainBindable)
                    IN
                       /\ (CASE accept /\ isChain
                                -> /\ vats' =
                                        [vats EXCEPT
                                            ![self].refs[pw] =
                                                MkRemotePromise(tgtHost, pw,
                                                    ResNone, FALSE,
                                                    << >>, TRUE, TRUE),
                                            ![self].refs[targetRefId].localResolution =
                                                ResRef(self, pw)]
                                   /\ channels' =
                                        AppendToOutbox(ch0, self, tgtHost,
                                            OpWithdrawGift(gid, gifter, pw))
                            [] accept /\ ~isChain
                                -> /\ vats' =
                                        [vats EXCEPT
                                            ![self].refs[pw] =
                                                MkRemotePromise(tgtHost, pw,
                                                    ResNone, FALSE,
                                                    << >>, TRUE, TRUE)]
                                   /\ channels' =
                                        AppendToOutbox(ch0, self, tgtHost,
                                            OpWithdrawGift(gid, gifter, pw))
                            [] OTHER
                                -> \* Silent drop: consume inbox head, no
                                   \* state change, no withdraw emitted.
                                   /\ channels' = ch0
                                   /\ UNCHANGED vats)
                       /\ UNCHANGED << host, sent, delivered >>
                       /\ HandoffVarsUnchanged
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "resolve-handoff",
                                from |-> from,
                                to |-> self,
                                targetRefId |-> targetRefId,
                                pw |-> pw,
                                gifter |-> gifter,
                                targetHost |-> tgtHost,
                                giftId |-> gid,
                                chain |-> isChain,
                                accepted |-> accept])
              \/ \* op:flush  (OpFlushProtocol only).  Listener `self`
                 \* sets embargo on its RemotePromise AND immediately
                 \* enqueues op:flush-ack on its own outbox back to the
                 \* resolver `from`.  Because channels[self][from] is
                 \* p2p FIFO, any previously-pipelined op:deliver-only
                 \* sends from `self` to `from` are already in the
                 \* channel and queue behind the ack -- the resolver
                 \* therefore receives (and forwards) all of `self`'s
                 \* pre-flush sends before it dequeues the ack.  No
                 \* "is my outbox empty?" inference is needed.
                 /\ msg.op = "op:flush"
                 /\ RoutingPolicy = "OpFlushProtocol"
                 /\ LET r == msg.refId
                        entry == LocalRef(self, r)
                    IN
                       /\ entry # EntryNone
                       /\ entry.kind = "RemotePromise"
                       /\ vats' =
                            [vats EXCEPT ![self].refs[r].embargo = TRUE]
                       /\ channels' =
                            AppendToOutbox(ch0, self, from, OpFlushAck(r))
                       /\ UNCHANGED << host, sent, delivered >>
                       /\ HandoffVarsUnchanged
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "flush",
                                from |-> from,
                                to |-> self,
                                refId |-> r])
              \/ \* op:flush-ack  (OpFlushProtocol only)
                 /\ msg.op = "op:flush-ack"
                 /\ RoutingPolicy = "OpFlushProtocol"
                 /\ LET r == msg.refId
                        entry == LocalRef(self, r)
                    IN
                       /\ entry # EntryNone
                       /\ entry.kind = "LocalPromise"
                       /\ from \in entry.flushPending
                       /\ vats' =
                            [vats EXCEPT
                                ![self].refs[r].flushPending = entry.flushPending \ {from}]
                       /\ channels' = ch0
                       /\ UNCHANGED << host, sent, delivered >>
                       /\ HandoffVarsUnchanged
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "flush-ack",
                                from |-> from,
                                to |-> self,
                                refId |-> r])
              \/ \* op:e-flush-probe.  End-to-end sentinel used by both
                 \* EJavaFlush (subscriber-initiated slow path) and
                 \* OpFlushProtocol (resolver-initiated target flush).
                 \* It rides the pipelined path exactly like an
                 \* op:deliver-only would: dispatch by Route over
                 \* LocalRef(self, r), then ApplyRoute.  Terminal
                 \* "deliver" tag at a LocalTarget is intercepted by
                 \* ApplyRoute (polymorphic on msg.op) to emit
                 \* OpEFlushProbeAck back to msg.originPeer on `self`'s
                 \* own outbox, rather than appending to `delivered`.
                 \* Probes that hit an unresolved LocalPromise or an
                 \* embargoed RemotePromise correctly queue/hold and
                 \* are later drained by ProcessPending / ProcessHold.
                 /\ msg.op = "op:e-flush-probe"
                 /\ RoutingPolicy \in {"EJavaFlush", "OpFlushProtocol"}
                 /\ LET r == msg.refId
                        entry == LocalRef(self, r)
                        route == Route(self, r)
                        after ==
                            ApplyRoute(self, route, msg, ch0, vats, delivered)
                    IN
                       /\ entry # EntryNone
                       /\ route.tag \in {"deliver", "wire", "queue", "hold"}
                       /\ channels' = after.channels
                       /\ vats' = after.vats
                       /\ delivered' = after.delivered
                       /\ UNCHANGED << host, sent >>
                       /\ HandoffVarsUnchanged
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "e-flush-probe",
                                from |-> from,
                                to |-> self,
                                refId |-> r,
                                tag |-> route.tag,
                                originPeer |-> msg.originPeer,
                                originRefId |-> msg.originRefId])
              \/ \* op:e-flush-probe-ack.  Returned by the eventual
                 \* target back to the probe's originPeer (= self) on
                 \* the direct channel from terminal -> self.  Dispatch
                 \* on the originator's entry kind at originRefId:
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
                        entry == LocalRef(self, r)
                    IN
                       /\ entry # EntryNone
                       /\ (CASE entry.kind = "RemotePromise"
                                -> /\ RoutingPolicy = "EJavaFlush"
                                   /\ entry.embargo
                                   /\ vats' =
                                        [vats EXCEPT
                                            ![self].refs[r].embargo = FALSE]
                            [] entry.kind = "LocalPromise"
                                -> /\ RoutingPolicy = "OpFlushProtocol"
                                   /\ entry.flushPhase = "out"
                                   /\ vats' =
                                        [vats EXCEPT
                                            ![self].refs[r].flushPhase = "acked"]
                            [] OTHER -> FALSE)
                       /\ channels' = ch0
                       /\ UNCHANGED << host, sent, delivered >>
                       /\ HandoffVarsUnchanged
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "e-flush-probe-ack",
                                from |-> from,
                                to |-> self,
                                refId |-> r,
                                originKind |-> entry.kind])
              \/ \* op:listen  (dynamic subscription)
                 /\ msg.op = "op:listen"
                 /\ LET r == msg.refId
                        entry == LocalRef(self, r)
                        res ==
                            IF entry # EntryNone /\ entry.kind = "LocalPromise"
                            THEN entry.resolution
                            ELSE ResNone
                        alreadyResolvedToTarget ==
                            /\ res # ResNone
                            /\ IsResolutionTarget(self, res)
                    IN
                       /\ entry # EntryNone
                       /\ entry.kind = "LocalPromise"
                       /\ (CASE alreadyResolvedToTarget
                                -> \* Subscribe-to-already-resolved with a
                                   \* terminal value: immediate op:resolve reply.
                                   \* Listener is also recorded for bookkeeping.
                                   LET value == ResolveValueFor(self, res)
                                   IN /\ vats' =
                                           [vats EXCEPT
                                               ![self].refs[r].listeners = @ \cup {from},
                                               ![self].refs[r].notified = TRUE]
                                      /\ channels' =
                                           AppendToOutbox(ch0, self, from,
                                               OpResolve(r, value))
                            [] OTHER
                                -> \* Unresolved, or resolution is a Promise
                                   \* (terminal-only propagation: no immediate
                                   \* op:resolve sent in this case).
                                   /\ vats' =
                                        [vats EXCEPT
                                            ![self].refs[r].listeners = @ \cup {from}]
                                   /\ channels' = ch0)
                       /\ UNCHANGED << host, sent, delivered >>
                       /\ HandoffVarsUnchanged
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "listen",
                                from |-> from,
                                to |-> self,
                                refId |-> r,
                                replied |-> alreadyResolvedToTarget])
              \/ \* op:deposit-gift (target host = self).  In addition
                 \* to recording the gift, the target host pre-mints a
                 \* LocalPromise at pw so that pipelined sends from the
                 \* recipient on RemotePromise(pw) have somewhere to queue
                 \* before op:withdraw-gift arrives.  This is consistent
                 \* with the OCapN opaque model: the target host knows pw
                 \* via the deposit but does not learn the underlying
                 \* target until the withdraw resolves the promise.
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
                       /\ LocalGift(self, from, gid) = NoGift
                       /\ ~LocalRefAllocated(self, pw)
                       /\ vats' =
                            [vats EXCEPT
                                ![self].gifts[from][gid] = entry,
                                ![self].refs[pw] =
                                    MkLocalPromise(<< >>, {rcp}, ResNone, {},
                                                   FALSE, "idle")]
                       /\ channels' = ch0
                       /\ UNCHANGED << host, sent, delivered, nextRefId >>
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "deposit-gift",
                                from |-> from,
                                to |-> self,
                                giftId |-> gid,
                                recipient |-> rcp,
                                targetLocalRefId |-> tlr,
                                pw |-> pw])
              \/ \* op:withdraw-gift (target host = self).  Two outcomes:
                 \*   (1) entry present and recipient matches: resolve the
                 \*       pre-minted LocalPromise(pw) to T_local, send
                 \*       op:resolve(pw, desc:remote-target), clear the gift.
                 \*   (2) entry present but recipient mismatch: silently drop
                 \*       (wrong-recipient rejection; gift stays intact for
                 \*       the legitimate recipient).
                 \* If the entry is NOT yet present (the deposit hasn't been
                 \* processed at self yet because deposit and withdraw
                 \* arrive on different channels), the action is disabled
                 \* and the message stays at the head of the queue; this is
                 \* the natural serialization point the plan calls out, and
                 \* prevents a withdraw from being lost when it races the
                 \* deposit.
                 /\ msg.op = "op:withdraw-gift"
                 /\ EnableHandoff
                 /\ LET gid == msg.giftId
                        gifter == msg.gifter
                        pw == msg.withdrawPromiseRefId
                        entry == LocalGift(self, gifter, gid)
                        depositSeen == entry # NoGift
                        recipientOK ==
                            /\ depositSeen
                            /\ entry.recipient = from
                        tlr == IF recipientOK THEN entry.targetLocalRefId ELSE 0
                        resVal == DescRemoteTarget(self, tlr)
                    IN
                       /\ depositSeen
                       /\ (CASE recipientOK
                                -> \* All steps fused atomically so the
                                   \* PairingInvariant is satisfied at the
                                   \* state boundary.  The LocalPromise(pw)
                                   \* was pre-minted on deposit; we now only
                                   \* install its resolution.
                                   /\ LocalRef(self, tlr).kind = "LocalTarget"
                                   /\ LocalRef(self, pw).kind = "LocalPromise"
                                   /\ vats' =
                                        [vats EXCEPT
                                            ![self].refs[pw].resolution =
                                                ResRef(self, tlr),
                                            ![self].refs[pw].notified = TRUE,
                                            ![self].gifts[gifter][gid] = NoGift]
                                   /\ channels' =
                                        AppendToOutbox(ch0, self, from,
                                            OpResolve(pw, resVal))
                            [] OTHER
                                -> \* Wrong-recipient: silent drop, gift
                                   \* entry preserved for the legitimate
                                   \* recipient (GiftHasOneRecipient).
                                   /\ channels' = ch0
                                   /\ UNCHANGED vats)
                       /\ UNCHANGED << host, sent, delivered, nextRefId >>
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "withdraw-gift",
                                from |-> from,
                                to |-> self,
                                giftId |-> gid,
                                gifter |-> gifter,
                                pw |-> pw,
                                accepted |-> recipientOK])

----------------------------------------------------------------------------
(* Listen: peer self holding a RemotePromise sends op:listen to the        *)
(* resolver to dynamically subscribe.  Gated by EnableDynamicListen so we  *)
(* don't pollute the chain-MC state spaces unnecessarily.  Actor: self.   *)
(* Reads LocalRef(self, r); writes vats[self].refs (listenSent flag) and  *)
(* self's own outbox to resolverPeer.  Locality contract upheld.          *)

Listen ==
    \E self \in Peers : \E r \in DOMrefs(self) :
        /\ EnableDynamicListen
        /\ LocalRef(self, r).kind = "RemotePromise"
        /\ ~LocalRef(self, r).listenSent
        /\ LET entry == LocalRef(self, r)
               resolverPeer == entry.resolverPeer
               resolverR == entry.resolverRefId
           IN
              /\ self # resolverPeer
              /\ channels' =
                   AppendToOutbox(channels, self, resolverPeer,
                       OpListen(resolverR))
              /\ vats' =
                   [vats EXCEPT ![self].refs[r].listenSent = TRUE]
              /\ UNCHANGED << host, sent, delivered >>
              /\ HandoffVarsUnchanged
              /\ Mark([name |-> "Listen",
                       actor |-> self,
                       resolver |-> resolverPeer,
                       refId |-> resolverR])

----------------------------------------------------------------------------
(* HandoffInitiate: gifter (= self) packages the gifter-side of a 3PHO
   without a preceding promise resolution.  Modeled as an atomic step that
   allocates (giftId, pw), appends op:deposit-gift on self's outbox to
   targetHost, and appends op:resolve(targetRefIdToSend, desc:handoff-give
   (...)) on self's outbox to recipient.

   pw is allocated from the global nextRefId counter so it does not collide
   with chain refs or other handoffs.  The gifter must already hold a
   RemoteTarget for the target so the deposit's targetLocalRefId is
   meaningful.

   Actor: self (the gifter).  Channel writes are self->targetHost and
   self->recipient (both AppendToOutbox).  vats[self].nextGiftId is the
   gifter's own counter; nextRefId is a global model counter (see the
   "known modeling shortcuts" in ../notes/locality-contract.md section 5).

   LOCALITY: this action reads ONLY self's own state.  Per the OCapN
   model, a peer never inspects another peer's ref table or gift table;
   it only sends messages whose effect is dispatched at the recipient
   via that recipient's own ReceiveNetwork action.  In particular:
     - pw collision against recipient's refs: NOT checked here.  The
       recipient validates `LocalRef(self, pw) = EntryNone` in its
       desc:handoff-give receive branch and silently drops if violated
       (and under nextRefId's monotonic allocation collisions cannot
       arise in well-formed traces, so the drop is a defence-in-depth
       guard, not a routine path).
     - existingRefId on the recipient's refs: NOT checked here.  The
       chain form of handoff requires the recipient to hold a
       RemotePromise at existingRefId with unresolved localResolution
       for the rebind to take effect.  The recipient validates this
       in its desc:handoff-give receive branch; an invalid combination
       is silently dropped at the recipient.  In OCapN, the gifter
       would have learned of the recipient's refId via some prior
       op:* message; under v0 globally-shared refIds the chain ref
       (1..ChainLength) is in DOMrefs(self) on every peer, so picking
       from `DOMrefs(self)` recovers the same test coverage as the
       previous `DOMrefs(recipient)` quantifier while staying local. *)

(* `existingRefId` selects between:
     0  -- standalone case (no preceding promise; recipient just gets pw).
     r  -- chain (forwarder) case: the gifter advertises a refId r from
           its own ref namespace.  The recipient, on receipt, checks
           whether IT holds a RemotePromise at r with unresolved
           localResolution and installs r.localResolution = ResRef(_, pw)
           if so (chain rebind), or silently drops otherwise.

   The quantifier is restricted to {0} ∪ {r ∈ DOMrefs(self) : r is
   a Promise kind on self}.  This is locality-clean (the gifter
   inspects only its own refs) and tighter than the unrestricted
   DOMrefs(self): refIds that are Targets on the gifter would
   silent-drop on every recipient anyway (Targets aren't bindable as
   chain-handoff anchors).  Including BOTH LocalPromise and
   RemotePromise kinds is required to cover the canonical forwarder
   scenario where the gifter holds a LocalPromise at r and the
   recipient holds the parallel RemotePromise at r. *)
HandoffInitiate ==
    \E self, recipient \in Peers :
      \E srcRef \in DOMrefs(self) :
        \E existingRefId \in
              {0} \cup
              {r \in DOMrefs(self) :
                  LocalRef(self, r).kind \in
                      {"LocalPromise", "RemotePromise"}} :
            /\ EnableHandoff
            /\ self # recipient
            /\ LocalRef(self, srcRef).kind = "RemoteTarget"
            /\ LET srcEntry == LocalRef(self, srcRef)
                   targetHost == srcEntry.targetPeer
                   targetLocalRef == srcEntry.targetRefId
                   gid == LocalNextGiftId(self)
                   pw == nextRefId
                   targetRefIdToSend ==
                       IF existingRefId = 0 THEN pw ELSE existingRefId
               IN
                  /\ self # targetHost
                  /\ recipient # targetHost
                  /\ gid \in GiftIds
                  /\ pw \in RefIds
                  /\ channels' =
                       LET ch1 ==
                               AppendToOutbox(channels, self, targetHost,
                                   OpDepositGift(gid, recipient, targetLocalRef, pw))
                       IN AppendToOutbox(ch1, self, recipient,
                              OpResolve(targetRefIdToSend,
                                  DescHandoffGive(self, targetHost, gid, pw)))
                  /\ vats' =
                       [vats EXCEPT ![self].nextGiftId = gid + 1]
                  /\ nextRefId' = pw + 1
                  /\ UNCHANGED << host, sent, delivered >>
                  /\ Mark([name |-> "HandoffInitiate",
                           gifter |-> self,
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
    /\ PeerStateTypeOK(DeliveredEntry, NumMessages, MaxRefId, Messages)
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
            vats[p].refs[r].kind = "LocalPromise" =>
                Len(vats[p].refs[r].queue) = 0
    /\ \A p \in Peers : \A r \in DOMrefs(p) :
            vats[p].refs[r].kind = "RemotePromise" =>
                Len(vats[p].refs[r].pending) = 0

NoMessageLost ==
    (sent = NumMessages /\ NoInFlightDeliverOnly)
        => (Len(delivered) = NumMessages)

EventualDelivery ==
    <>(Len(delivered) = NumMessages)

----------------------------------------------------------------------------
(* Gift-table invariants.                                                   *)

(* GiftOneShot: vats[p].nextGiftId monotonicity (per-gifter counter
   strictly increasing on every HandoffInitiate) ensures no
   (gifter, giftId) pair is re-deposited.  At any state, the depositions
   that ever occurred at vats[targetHost].gifts[gifter] are confined to
   giftIds < vats[gifter].nextGiftId, and once cleared (on withdraw)
   they never become a gift again because no action mutates a
   vats[*].gifts[*][*] slot besides the deposit (NoGift -> entry) and
   withdraw (entry -> NoGift) atomic transitions. *)

GiftOneShot ==
    /\ \A p \in Peers : vats[p].nextGiftId \in 1..(MaxGifts + 1)
    /\ \A target, gifter \in Peers : \A gid \in GiftIds :
         vats[target].gifts[gifter][gid] # NoGift =>
            gid < vats[gifter].nextGiftId

(* GiftHasOneRecipient: as long as the gift entry exists, only the named
   recipient may successfully withdraw it.  The ReceiveOpWithdrawGift
   handler enforces this at the action level (silently rejecting other
   peers).  The state invariant here just records that the recipient field
   is a single Peer. *)

GiftHasOneRecipient ==
    \A target, gifter \in Peers : \A gid \in GiftIds :
        LET e == vats[target].gifts[gifter][gid]
        IN e # NoGift => e.recipient \in Peers

============================================================================
