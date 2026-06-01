------------------------- MODULE PromiseResolution -------------------------
(***************************************************************************)
(* OCapN-flavored reference taxonomy with kind-discriminated dispatch.    *)
(*                                                                         *)
(* Per-peer vats[p].refs[r] entries (one of):                              *)
(*   LocalTarget    -- a sink owned by p                                   *)
(*   RemoteTarget   -- presence for someone else's LocalTarget             *)
(*   LocalPromise   -- p is the resolver; holds queue, listeners,         *)
(*                     resolution, flushPending, notified,                  *)
(*                     repropNotified, pipelinedListeners                  *)
(*   RemotePromise  -- presence for someone else's LocalPromise; holds     *)
(*                     localResolution, embargo, pending, listenSent,      *)
(*                     fresh, flushSent                                    *)
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
(*   "OpFlushProtocol"         faithful implementation of Ridley's        *)
(*                              op:flush proposal (ocapn#11; verbatim     *)
(*                              draft in notes/flush-protocols.md §9).    *)
(*                              Shortener-initiated: when a peer X has   *)
(*                              learned its RemotePromise resolves to a   *)
(*                              third party, X fires InitiateFlush       *)
(*                              (defined in protocols/OpFlushProtocol)    *)
(*                              and sends                                  *)
(*                              op:flush(toDescRefId, answerPos,           *)
(*                              resolveMeRefId) to the resolver-holder.    *)
(*                              The resolver-holder mints a fresh         *)
(*                              LocalPromise p' via nextRefId, sets the   *)
(*                              old resolver's resolution to              *)
(*                              ResRef(self, p') (intra-vat cascade       *)
(*                              buffers future sends locally at p'), and  *)
(*                              replies with op:resolve(resolveMeRefId,   *)
(*                              desc:import-promise(p')) on               *)
(*                              channels[self][from].  No probe, no       *)
(*                              flush-ack.  Surprising result: faithful   *)
(*                              Ridley does NOT preserve EndToEndRefFIFO  *)
(*                              on the chain topologies this spec        *)
(*                              exercises -- see notes/path-changes.md    *)
(*                              §4.7 for the counterexample.              *)
(***************************************************************************)

(* EXTENDS chain:
   - lib/ (References, Network, PeerState): types, channels, vats.
   - protocols/Common: shared CONSTANT block, lastAction VARIABLE, Mark,
     HandoffVarsUnchanged.
   - protocols/EJavaFlush: EJavaFlush-specific wire ops + helpers
     (OpEFlushProbe, OpEFlushProbeAck, MarkRefNonFresh,
     ClearRemotePromiseFresh, ListenersWitnessPipelined).
   - protocols/OpFlushProtocol: faithful Ridley op:flush wire op +
     shortener-side action (OpFlush, InitiateFlush).
   The big action bodies (PeerSend, ResolverResolve, ReceiveNetwork,
   ProcessPending, ProcessHold, RepropagatePromiseShorten, Listen,
   HandoffInitiate) stay below because their dispatch crosses policy
   boundaries.  See notes/flush-protocols.md for the per-policy
   semantics. *)
EXTENDS Naturals, Sequences, TLC, EJavaFlushHelpers, OpFlushProtocolHelpers

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

(* op:flush, op:e-flush-probe, op:e-flush-probe-ack wire ops now live in
   protocols/OpFlushProtocol.tla and protocols/EJavaFlush.tla
   respectively, pulled in via EXTENDS above.  Each policy module owns
   the wire ops that only its policy emits. *)

(* v0 globally-shared refIds: subscriber and resolver name the same logical
   refId, so op:listen carries only one. *)
OpListen(refId) ==
    [op |-> "op:listen",
     refId |-> refId]

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

(* Resolution descriptors carried in op:resolve.value.  "import" and
   "export" are from the perspective of the message receiver (the peer
   that processes the op:resolve).  A desc:import-* names a capability
   hosted on the sender; desc:export-* names one hosted on the receiver.
   desc:handoff-give is reserved for third-party introductions where the
   capability host is neither sender nor receiver. *)

DescImportTarget(refId) ==
    [desc |-> "desc:import-target", refId |-> refId]

DescExportTarget(refId) ==
    [desc |-> "desc:export-target", refId |-> refId]

DescImportPromise(refId) ==
    [desc |-> "desc:import-promise", refId |-> refId]

DescExportPromise(refId) ==
    [desc |-> "desc:export-promise", refId |-> refId]

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

TargetWireDescs ==
    {"desc:import-target", "desc:export-target",
     "desc:import-promise", "desc:export-promise"}

DescValues ==
    {DescImportTarget(r) : r \in RefIds}
    \cup {DescExportTarget(r) : r \in RefIds}
    \cup {DescImportPromise(r) : r \in RefIds}
    \cup {DescExportPromise(r) : r \in RefIds}
    \cup {DescHandoffGive(g, h, i, w) :
            g \in Peers, h \in Peers, i \in GiftIds, w \in RefIds}

(* Host peer and wire refId for a resolution value at the resolver.
   Dispatches on the entry kind:
     - LocalTarget / LocalPromise : the resolver itself is the cap host;
       the wire refId is the resolver-local refId pointed at by `res`.
     - RemoteTarget               : the cap is hosted on entry.targetPeer
       at entry.targetRefId (target's local refId).
     - RemotePromise              : the cap is hosted on entry.resolverPeer
       at entry.resolverRefId (resolver-host's local refId).  This arm is
       reached when a LocalPromise resolves to another peer's promise --
       the inter-vat promise-shortening case modelled in Phase A. *)
TargetHostPeer(resolver, res) ==
    LET entry == LocalRef(resolver, res.refId)
    IN CASE entry.kind = "LocalTarget"   -> resolver
         [] entry.kind = "LocalPromise"  -> resolver
         [] entry.kind = "RemoteTarget"  -> entry.targetPeer
         [] entry.kind = "RemotePromise" -> entry.resolverPeer

TargetWireRefId(resolver, res) ==
    LET entry == LocalRef(resolver, res.refId)
    IN CASE entry.kind = "LocalTarget"   -> res.refId
         [] entry.kind = "LocalPromise"  -> res.refId
         [] entry.kind = "RemoteTarget"  -> entry.targetRefId
         [] entry.kind = "RemotePromise" -> entry.resolverRefId

TargetCapKind(resolver, res) ==
    LocalRef(resolver, res.refId).kind

(* Third-party introduction: capability host is neither sender nor receiver. *)
NeedsHandoffIntro(sender, receiver, capHost) ==
    capHost \notin {sender, receiver}

(* Classify which descriptor tag applies (pure; for tests and docs). *)
WireDescTag(sender, receiver, capHost, capKind) ==
    IF NeedsHandoffIntro(sender, receiver, capHost)
    THEN "handoff-give"
    ELSE IF capKind \in {"LocalTarget", "RemoteTarget"}
         THEN IF capHost = receiver THEN "export-target" ELSE "import-target"
         ELSE IF capHost = receiver THEN "export-promise" ELSE "import-promise"

(* Build the op:resolve value for a two-party target introduction.  Must
   not be called when WireDescTag is "handoff-give" (third-party): a
   3-party introduction needs a fresh gift and the desc:handoff-give
   shape carries (targetHost, giftId, withdrawPromise) instead of a
   bare refId.  Callers are expected to check NeedsHandoffIntro first
   and dispatch into the deposit-gift path; the OTHER arm asserts to
   catch any missed gate. *)
ResolveValueFor(resolver, res, listener) ==
    LET capHost == TargetHostPeer(resolver, res)
        refId == TargetWireRefId(resolver, res)
        capKind == TargetCapKind(resolver, res)
        tag == WireDescTag(resolver, listener, capHost, capKind)
    IN CASE tag = "export-target" -> DescExportTarget(refId)
         [] tag = "import-target" -> DescImportTarget(refId)
         [] tag = "export-promise" -> DescExportPromise(refId)
         [] tag = "import-promise" -> DescImportPromise(refId)
         [] OTHER ->
              Assert(FALSE,
                     "ResolveValueFor called with handoff-give context; "
                  \o "caller must dispatch through deposit-gift path")

(* Map a received descriptor to the ResRef a holder installs. *)
DescToResRef(receiver, sender, desc) ==
    CASE desc.desc = "desc:import-target" -> ResRef(sender, desc.refId)
      [] desc.desc = "desc:export-target" -> ResRef(receiver, desc.refId)
      [] desc.desc = "desc:import-promise" -> ResRef(sender, desc.refId)
      [] desc.desc = "desc:export-promise" -> ResRef(receiver, desc.refId)
      [] OTHER -> ResNone

(* True when `desc` is the correct wire shape for introducing `capHost`'s
   ref from `sender` to `receiver`.  Used by unit-test invariants. *)
WireDescMatches(sender, receiver, capHost, capKind, desc) ==
    IF NeedsHandoffIntro(sender, receiver, capHost)
    THEN desc.desc = "desc:handoff-give"
    ELSE IF capKind \in {"LocalTarget", "RemoteTarget"}
         THEN /\ desc.desc =
                  IF capHost = receiver
                  THEN "desc:export-target" ELSE "desc:import-target"
              /\ desc.refId \in RefIds
         ELSE /\ desc.desc =
                  IF capHost = receiver
                  THEN "desc:export-promise" ELSE "desc:import-promise"
              /\ desc.refId \in RefIds

Messages ==
    { OpDeliverOnly(HeadPeer, 1, n, r) :
        n \in 1..NumMessages, r \in RefIds }
    \cup { OpResolve(r, v) : r \in RefIds, v \in DescValues }
    \cup { OpFlush(td, ap, rm) :
            td \in RefIds, ap \in RefIds, rm \in RefIds }
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
               /\ \/ entry.embargo # {}
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
   When subscriber L receives op:resolve(r, desc:import-target(r')) or
   desc:export-target(r') on a RemotePromise vats[L].refs[r]:

   FAST PATH (no flush) -- locally decidable at L, no remote read:
     fastPath := LocalRef(L,r).fresh \/ sameConn
     If fastPath, set localResolution = DescToResRef(L, from, msg.value);
     embargo stays FALSE.  Subsequent sends route directly through the
     installed localResolution via the normal Route recursion.

       - `fresh` (only on RemotePromise entries in vats[L].refs; mirrors
         RemotePromiseHandler [1] / EProxyHandler.isFresh [6]): TRUE while
         this peer has never pipelined on that imported promise; cleared
         FALSE by MarkRefNonFresh on route.tag = "wire" (outbound to the
         paired resolver wire) or "hold" (local pending while embargoed).
         The resolver's paired LocalPromise does not carry `fresh`; it
         uses pipelinedListeners when wire traffic proves the listener
         used its import.  Once fresh is FALSE it stays FALSE.
       - `sameConnection`: the new target is in the same vat as the
         current resolver (desc is import-* and sender = resolverPeer).
         Any new send arrives behind prior sends by p2p FIFO on that
         single wire, so no flush is needed (e-on-java [3]).

   SLOW PATH (downstream flush + ack) -- L sends one protocol message,
   awaits one protocol message:
     embargoInstead := EJavaFlush /\ ~fastPath /\ ~isHandoffPw
     If embargoInstead: set localResolution = DescToResRef(L, from,
     msg.value) (staged); set embargo = TRUE; append OpEFlushProbe(L, r,
     resolverRefId) to L's own outbox channels[L][resolverPeer].

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

(* ClearRemotePromiseFresh / MarkRefNonFresh have moved to
   protocols/EJavaFlush.tla.  Their effect (clear the `fresh` bit on
   the imported RemotePromise once this peer has pipelined through it)
   is policy-agnostic in form -- other policies just never read the
   `fresh` bit -- but conceptually it is the e-on-java
   `myFreshFlag` / `EProxyHandler.isFresh` mechanism, so it lives with
   the rest of the EJavaFlush model. *)

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
            IF route.tag \in {"wire", "hold"}
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

(* Mark and HandoffVarsUnchanged live in protocols/Common.tla, pulled in
   via the EXTENDS chain above. *)

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
        /\ LocalRef(self, r).embargo = {}
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

(* IsResolutionTarget: pure function over `self`'s own ref table. *)
IsResolutionTarget(self, res) ==
    /\ res # ResNone
    /\ res.refId \in DOMrefs(self)
    /\ LocalRef(self, res.refId).kind \in {"LocalTarget", "RemoteTarget"}

(* IsResolutionPromise: dual of IsResolutionTarget for the inter-vat
   promise-shortening case (notes/path-changes.md §1.2.b, Phase A).
   Holds when the LocalPromise's resolution points at another Promise
   on the resolver's ref table.  When the resolution points at an
   intra-vat LocalPromise the cap host is the resolver itself (silent
   intra-vat shortening, §1.2.a); when it points at a RemotePromise the
   cap host is that promise's resolverPeer (the inter-vat case). *)
IsResolutionPromise(self, res) ==
    /\ res # ResNone
    /\ res.refId \in DOMrefs(self)
    /\ LocalRef(self, res.refId).kind \in {"LocalPromise", "RemotePromise"}

(* AllListenersTwoParty: every listener can receive a two-party
   import/export descriptor (cap host is sender or receiver).  This
   gates Phase A's promise-shortening emission: any third-party
   listener would require desc:handoff-give for a Promise cap, which
   is Phase B work. *)
AllListenersTwoParty(resolver, res, listeners) ==
    LET capHost == TargetHostPeer(resolver, res)
    IN \A l \in listeners : ~NeedsHandoffIntro(resolver, l, capHost)

(* MarkListenerPipelined: resolver-side witness for a listener's *paired
   import*.  Listener L holds RemotePromise(resolver, promiseRefId) with
   its own local `fresh` (cleared when L pipelines on that presence via
   MarkRefNonFresh — wire or hold — never read here).  When that pipeline
   reaches the resolver on the wire, an op:deliver-only from L on this
   LocalPromise ref records L in pipelinedListeners.  Independent state:
   vats[L].refs[...] vs vats[resolver].refs[promiseRefId]. *)
MarkListenerPipelined(resolver, promiseRefId, from, vats0) ==
    LET entry == vats0[resolver].refs[promiseRefId]
    IN IF /\ entry # EntryNone
           /\ entry.kind = "LocalPromise"
           /\ from \in entry.listeners
        THEN [vats0 EXCEPT
                 ![resolver].refs[promiseRefId].pipelinedListeners =
                     entry.pipelinedListeners \cup {from}]
        ELSE vats0

(* ListenersWitnessPipelined has moved to protocols/EJavaFlush.tla. *)

(* CoTerminalPromiseHost: terminal and penultimate promise share a host
   (e.g. host = <<vatB, vatC, vatC>>).  Used to gate EJavaFlush and
   OpFlush resolver-initiated 3-party handoff at r=1 only (state-space). *)
CoTerminalPromiseHost ==
    host[ChainLength] = host[ChainLength - 1]

(* Fold listener notifications into outboxes.  Two-party resolutions carry
   import/export descriptors; third-party resolutions emit deposit-gift +
   desc:handoff-give (one gift per listener).  Locality: only appends on
   channels[resolver][_]. *)
RECURSIVE AppendResolveNotifications(_, _, _, _, _, _, _)
AppendResolveNotifications(ch, resolver, promiseRefId, res, listeners,
                            gidAcc, pwAcc) ==
    IF listeners = {}
    THEN [channels |-> ch, gidNext |-> gidAcc, pwNext |-> pwAcc]
    ELSE LET listener == CHOOSE l \in listeners : TRUE
             capHost == TargetHostPeer(resolver, res)
             wireRefId == TargetWireRefId(resolver, res)
             rest == listeners \ {listener}
         IN IF NeedsHandoffIntro(resolver, listener, capHost)
            THEN LET gid == gidAcc
                     pw == pwAcc
                     ch1 ==
                         AppendToOutbox(ch, resolver, capHost,
                             OpDepositGift(gid, listener, wireRefId, pw))
                     ch2 ==
                         AppendToOutbox(ch1, resolver, listener,
                             OpResolve(promiseRefId,
                                 DescHandoffGive(resolver, capHost, gid, pw)))
                 IN AppendResolveNotifications(ch2, resolver, promiseRefId,
                     res, rest, gid + 1, pw + 1)
            ELSE LET value == ResolveValueFor(resolver, res, listener)
                     chN ==
                         AppendToOutbox(ch, resolver, listener,
                             OpResolve(promiseRefId, value))
                 IN AppendResolveNotifications(chN, resolver, promiseRefId,
                     res, rest, gidAcc, pwAcc)

ListenersNotifyable(resolver, res, listeners) ==
    listeners # {}

(* Append `msg` to channels[self][q] for each q in `qs`.  Locality: the
   acting peer `self` only mutates its own outbox; `qs` is the actor's
   own LocalPromise.listeners set, part of vats[self].refs[r].
   Skips q = self: a self-addressed op:flush would land in the resolver's
   own LocalPromise inbox where the RemotePromise receive arm is
   disabled, blocking channels[self][self].  Self's flush bookkeeping is
   tracked via vats[self].refs[r].flushPending (already updated
   non-wire by the caller). *)
AppendToManyOutboxes(ch, self, qs, msg) ==
    [ch EXCEPT ![self] =
        [q \in Peers |->
            IF q \in qs /\ q # self THEN Append(ch[self][q], msg)
            ELSE ch[self][q]]]

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
               \* Skip self in listeners: self already knows its own
               \* resolution locally; a wire-send to self would queue at
               \* channels[self][self] in an inbox arm that may be
               \* disabled (e.g. op:flush on a LocalPromise receiver).
               listeners == entry.listeners \ {self}
               isTarget == IsResolutionTarget(self, res)
               isPromise == IsResolutionPromise(self, res)
               \* Phase A (notes/path-changes.md §1.2.b): when the
               \* resolution is promise-shaped AND every listener can
               \* receive a two-party desc:import-promise /
               \* desc:export-promise (no handoff-give needed), the
               \* resolver also fires op:resolve so listeners can
               \* shorten their dispatch through the new promise's
               \* host.  Gated to NaivePromiseResolution and
               \* ShorteningUnsafe because the new race surface
               \* (in-flight forwards on the old path racing direct
               \* sends on the new path) is exactly what those
               \* policies are designed to surface; EJavaFlush and
               \* OpFlushProtocol extend to promise-shaped chains
               \* (Phase C).  Three-party promise caps use
               \* desc:handoff-give (Phase B).
               \* Phase A (2-party): NaivePromiseResolution +
               \* ShorteningUnsafe.  Phase C extends to EJavaFlush; the
               \* listener-side EJavaFlush slow path on the existing
               \* op:resolve / TargetWireDescs receive branch already
               \* handles the new race (embargo + e-flush-probe through
               \* the chain via Route, which now cascades through
               \* promise-shaped hops).
               firePromiseShorten ==
                   /\ isPromise
                   /\ listeners # {}
                   /\ AllListenersTwoParty(self, res, listeners)
                   /\ RoutingPolicy \in
                          {"NaivePromiseResolution",
                           "ShorteningUnsafe",
                           "EJavaFlush"}
               \* Phase B/C (3-party): desc:handoff-give for Promise caps.
               \* Phase C adds EJavaFlush (immediate op:resolve; listeners
               \* apply local chainEmbargo).  OpFlushProtocol under faithful
               \* Ridley behaves like the other push-immediately policies
               \* here (the shortener-initiated op:flush fires separately
               \* via InitiateFlush, not as part of ResolverResolve).
               \* ListenersWitnessPipelined gates EJavaFlush 3-party only:
               \* under Naive/Shortening the resolver intentionally has
               \* no synchronization with listeners, so the witness gate
               \* would suppress real race surfaces (notes/path-changes.md
               \* §3.10).  EJavaFlush requires the witness to ensure
               \* listener-side embargo is reachable.
               firePromiseShorten3Party ==
                   /\ isPromise
                   /\ listeners # {}
                   /\ \E l \in listeners :
                        NeedsHandoffIntro(self, l, TargetHostPeer(self, res))
                   /\ (RoutingPolicy # "EJavaFlush"
                       \/ ListenersWitnessPipelined(self, r, listeners))
                   /\ RoutingPolicy \in
                          {"NaivePromiseResolution",
                           "ShorteningUnsafe",
                           "EJavaFlush"}
                   \* Flush policies: head-hop 3PHO only on co-terminal
                   \* topologies (see CoTerminalPromiseHost).
                   /\ (RoutingPolicy \in
                           {"NaivePromiseResolution", "ShorteningUnsafe"}
                       \/ /\ r = 1
                          /\ CoTerminalPromiseHost)
               \* Under faithful Ridley (notes/flush-protocols.md §9),
               \* OpFlushProtocol's resolver does NOT push op:flush
               \* downstream.  The resolver immediately notifies
               \* listeners via op:resolve.  If a listener wants to
               \* shorten itself out of the chain, it later fires
               \* InitiateFlush against its own RemotePromise.  So
               \* OpFlushProtocol's fireOpResolveNow gate matches the
               \* other "push-immediately" policies (Naive / Shortening
               \* / EJavaFlush).
               fireOpResolveNow ==
                   \/ /\ isTarget
                      /\ listeners # {}
                      /\ RoutingPolicy \in
                             {"NaivePromiseResolution",
                              "ShorteningUnsafe",
                              "EJavaFlush",
                              "OpFlushProtocol"}
                   \/ firePromiseShorten
                   \/ firePromiseShorten3Party
               needsHandoff ==
                   /\ \E l \in listeners :
                        NeedsHandoffIntro(self, l, TargetHostPeer(self, res))
                   /\ \/ isTarget
                      \/ firePromiseShorten3Party
               notify ==
                   AppendResolveNotifications(channels, self, r, res,
                       listeners, LocalNextGiftId(self), nextRefId)
           IN
              /\ res # ResNone
              \* Defensive: a 3-party listener requires handoff support
              \* to be notified.  If EnableHandoff is FALSE, suppress the
              \* resolve entirely (visible as EventualDelivery violation
              \* in model-checking) rather than emit a deposit-gift the
              \* receiver cannot process.
              /\ (EnableHandoff
                  \/ ~(\E l \in listeners :
                          NeedsHandoffIntro(self, l,
                              TargetHostPeer(self, res))))
              /\ (CASE fireOpResolveNow
                       -> /\ ListenersNotifyable(self, res, listeners)
                          /\ vats' =
                              [vats EXCEPT
                                  ![self].refs[r].resolution = res,
                                  ![self].refs[r].notified = TRUE,
                                  ![self].nextGiftId = notify.gidNext]
                          /\ channels' = notify.channels
                          /\ IF needsHandoff
                             THEN nextRefId' = notify.pwNext
                             ELSE UNCHANGED nextRefId
                   [] OTHER
                       -> /\ vats' =
                              [vats EXCEPT ![self].refs[r].resolution = res]
                          /\ UNCHANGED channels)
              /\ UNCHANGED << host, sent, delivered >>
              /\ IF ~fireOpResolveNow \/ ~needsHandoff THEN HandoffVarsUnchanged
                 ELSE TRUE
              /\ Mark([name |-> "ResolverResolve",
                       actor |-> self,
                       refId |-> r,
                       resKind |-> IF isTarget THEN "Target" ELSE "Promise",
                       notified |-> fireOpResolveNow])

----------------------------------------------------------------------------
(* RepropagatePromiseShorten (Phase D): when `self` learns a downstream     *)
(* shortening by installing `localResolution` on `recvR`, and `self` also  *)
(* hosts a chain `LocalPromise` `chainR` whose `resolution` points at        *)
(* `recvR`, notify `chainR`'s upstream listeners using the same local        *)
(* predicates as `ResolverResolve` (witness-gated 3-party under flush          *)
(* policies).  No cross-node flush relay; each peer decides from its own     *)
(* ref table (notes/path-changes.md §3.1).  Gated by `EnableRepropagate`.   *)

RepropagatePromiseShorten ==
    /\ EnableRepropagate
    /\ \E self \in Peers :
       \E recvR \in DOMrefs(self) :
       \E chainR \in ChainRefs \intersect DOMrefs(self) :
        /\ LocalRef(self, recvR).kind = "RemotePromise"
        /\ LocalRef(self, recvR).localResolution # ResNone
        /\ LocalRef(self, chainR).kind = "LocalPromise"
        /\ LocalRef(self, chainR).resolution # ResNone
        /\ LocalRef(self, chainR).resolution.refId = recvR
        /\ LocalRef(self, chainR).listeners # {}
        /\ ~LocalRef(self, chainR).repropNotified
        /\ LET res == LocalRef(self, recvR).localResolution
               listeners == LocalRef(self, chainR).listeners \ {self}
               isTarget == IsResolutionTarget(self, res)
               isPromise == IsResolutionPromise(self, res)
               firePromiseShorten ==
                   /\ isPromise
                   /\ AllListenersTwoParty(self, res, listeners)
                   /\ RoutingPolicy \in
                          {"NaivePromiseResolution",
                           "ShorteningUnsafe",
                           "EJavaFlush"}
               firePromiseShorten3Party ==
                   /\ isPromise
                   /\ \E l \in listeners :
                        NeedsHandoffIntro(self, l, TargetHostPeer(self, res))
                   \* EJavaFlush-only witness gate (see ResolverResolve).
                   /\ (RoutingPolicy # "EJavaFlush"
                       \/ ListenersWitnessPipelined(self, chainR, listeners))
                   /\ RoutingPolicy \in
                          {"NaivePromiseResolution",
                           "ShorteningUnsafe",
                           "EJavaFlush"}
               \* Under faithful Ridley (see ResolverResolve above),
               \* OpFlushProtocol uses fireOpResolveNow like other
               \* "push-immediately" policies.  No resolver-pushed
               \* op:flush.
               fireOpResolveNow ==
                   \/ /\ isTarget
                      /\ RoutingPolicy \in
                             {"NaivePromiseResolution",
                              "ShorteningUnsafe",
                              "EJavaFlush",
                              "OpFlushProtocol"}
                   \/ firePromiseShorten
                   \/ firePromiseShorten3Party
               needsHandoff ==
                   /\ \E l \in listeners :
                        NeedsHandoffIntro(self, l, TargetHostPeer(self, res))
                   /\ \/ isTarget
                      \/ firePromiseShorten3Party
               notify ==
                   AppendResolveNotifications(channels, self, chainR, res,
                       listeners, LocalNextGiftId(self), nextRefId)
           IN
              /\ res # ResNone
              /\ fireOpResolveNow
              \* Defensive: see ResolverResolve.  A 3-party listener
              \* requires EnableHandoff; otherwise suppress the resolve.
              /\ (EnableHandoff
                  \/ ~(\E l \in listeners :
                          NeedsHandoffIntro(self, l,
                              TargetHostPeer(self, res))))
              /\ ListenersNotifyable(self, res, listeners)
              /\ vats' =
                   [vats EXCEPT
                       ![self].refs[chainR].repropNotified = TRUE,
                       ![self].refs[chainR].notified = TRUE,
                       ![self].nextGiftId = notify.gidNext]
              /\ channels' = notify.channels
              /\ IF needsHandoff
                 THEN nextRefId' = notify.pwNext
                 ELSE UNCHANGED nextRefId
              /\ UNCHANGED << host, sent, delivered >>
              /\ IF ~fireOpResolveNow \/ ~needsHandoff THEN HandoffVarsUnchanged
                 ELSE TRUE
              /\ Mark([name |-> "RepropagatePromiseShorten",
                       actor |-> self,
                       chainR |-> chainR,
                       recvR |-> recvR])

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
                                            MarkListenerPipelined(self, r, from,
                                                [vats EXCEPT
                                                    ![self].refs[r].queue =
                                                        Append(@, msg)])
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
                                                  [] route.tag = "hold"
                                                        -> "forward-hold"
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
                                           \* Phase C (notes/path-changes.md
                                           \* §3.10): "hold" is reachable
                                           \* when Promise shortening chains
                                           \* this LocalPromise through to an
                                           \* embargoed RemotePromise.  The
                                           \* RemotePromise branch already
                                           \* accepted "hold" -- this branch
                                           \* was missing it pre-Phase-C and
                                           \* deadlocked instead.
                                           /\ route.tag \in {"deliver", "wire", "queue", "hold"}
                                           /\ channels' = after.channels
                                           /\ vats' =
                                                MarkListenerPipelined(self, r, from,
                                                    after.vats)
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
              \/ \* op:resolve carrying import/export target descriptors.
                 \*
                 \* Under EJavaFlush this dispatches to one of two paths
                 \* (faithful to e-on-java's DelayedRedirector.run):
                 \*
                 \*   FAST PATH (installNow): take when LocalRef(self,r).fresh
                 \*     OR sameConnection(newTarget, current resolver).
                 \*     `fresh` is the local sticky bit asserting no
                 \*     message has ever been pipelined through this
                 \*     RemotePromise; `sameConnection` holds when the
                 \*     descriptor is import-* and the sender is the
                 \*     current resolverPeer (target hosted on sender).
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
                 /\ msg.value.desc \in TargetWireDescs
                 /\ LET r == msg.targetRefId
                        v == msg.value
                        entry == LocalRef(self, r)
                        newLocalRes == DescToResRef(self, from, v)
                        \* EJavaFlush fast-path predicates.  Both are
                        \* purely local at `self`.
                        isFreshHere ==
                            entry.kind = "RemotePromise" /\ entry.fresh
                        \* sameConn is restricted to Target descriptors
                        \* (notes/path-changes.md §3.10).  For a
                        \* Promise descriptor, the new target is a
                        \* Promise hosted on the sender; existing
                        \* forwards through the receiver's chain may
                        \* take an intermediate hop on the receiver
                        \* whose queue is independent of the sender's
                        \* FIFO -- the new direct path can bypass
                        \* that queue, surfacing an ordering race
                        \* (see MC_EJavaFlush_3Chain_PromiseShorten
                        \* counterexample).  Under EJavaFlush this
                        \* forces the slow embargo + e-flush-probe
                        \* path for Promise shortening, matching the
                        \* chain-form handoff-give branch above.
                        sameConn ==
                            entry.kind = "RemotePromise"
                            /\ v.desc = "desc:import-target"
                            /\ from = entry.resolverPeer
                        fastPath == isFreshHere \/ sameConn
                        \* Handoff withdraw-promise responses (refId allocated
                        \* by HandoffInitiate above ChainLength) always
                        \* install: the listener is the recipient and has no
                        \* race-surface for the policy gating that applies to
                        \* chain promise resolution.
                        isHandoffPw == r > ChainLength
                        \* Withdraw-promise fast install only for Target
                        \* descriptors; Promise caps use the normal EJavaFlush
                        \* slow path so the chain ref's embargo is respected.
                        isHandoffPwTarget ==
                            isHandoffPw /\ v.desc = "desc:import-target"
                        isHandoffPwPromiseCap ==
                            /\ isHandoffPw
                            /\ v.desc \in {"desc:import-promise",
                                           "desc:export-promise"}
                        installNow ==
                            \/ isHandoffPwTarget
                            \/ /\ isHandoffPwPromiseCap
                               /\ RoutingPolicy # "EJavaFlush"
                            \/ RoutingPolicy = "NaivePromiseResolution"
                            \/ RoutingPolicy = "ShorteningUnsafe"
                            \/ /\ RoutingPolicy = "EJavaFlush"
                               /\ fastPath
                            \/ RoutingPolicy = "OpFlushProtocol"
                        embargoInstead ==
                            /\ ~(isHandoffPw /\ v.desc = "desc:import-target")
                            /\ RoutingPolicy = "EJavaFlush"
                            /\ ~fastPath
                        \* Slow path: emit downstream probe on self's own
                        \* outbox to the current resolver.  refId starts at
                        \* the resolverRefId (mirroring how a fresh
                        \* op:deliver-only is wire-tagged); ApplyRoute
                        \* would mutate it at each forward.
                        probeMsg ==
                            OpEFlushProbe(self, r, entry.resolverRefId)
                        \* Block withdraw-promise Promise resolutions while
                        \* the chain binder ref is still under EJavaFlush
                        \* embargo (handoff-give slow path on refs[cr]).
                        handoffPwBlocked ==
                            /\ isHandoffPw
                            /\ v.desc \in {"desc:import-promise",
                                           "desc:export-promise"}
                            /\ RoutingPolicy = "EJavaFlush"
                            /\ \E cr \in ChainRefs \intersect DOMrefs(self) :
                                 /\ LocalRef(self, cr).kind = "RemotePromise"
                                 /\ LocalRef(self, cr).localResolution =
                                        ResRef(self, r)
                                 /\ LocalRef(self, cr).embargo # {}
                    IN
                       /\ ~handoffPwBlocked
                       /\ entry # EntryNone
                       /\ entry.kind = "RemotePromise"
                       /\ (CASE installNow
                                -> LET ChainBinderPred(cr) ==
                                           /\ LocalRef(self, cr).kind =
                                                  "RemotePromise"
                                           /\ LocalRef(self, cr)
                                                  .localResolution =
                                                  ResRef(self, r)
                                       chainBinderExists ==
                                           /\ isHandoffPw
                                           /\ \E cr \in ChainRefs
                                                  \intersect DOMrefs(self) :
                                                  ChainBinderPred(cr)
                                       chainBinder ==
                                           CHOOSE cr \in ChainRefs
                                               \intersect DOMrefs(self) :
                                                  ChainBinderPred(cr)
                                       vatsBase ==
                                           [vats EXCEPT
                                               ![self].refs[r].localResolution =
                                                   newLocalRes,
                                               \* OpFlush op:resolve install:
                                               \* remove the matching source
                                               \* (= `from`, the resolver who
                                               \* sent the op:flush) from the
                                               \* refid-scoped embargo set.
                                               \* For EJavaFlush this branch
                                               \* fires on the fast path or
                                               \* withdraw-promise paths;
                                               \* embargo is already {} so the
                                               \* set-difference is a no-op.
                                               ![self].refs[r].embargo =
                                                   entry.embargo \ {from}]
                                   IN /\ vats' =
                                          IF /\ RoutingPolicy =
                                                    "OpFlushProtocol"
                                             /\ chainBinderExists
                                          THEN [vatsBase EXCEPT
                                                    ![self].refs[chainBinder]
                                                        .embargo =
                                                        LocalRef(self, chainBinder).embargo
                                                          \ {LocalRef(self, chainBinder).resolverPeer}]
                                          ELSE vatsBase
                                      /\ channels' = ch0
                            [] embargoInstead
                                -> /\ vats' =
                                       [vats EXCEPT
                                           ![self].refs[r].localResolution = newLocalRes,
                                           \* EJavaFlush slow path: add the
                                           \* source (= `from`, the
                                           \* resolverPeer who sent this
                                           \* op:resolve) to the refid-scoped
                                           \* embargo set.  Probe-ack will
                                           \* remove it on receipt.
                                           ![self].refs[r].embargo =
                                               entry.embargo \cup {from}]
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
                 \*
                 \* CHAIN-FORM RACE under flush protocols.  Receiving
                 \* a chain-form desc:handoff-give rebinds
                 \* vats[self].refs[targetRefId].localResolution from
                 \* ResNone to ResRef(self, pw).  Future sends through
                 \* targetRefId now take the NEW direct route to tgtHost
                 \* via pw, while in-flight pipelined sends on the OLD
                 \* route (channels[self][resolverPeer] and downstream)
                 \* may not yet have reached tgtHost.  This is the
                 \* identical race that desc:import-target/desc:export-
                 \* target faces, and it must be guarded by the same
                 \* flush dispatch:
                 \*
                 \*   EJavaFlush.  Apply the subscriber-side fast/slow
                 \*   dispatch on vats[self].refs[targetRefId]:
                 \*     - fastPath when targetRefId is `fresh`
                 \*       (nothing was ever pipelined through it) --
                 \*       install immediately.  sameConnection cannot
                 \*       apply: tgtHost is by construction a third
                 \*       peer (NeedsHandoffIntro held at the gifter).
                 \*     - else slow path: set embargo on
                 \*       vats[self].refs[targetRefId] AND emit
                 \*       op:e-flush-probe on the OLD wire
                 \*       channels[self][resolverPeer].  The probe
                 \*       queues behind any in-flight forwards and the
                 \*       ack returns only after they reach the
                 \*       eventual target.  ProcessHold then drains
                 \*       vats[self].refs[targetRefId].pending through
                 \*       the (now committed) localResolution = pw,
                 \*       which Route follows to a direct wire to
                 \*       tgtHost.
                 \*
                 \*   OpFlushProtocol.  The op:resolve from the
                 \*   resolver is itself the post-flush notification:
                 \*   listener `self` had already set embargo on
                 \*   refs[targetRefId] when it processed op:flush, and
                 \*   the resolver has since performed the
                 \*   resolver-initiated op:e-flush-probe roundtrip
                 \*   through tgtHost.  Clear the embargo so
                 \*   ProcessHold can drain pending through the new pw.
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
                        chainEntry ==
                            IF isChain /\ chainBindable
                            THEN LocalRef(self, targetRefId) ELSE EntryNone
                        chainFresh ==
                            /\ isChain
                            /\ chainBindable
                            /\ chainEntry.fresh
                        chainEmbargo ==
                            /\ isChain
                            /\ RoutingPolicy = "EJavaFlush"
                            /\ ~chainFresh
                        \* Under EJavaFlush the chain handoff-give slow
                        \* path uses chainEmbargo + chainProbe (probe
                        \* rides the old chain back through the listener's
                        \* resolverPeer wire) to fence the path change.
                        \* Other policies leave chainEmbargo / chainProbe
                        \* unused.
                        chainProbe ==
                            OpEFlushProbe(self, targetRefId,
                                          chainEntry.resolverRefId)
                    IN
                       /\ (CASE accept /\ isChain
                                -> /\ vats' =
                                        [vats EXCEPT
                                            ![self].refs[pw] =
                                                MkRemotePromise(
                                                    tgtHost,
                                                    pw,
                                                    ResNone,
                                                    {},
                                                    << >>,
                                                    TRUE,
                                                    TRUE,
                                                    FALSE),
                                            ![self].refs[targetRefId].localResolution =
                                                ResRef(self, pw),
                                            \* EJavaFlush slow path adds the
                                            \* sender (`from`) to the embargo
                                            \* set; other policies leave the
                                            \* embargo untouched.
                                            ![self].refs[targetRefId].embargo =
                                                IF chainEmbargo
                                                THEN chainEntry.embargo \cup {from}
                                                ELSE chainEntry.embargo]
                                   /\ channels' =
                                        LET ch1 == AppendToOutbox(ch0, self,
                                                       tgtHost,
                                                       OpWithdrawGift(gid,
                                                           gifter, pw))
                                        IN IF chainEmbargo
                                           THEN AppendToOutbox(ch1, self,
                                                    chainEntry.resolverPeer,
                                                    chainProbe)
                                           ELSE ch1
                            [] accept /\ ~isChain
                                -> /\ vats' =
                                        [vats EXCEPT
                                            ![self].refs[pw] =
                                                MkRemotePromise(
                                                    tgtHost,
                                                    pw,
                                                    ResNone,
                                                    {},
                                                    << >>,
                                                    TRUE,
                                                    TRUE,
                                                    FALSE)]
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
                                accepted |-> accept,
                                embargoed |-> chainEmbargo])
              \/ \* op:flush  (Ridley, OpFlushProtocol only).  Receiver
                 \* `self` is the resolver-holder of the LocalPromise at
                 \* msg.toDescRefId; sender `from` is the would-be
                 \* shortener.  Per notes/flush-protocols.md §9 step 2,
                 \* `self` MUST: (a) mint a fresh local promise `p'`
                 \* at a NEW refId slot (allocated from nextRefId); (b)
                 \* fulfill the old resolver `r` with `p'` -- modelled
                 \* by setting refs[r].resolution = ResRef(self, p'),
                 \* which causes future sends through r to cascade onto
                 \* p' via the standard intra-vat queue machinery; (c)
                 \* emit the flush response op:resolve(resolveMeRefId,
                 \* desc:import-promise(p')) back on channels[self][from].
                 \* Implicit GC of the old r is NOT modelled (the slot
                 \* stays live but is now resolved-to-p').
                 \*
                 \* Refused (silent drop) if the old resolver `r` does
                 \* not exist at self as an unresolved LocalPromise --
                 \* second concurrent flush against the same r cannot
                 \* fulfill r twice; Ridley §9 v0 limitation.
                 /\ msg.op = "op:flush"
                 /\ RoutingPolicy = "OpFlushProtocol"
                 /\ LET r == msg.toDescRefId
                        rm == msg.resolveMeRefId
                        entry == LocalRef(self, r)
                        freshP == nextRefId
                        validFlush ==
                            /\ entry # EntryNone
                            /\ entry.kind = "LocalPromise"
                            /\ entry.resolution = ResNone
                            /\ freshP \in RefIds
                    IN
                       /\ (CASE validFlush
                                -> /\ vats' =
                                        [vats EXCEPT
                                            \* Fulfill r with p'.
                                            ![self].refs[r].resolution =
                                                ResRef(self, freshP),
                                            ![self].refs[r].notified = TRUE,
                                            \* Mint p' as a fresh LocalPromise
                                            \* at this peer, ready to absorb the
                                            \* future eventual resolution and
                                            \* hold the buffered sends.
                                            ![self].refs[freshP] =
                                                MkLocalPromise(<< >>, {}, ResNone,
                                                    {}, FALSE, FALSE, {})]
                                   /\ nextRefId' = freshP + 1
                                   /\ channels' =
                                        AppendToOutbox(ch0, self, from,
                                            OpResolve(rm,
                                                DescImportPromise(freshP)))
                            [] OTHER
                                -> \* Silent drop: cannot serve a second
                                   \* concurrent flush against the same r.
                                   /\ channels' = ch0
                                   /\ UNCHANGED << vats, nextRefId >>)
                       /\ UNCHANGED << host, sent, delivered >>
                       /\ HandoffVarsUnchanged
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "flush",
                                from |-> from,
                                to |-> self,
                                refId |-> msg.toDescRefId])
              \/ \* op:e-flush-probe.  EJavaFlush-only sentinel
                 \* (subscriber-initiated slow path).  Rides the
                 \* pipelined path exactly like an op:deliver-only:
                 \* dispatch by Route over LocalRef(self, r), then
                 \* ApplyRoute.  Terminal "deliver" tag at a LocalTarget
                 \* is intercepted by ApplyRoute (polymorphic on msg.op)
                 \* to emit OpEFlushProbeAck back to msg.originPeer on
                 \* `self`'s own outbox, rather than appending to
                 \* `delivered`.  Probes that hit an unresolved
                 \* LocalPromise or an embargoed RemotePromise correctly
                 \* queue/hold and are later drained by ProcessPending
                 \* / ProcessHold.
                 /\ msg.op = "op:e-flush-probe"
                 /\ RoutingPolicy = "EJavaFlush"
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
              \/ \* op:e-flush-probe-ack.  EJavaFlush only -- the
                 \* originator is a subscriber holding a RemotePromise;
                 \* ack lifts that promise's refid-scoped embargo so
                 \* ProcessHold can drain the locally-buffered pending
                 \* sends to the newly committed post-resolution path.
                 \* OpFlushProtocol does NOT emit probes; its drain
                 \* proof is per-session FIFO (see Ridley §9 / §9.1
                 \* implementation pointer).
                 /\ msg.op = "op:e-flush-probe-ack"
                 /\ RoutingPolicy = "EJavaFlush"
                 /\ LET r == msg.originRefId
                        entry == LocalRef(self, r)
                        \* Apply the ack effect only when the local
                        \* state still matches what the ack was issued
                        \* against; otherwise drop the ack (consume from
                        \* the channel) so it doesn't block subsequent
                        \* messages on this FIFO.
                        liftEmbargo ==
                            /\ entry # EntryNone
                            /\ entry.kind = "RemotePromise"
                            /\ entry.embargo # {}
                    IN
                       /\ (CASE liftEmbargo
                                -> vats' =
                                       [vats EXCEPT
                                           ![self].refs[r].embargo =
                                               entry.embargo
                                                   \ {entry.resolverPeer}]
                            [] OTHER -> UNCHANGED vats)
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
                        \* Late-subscribe immediate-reply only when the
                        \* listener is two-party with the target; the
                        \* 3-party handoff-give path requires gift
                        \* allocation and is not implemented for the
                        \* late-listen flow.  3-party listeners fall
                        \* through to OTHER and are recorded silently;
                        \* notes/path-changes.md tracks the gap.
                        alreadyResolvedToTarget ==
                            /\ res # ResNone
                            /\ IsResolutionTarget(self, res)
                            /\ ~NeedsHandoffIntro(self, from,
                                   TargetHostPeer(self, res))
                    IN
                       /\ entry # EntryNone
                       /\ entry.kind = "LocalPromise"
                       /\ (CASE alreadyResolvedToTarget
                                -> \* Subscribe-to-already-resolved with a
                                   \* terminal value: immediate op:resolve reply.
                                   \* Listener is also recorded for bookkeeping.
                                   LET value == ResolveValueFor(self, res, from)
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
                                    MkLocalPromise(
                                                   << >>,
                                                   {rcp},
                                                   ResNone,
                                                   {},
                                                   FALSE,
                                                   FALSE,
                                                   {})]
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
                 \*       op:resolve(pw, desc:import-target), clear the gift.
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
                        \* Phase B (notes/path-changes.md §3.9): the gift's
                        \* target on `self` may be a LocalTarget (the
                        \* classic 3PHO case) OR a LocalPromise (an
                        \* inter-vat promise gift -- e.g. a chain-form
                        \* handoff-give whose underlying cap was a chain
                        \* LocalPromise).  Dispatch on the kind to pick
                        \* the matching receiver-relative descriptor:
                        \*   LocalTarget  -> desc:import-target(tlr)
                        \*   LocalPromise -> desc:import-promise(tlr)
                        \* Either way the recipient's RemotePromise(pw)
                        \* receives the descriptor and installs
                        \* localResolution = ResRef(self, tlr).  When
                        \* the cap is a promise, the pre-minted
                        \* LocalPromise(pw).resolution becomes
                        \* ResRef(self, tlr) where tlr is itself a
                        \* LocalPromise on self -- intra-vat promise
                        \* shortening that drains via the existing
                        \* cascade in Route.
                        tlrKind ==
                            IF recipientOK THEN LocalRef(self, tlr).kind
                                            ELSE "none"
                        resVal ==
                            IF tlrKind = "LocalPromise"
                            THEN DescImportPromise(tlr)
                            ELSE DescImportTarget(tlr)
                    IN
                       /\ depositSeen
                       /\ (CASE recipientOK
                                -> \* All steps fused atomically so the
                                   \* PairingInvariant is satisfied at the
                                   \* state boundary.  The LocalPromise(pw)
                                   \* was pre-minted on deposit; we now only
                                   \* install its resolution.
                                   /\ tlrKind \in {"LocalTarget", "LocalPromise"}
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
                  /\ r # srcRef  \* Phase B (notes/path-changes.md §3.9):
                                  \* chain-form must rebind a DIFFERENT
                                  \* ref than the cap being gifted, or
                                  \* the withdraw response can cycle the
                                  \* recipient's localResolution
                                  \* (refs[r].localResolution = pw and
                                  \* pw.localResolution = ResRef(_, r))
                                  \* under v0 globally-shared chain
                                  \* refIds when the cap is a Promise.
                  /\ LocalRef(self, r).kind \in
                         {"LocalPromise", "RemotePromise"}} :
            /\ EnableHandoff
            /\ EnableHandoffInitiate
            /\ self # recipient
            \* Phase B (notes/path-changes.md §3.9): allow gifting a
            \* RemotePromise cap as well as a RemoteTarget.  The wire
            \* shape is identical (op:deposit-gift to capHost +
            \* op:resolve with desc:handoff-give to recipient); the
            \* only difference is that the target host's pre-minted
            \* LocalPromise(pw) resolves to a LocalPromise on withdraw
            \* (intra-vat shortening cascade) instead of a LocalTarget.
            /\ LocalRef(self, srcRef).kind \in {"RemoteTarget", "RemotePromise"}
            /\ LET srcEntry == LocalRef(self, srcRef)
                   targetHost ==
                       IF srcEntry.kind = "RemoteTarget"
                       THEN srcEntry.targetPeer
                       ELSE srcEntry.resolverPeer
                   targetLocalRef ==
                       IF srcEntry.kind = "RemoteTarget"
                       THEN srcEntry.targetRefId
                       ELSE srcEntry.resolverRefId
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
    \/ InitiateFlush
    \/ RepropagatePromiseShorten
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
    /\ WF_vars(InitiateFlush)
    /\ WF_vars(RepropagatePromiseShorten)
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
(* Currently HeadPeer is the only originator of ref-1 op:deliver-only, so
   only the (HeadPeer, 1) pair has non-empty `seqs`.  Multi-sender FIFO
   coverage is tracked in notes/path-changes.md §3.4. *)
EndToEndRefFIFO ==
    \A sender \in {HeadPeer}, ref \in {1} :
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
(* Wire descriptor contract: desc:handoff-give only for third-party refs;
   two-party introductions use import/export descriptors. *)

WireDescriptorContract ==
    \A sender, receiver \in Peers :
        \A i \in 1..Len(channels[sender][receiver]) :
            LET msg == channels[sender][receiver][i]
            IN (msg.op # "op:resolve") \/
               (msg.value.desc # "desc:handoff-give") \/
               msg.value.targetHost \notin {sender, receiver}

(* Every op:resolve in flight carries a known descriptor: either
   desc:handoff-give (3-party introduction) or one of the import/export
   TargetWireDescs (2-party introduction).  Despite the historical name,
   this does NOT restrict to 2-party; that constraint is in
   WireDescriptorContract above. *)
OnlyKnownResolveDescriptors ==
    \A sender, receiver \in Peers :
        \A i \in 1..Len(channels[sender][receiver]) :
            LET msg == channels[sender][receiver][i]
            IN (msg.op # "op:resolve") \/
               (msg.value.desc = "desc:handoff-give") \/
               msg.value.desc \in TargetWireDescs

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
