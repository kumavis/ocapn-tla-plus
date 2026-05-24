------------------------- MODULE PromiseResolution -------------------------
(***************************************************************************)
(* OCapN-flavored reference taxonomy with kind-discriminated dispatch.    *)
(*                                                                         *)
(* Per-peer refs[p][r] entries (one of):                                   *)
(*   LocalTarget    -- a sink owned by p                                   *)
(*   RemoteTarget   -- presence for someone else's LocalTarget             *)
(*   LocalPromise   -- p is the resolver; holds queue, listeners,         *)
(*                     resolution, flushPending, notified                  *)
(*   RemotePromise  -- presence for someone else's LocalPromise; holds     *)
(*                     localResolution, embargo, flushPhase                *)
(*                                                                         *)
(* Routing is a single dispatch over refs[self][r].kind plus the          *)
(* localResolution / resolution recursion (local shortening at send time). *)
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
(*   "EJavaFlush"              on op:resolve(r, _) at L: if the wire L    *)
(*                              uses to forward through refs[L][r] still   *)
(*                              has in-flight op:deliver-only sends        *)
(*                              (RefHasPipelinedForwards), embargo +       *)
(*                              remember value; wait for local signal      *)
(*                              (channels[L][resolver] drained of          *)
(*                              op:deliver-only); then install + lift.     *)
(*                              Canonical kpreid race on 4-chains.         *)
(*   "OpFlushProtocol"         resolver-initiated: ResolverResolve sends   *)
(*                              op:flush(r) instead of op:resolve.         *)
(*                              Listener embargos, drains its outgoing to  *)
(*                              resolver, sends op:flush-ack. Resolver     *)
(*                              waits for all acks AND its own queue+      *)
(*                              outgoing-to-target drained, then sends     *)
(*                              op:resolve. Holds.                         *)
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

(* Phase 3 -- opaque 3PHO wire messages. *)

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
   recipient (chain case -- forwarder shortens to pw) or (b) pw itself
   (standalone case -- recipient mints a brand-new ref). *)

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
(* Dispatch via the reference table.  Returns a record with .tag:
     "deliver" - apply msg locally (peer hosts a LocalTarget)
     "wire"    - append op:deliver-only to channels[self][.peer] with
                 refId = .refId
     "queue"   - append msg to refs[self][.refId].queue (a LocalPromise
                 we own that's still unresolved)
     "deadEnd" - no usable route; shouldn't happen in v0 chains *)

(* Routing dispatch.  Returns one of:
     [tag |-> "deliver", peer, refId]      apply locally (LocalTarget sink)
     [tag |-> "wire",    peer, refId]      append op:deliver-only on
                                           channels[self][peer] with refId
     [tag |-> "queue",   peer, refId]      enqueue into local LocalPromise.queue
     [tag |-> "hold",    peer, refId]      enqueue into local RemotePromise.pending
                                           (OpFlushProtocol embargo)
     [tag |-> "deadEnd"]                   unallocated; shouldn't happen *)

RECURSIVE RouteRec(_, _)
RouteRec(self, r) ==
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
                 ELSE RouteRec(self, entry.resolution.refId)
       ELSE (* RemotePromise *)
            IF /\ RoutingPolicy = "OpFlushProtocol"
               /\ \/ entry.embargo
                  \/ Len(entry.pending) > 0
            THEN [tag |-> "hold", peer |-> self, refId |-> r]
            ELSE IF \/ entry.localResolution = ResNone
                    \/ entry.embargo
                 THEN [tag |-> "wire",
                       peer |-> entry.resolverPeer,
                       refId |-> entry.resolverRefId]
                 ELSE RouteRec(self, entry.localResolution.refId)

Route(self, r) == RouteRec(self, r)

(* RefHasPipelinedForwards: predicate "peer p has at least one in-flight
   op:deliver-only that p previously forwarded through refs[p][r]".
   Parameterized by the ref under resolution; locally observable (p reads
   only its own outgoing buffer to the resolver of r).  Used by EJavaFlush
   to skip embargo when no pre-resolve traffic exists on the about-to-be-
   shortened path.

   For an unresolved RemotePromise(r), Route(p, r) yields wire(resolverPeer,
   resolverRefId), so a previously-forwarded send via r sits on
   channels[p][resolverPeer] with refId = resolverRefId.  Messages with
   different refIds, or on channels to other peers, came from different
   refs and are irrelevant to this resolution.

   Defensive: returns FALSE for non-RemotePromise entries so callers can
   evaluate it inside a LET without separate kind guards. *)
RefHasPipelinedForwards(p, r) ==
    LET entry == refs[p][r]
    IN /\ entry # EntryNone
       /\ entry.kind = "RemotePromise"
       /\ \E i \in 1..Len(channels[p][entry.resolverPeer]) :
              LET m == channels[p][entry.resolverPeer][i]
              IN /\ m.op = "op:deliver-only"
                 /\ m.refId = entry.resolverRefId

ChannelHasDeliverOnly(p, q) ==
    \E i \in 1..Len(channels[p][q]) :
        /\ channels[p][q][i].op = "op:deliver-only"

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
    IN
        /\ sent < NumMessages
        /\ sent' = seqN
        /\ (CASE route.tag = "wire"
                -> /\ channels' =
                       NetworkAppend(channels, sender, route.peer, msg)
                   /\ UNCHANGED << refs, delivered >>
             [] route.tag = "deliver"
                -> /\ delivered' =
                       Append(delivered,
                              [sender |-> sender, ref |-> 1, seq |-> seqN])
                   /\ UNCHANGED << channels, refs >>
             [] route.tag = "queue"
                -> /\ refs' =
                       [refs EXCEPT
                           ![route.peer][route.refId].queue =
                               Append(@, msg)]
                   /\ UNCHANGED << channels, delivered >>
             [] route.tag = "hold"
                -> /\ refs' =
                       [refs EXCEPT
                           ![route.peer][route.refId].pending =
                               Append(@, msg)]
                   /\ UNCHANGED << channels, delivered >>
             [] OTHER -> FALSE)
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
           IN
              /\ (CASE route.tag = "deliver"
                      -> /\ delivered' =
                             Append(delivered,
                                    [sender |-> msg.sender,
                                     ref |-> msg.sentOnRef,
                                     seq |-> msg.seq])
                         /\ refs' = [refs EXCEPT ![p][r].queue = restQueue]
                         /\ UNCHANGED channels
                   [] route.tag = "wire"
                      -> LET m2 == [msg EXCEPT !.refId = route.refId]
                         IN /\ channels' =
                                NetworkAppend(channels, p, route.peer, m2)
                            /\ refs' =
                                [refs EXCEPT ![p][r].queue = restQueue]
                            /\ UNCHANGED delivered
                   [] route.tag = "queue"
                      -> \* Local-shortening cascade: spill onto another
                         \* LocalPromise's queue on the same peer.
                         /\ refs' =
                              [refs EXCEPT
                                  ![p][r].queue = restQueue,
                                  ![p][route.refId].queue =
                                      Append(refs[p][route.refId].queue,
                                             msg)]
                         /\ UNCHANGED << channels, delivered >>
                   [] route.tag = "hold"
                      -> \* Spill onto a held RemotePromise.pending on the
                         \* same peer (OpFlush embargo).
                         /\ refs' =
                              [refs EXCEPT
                                  ![p][r].queue = restQueue,
                                  ![p][route.refId].pending =
                                      Append(refs[p][route.refId].pending,
                                             msg)]
                         /\ UNCHANGED << channels, delivered >>
                   [] OTHER -> FALSE)
              /\ UNCHANGED << host, sent >>
              /\ HandoffVarsUnchanged
              /\ Mark([name |-> "ProcessPending",
                       actor |-> p,
                       fromRefId |-> r,
                       nextRefId |-> nextR,
                       tag |-> route.tag,
                       seq |-> msg.seq])

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
           IN
              /\ (CASE route.tag = "deliver"
                      -> /\ delivered' =
                             Append(delivered,
                                    [sender |-> msg.sender,
                                     ref |-> msg.sentOnRef,
                                     seq |-> msg.seq])
                         /\ refs' = [refs EXCEPT ![p][r].pending = restPending]
                         /\ UNCHANGED channels
                   [] route.tag = "wire"
                      -> LET m2 == [msg EXCEPT !.refId = route.refId]
                         IN /\ channels' =
                                NetworkAppend(channels, p, route.peer, m2)
                            /\ refs' =
                                [refs EXCEPT ![p][r].pending = restPending]
                            /\ UNCHANGED delivered
                   [] route.tag = "queue"
                      -> /\ refs' =
                              [refs EXCEPT
                                  ![p][r].pending = restPending,
                                  ![p][route.refId].queue =
                                      Append(refs[p][route.refId].queue,
                                             msg)]
                         /\ UNCHANGED << channels, delivered >>
                   [] OTHER -> FALSE)
              /\ UNCHANGED << host, sent >>
              /\ HandoffVarsUnchanged
              /\ Mark([name |-> "ProcessHold",
                       actor |-> p,
                       refId |-> r,
                       tag |-> route.tag,
                       seq |-> msg.seq])

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
(* Send op:resolve to listeners after flush round-trip completes.          *)
(* Preconditions:                                                          *)
(*   - resolution set, target-bearing                                      *)
(*   - flushPending = {}  (all listeners acked)                            *)
(*   - notified = FALSE                                                    *)
(*   - resolver's own queue at this LocalPromise is empty                  *)
(*   - resolver's outgoing channel to the target peer is drained of       *)
(*     op:deliver-only (no in-flight pre-resolve forwards)                *)

SendOpResolveAfterFlush ==
    \E p \in Peers : \E r \in DOMrefs(p) :
        /\ RoutingPolicy = "OpFlushProtocol"
        /\ refs[p][r].kind = "LocalPromise"
        /\ refs[p][r].resolution # ResNone
        /\ IsResolutionTarget(p, refs[p][r].resolution)
        /\ refs[p][r].flushPending = {}
        /\ ~refs[p][r].notified
        /\ Len(refs[p][r].queue) = 0
        /\ LET res == refs[p][r].resolution
               value == ResolveValueFor(p, res)
               targetEntry == refs[p][res.refId]
               targetPeer ==
                   IF targetEntry.kind = "RemoteTarget"
                   THEN targetEntry.targetPeer
                   ELSE p
               listeners == refs[p][r].listeners
           IN
              /\ targetPeer = p \/ ~ChannelHasDeliverOnly(p, targetPeer)
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
                                        IN
                                           CASE route.tag = "deliver"
                                                -> /\ delivered' =
                                                        Append(delivered,
                                                               [sender |-> msg.sender,
                                                                ref |-> msg.sentOnRef,
                                                                seq |-> msg.seq])
                                                   /\ channels' = ch0
                                                   /\ UNCHANGED refs
                                                   /\ Mark([name |-> "ReceiveNetwork",
                                                            kind |-> "forward-deliver",
                                                            from |-> from,
                                                            to |-> to,
                                                            seq |-> msg.seq,
                                                            refId |-> r])
                                             [] route.tag = "wire"
                                                -> LET m2 == [msg EXCEPT !.refId = route.refId]
                                                   IN /\ channels' =
                                                          NetworkAppend(ch0, to, route.peer, m2)
                                                      /\ UNCHANGED << refs, delivered >>
                                                      /\ Mark([name |-> "ReceiveNetwork",
                                                               kind |-> "forward-wire",
                                                               from |-> from,
                                                               to |-> to,
                                                               seq |-> msg.seq,
                                                               refId |-> r,
                                                               nextRefId |-> route.refId])
                                             [] route.tag = "queue"
                                                -> \* Local-shortening: spill into another
                                                   \* LocalPromise's queue on the same peer.
                                                   /\ refs' =
                                                        [refs EXCEPT
                                                            ![to][route.refId].queue =
                                                                Append(refs[to][route.refId].queue,
                                                                       msg)]
                                                   /\ channels' = ch0
                                                   /\ UNCHANGED delivered
                                                   /\ Mark([name |-> "ReceiveNetwork",
                                                            kind |-> "forward-queue",
                                                            from |-> from,
                                                            to |-> to,
                                                            seq |-> msg.seq,
                                                            refId |-> r])
                                             [] OTHER -> FALSE
                            [] entry.kind = "RemotePromise"
                                -> LET route == Route(to, r)
                                   IN CASE route.tag = "wire"
                                          -> /\ channels' =
                                                  NetworkAppend(ch0, to, route.peer,
                                                      [msg EXCEPT !.refId = route.refId])
                                             /\ UNCHANGED << refs, delivered >>
                                             /\ Mark([name |-> "ReceiveNetwork",
                                                      kind |-> "forward-remote",
                                                      from |-> from,
                                                      to |-> to,
                                                      seq |-> msg.seq,
                                                      refId |-> r])
                                        [] route.tag = "deliver"
                                          -> /\ delivered' =
                                                  Append(delivered,
                                                         [sender |-> msg.sender,
                                                          ref |-> msg.sentOnRef,
                                                          seq |-> msg.seq])
                                             /\ channels' = ch0
                                             /\ UNCHANGED refs
                                             /\ Mark([name |-> "ReceiveNetwork",
                                                      kind |-> "forward-remote-deliver",
                                                      from |-> from,
                                                      to |-> to,
                                                      seq |-> msg.seq,
                                                      refId |-> r])
                                        [] route.tag = "queue"
                                          -> /\ refs' =
                                                  [refs EXCEPT
                                                      ![to][route.refId].queue =
                                                          Append(refs[to][route.refId].queue,
                                                                 msg)]
                                             /\ channels' = ch0
                                             /\ UNCHANGED delivered
                                             /\ Mark([name |-> "ReceiveNetwork",
                                                      kind |-> "forward-remote-queue",
                                                      from |-> from,
                                                      to |-> to,
                                                      seq |-> msg.seq,
                                                      refId |-> r])
                                        [] route.tag = "hold"
                                          -> /\ refs' =
                                                  [refs EXCEPT
                                                      ![to][route.refId].pending =
                                                          Append(refs[to][route.refId].pending,
                                                                 msg)]
                                             /\ channels' = ch0
                                             /\ UNCHANGED delivered
                                             /\ Mark([name |-> "ReceiveNetwork",
                                                      kind |-> "forward-remote-hold",
                                                      from |-> from,
                                                      to |-> to,
                                                      seq |-> msg.seq,
                                                      refId |-> r])
                                        [] OTHER -> FALSE
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
              \/ \* op:resolve carrying desc:remote-target
                 /\ msg.op = "op:resolve"
                 /\ msg.value.desc = "desc:remote-target"
                 /\ LET r == msg.targetRefId
                        v == msg.value
                        entry == refs[to][r]
                        newLocalRes == ResRef(v.peer, v.refId)
                        isPipelined == RefHasPipelinedForwards(to, r)
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
                               /\ ~isPipelined
                            \/ RoutingPolicy = "OpFlushProtocol"
                        embargoInstead ==
                            /\ ~isHandoffPw
                            /\ RoutingPolicy = "EJavaFlush"
                            /\ isPipelined
                    IN
                       /\ entry # EntryNone
                       /\ entry.kind = "RemotePromise"
                       /\ channels' = ch0
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
                            [] embargoInstead
                                -> /\ refs' =
                                       [refs EXCEPT
                                           ![to][r].localResolution = newLocalRes,
                                           ![to][r].embargo = TRUE]
                            [] OTHER -> FALSE)
                       /\ UNCHANGED << host, sent, delivered >>
                       /\ HandoffVarsUnchanged
                       /\ Mark([name |-> "ReceiveNetwork",
                                kind |-> "resolve",
                                from |-> from,
                                to |-> to,
                                refId |-> r,
                                installed |-> installNow,
                                embargoed |-> embargoInstead])
              \/ \* op:resolve carrying desc:handoff-give (Phase 3 3PHO).
                 \* Two cases dispatched by targetRefId vs pw:
                 \*   - chain (forwarder): targetRefId is an existing
                 \*     RemotePromise being shortened to pw; both refs[pw]
                 \*     (new) and refs[targetRefId].localResolution are
                 \*     installed.
                 \*   - standalone: targetRefId == pw; the recipient just
                 \*     mints the new RemotePromise at pw.
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
                                                    ResNone, FALSE, "idle",
                                                    << >>, TRUE),
                                            ![to][targetRefId].localResolution =
                                                ResRef(to, pw)]
                            [] OTHER
                                -> /\ refs' =
                                        [refs EXCEPT
                                            ![to][pw] =
                                                MkRemotePromise(tgtHost, pw,
                                                    ResNone, FALSE, "idle",
                                                    << >>, TRUE)])
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
              \/ \* op:flush  (OpFlushProtocol only)
                 /\ msg.op = "op:flush"
                 /\ RoutingPolicy = "OpFlushProtocol"
                 /\ LET r == msg.refId
                        entry == refs[to][r]
                    IN
                       /\ entry # EntryNone
                       /\ entry.kind = "RemotePromise"
                       /\ refs' =
                            [refs EXCEPT ![to][r].embargo = TRUE]
                       /\ channels' = ch0
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
              \/ \* op:listen  (Phase 2: dynamic subscription)
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
              \/ \* op:deposit-gift (Phase 3, target host).  In addition to
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
                                                   FALSE)]
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
              \/ \* op:withdraw-gift (Phase 3, target host).  Two outcomes:
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
(* SendFlushAck: at L holding an embargoed RemotePromise, send op:flush-ack
   once channels[L][resolverPeer] is drained of op:deliver-only.  Guarded
   by flushPhase = "idle" to ensure one ack per flush round. *)

SendFlushAck ==
    \E p \in Peers : \E r \in DOMrefs(p) :
        /\ RoutingPolicy = "OpFlushProtocol"
        /\ refs[p][r].kind = "RemotePromise"
        /\ refs[p][r].embargo
        /\ refs[p][r].flushPhase = "idle"
        /\ LET resolverPeer == refs[p][r].resolverPeer
           IN
              /\ ~ChannelHasDeliverOnly(p, resolverPeer)
              /\ refs' =
                   [refs EXCEPT ![p][r].flushPhase = "out"]
              /\ channels' =
                   NetworkAppend(channels, p, resolverPeer, OpFlushAck(r))
              /\ UNCHANGED << host, sent, delivered >>
              /\ HandoffVarsUnchanged
              /\ Mark([name |-> "SendFlushAck",
                       actor |-> p,
                       refId |-> r,
                       resolver |-> resolverPeer])

----------------------------------------------------------------------------
(* Listen (Phase 2): peer p holding a RemotePromise sends op:listen to the
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
(* EJavaRelease: at L holding a RemotePromise with embargo set and
   localResolution staged, lift embargo once channels[L][resolverPeer] is
   drained of op:deliver-only. *)

EJavaRelease ==
    \E p \in Peers : \E r \in DOMrefs(p) :
        /\ RoutingPolicy = "EJavaFlush"
        /\ refs[p][r].kind = "RemotePromise"
        /\ refs[p][r].embargo
        /\ refs[p][r].localResolution # ResNone
        /\ LET resolverPeer == refs[p][r].resolverPeer
           IN
              /\ ~ChannelHasDeliverOnly(p, resolverPeer)
              /\ refs' =
                   [refs EXCEPT ![p][r].embargo = FALSE]
              /\ UNCHANGED << channels, host, sent, delivered >>
              /\ HandoffVarsUnchanged
              /\ Mark([name |-> "EJavaRelease",
                       actor |-> p,
                       refId |-> r])

----------------------------------------------------------------------------
(* HandoffInitiate (Phase 3): gifter packages the gifter-side of a 3PHO
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
           the handoff shortens that ref to pw, and once pw resolves the
           recipient can dispatch r -> pw -> wire to targetHost).  *)
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

ProtocolNextExtra ==
    \/ SendFlushAck
    \/ EJavaRelease
    \/ SendOpResolveAfterFlush
    \/ ProcessHold
    \/ Listen
    \/ HandoffInitiate

BasicNext ==
    \/ PeerSend
    \/ ResolverResolve
    \/ ReceiveNetwork
    \/ ProcessPending

Next == BasicNext \/ ProtocolNextExtra

(* Fairness: weak fairness on every action that can move a message toward
   delivery.  Exposed as a named operator so MCs that override Init can
   still pick up the same fairness assumptions (via PS!Fairness) without
   restating them. *)
Fairness ==
    /\ WF_vars(PeerSend)
    /\ WF_vars(ResolverResolve)
    /\ WF_vars(ReceiveNetwork)
    /\ WF_vars(ProcessPending)
    /\ WF_vars(SendFlushAck)
    /\ WF_vars(EJavaRelease)
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
(* Phase 3 gift-table invariants.                                           *)

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
