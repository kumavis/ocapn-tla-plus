--------------------------- MODULE References ---------------------------
(***************************************************************************)
(* Reference taxonomy:                                                      *)
(*   Reference        = Promise | Target                                   *)
(*   Promise          = LocalPromise | RemotePromise                       *)
(*   Target           = LocalTarget | RemoteTarget                         *)
(*                                                                         *)
(* Per-peer state: refs[p][r] is the entry for refId r on peer p, OR the   *)
(* sentinel EntryNone for unallocated slots.                               *)
(*                                                                         *)
(* v0 globally-shared refIds: a single integer r identifies the same       *)
(* logical capability everywhere it appears.  For the pinned chain shape   *)
(*   HeadPeer -> p_1@host[1] -> ... -> p_{N-1}@host[N-1] -> T@host[N]      *)
(* refIds 1..ChainLength-1 are promises; ChainLength is the terminal.      *)
(* Higher refIds (> ChainLength) are reserved for 3PHO withdraw-promise    *)
(* allocations.  See ../notes/path-changes.md for the path-change          *)
(* taxonomy these entries support (promise resolution and intra-vat        *)
(* promise shortening).                                                    *)
(***************************************************************************)

EXTENDS Naturals, Sequences

CONSTANT Peers, ChainLength, HeadPeer, MaxRefId

ASSUME Peers # {}
ASSUME HeadPeer \in Peers
ASSUME /\ ChainLength \in Nat
       /\ ChainLength >= 2
ASSUME /\ MaxRefId \in Nat
       /\ MaxRefId >= ChainLength

RefIds == 1..MaxRefId
ChainRefs == 1..ChainLength
TerminalPos == ChainLength

----------------------------------------------------------------------------
(* Entry constructors and the EntryNone sentinel. *)

EntryNone == [kind |-> "none"]

MkLocalTarget == [kind |-> "LocalTarget"]

MkRemoteTarget(targetPeer, targetRefId) ==
    [kind |-> "RemoteTarget",
     targetPeer |-> targetPeer,
     targetRefId |-> targetRefId]

(* Resolution values: stored in LocalPromise.resolution or
   RemotePromise.localResolution.  Either "none" or a (peer, refId)
   pointer; lookup of the pointed-to entry determines the kind. *)

ResNone == [kind |-> "none"]

ResRef(peer, refId) ==
    [kind |-> "ref",
     peer |-> peer,
     refId |-> refId]

(* `flushPhase` is OpFlushProtocol's resolver-side bookkeeping for the
   target-flush probe + ack roundtrip.  Tristate:
     "idle"    -- no probe sent (initial state, and the steady state
                  under any policy other than OpFlushProtocol).
     "out"     -- probe sent on channels[resolver][target], awaiting
                  op:e-flush-probe-ack.  SendTargetFlushProbe transitions
                  "idle" -> "out" exactly once per promise resolution.
     "acked"   -- ack received.  SendOpResolveAfterFlush requires this.
   When the resolver is itself the target host, SendTargetFlushProbe
   goes directly "idle" -> "acked" without emitting any probe (no
   cross-vat hop to flush). *)
MkLocalPromise(queue, listeners, resolution, flushPending,
               notified, flushPhase) ==
    [kind |-> "LocalPromise",
     queue |-> queue,
     listeners |-> listeners,
     resolution |-> resolution,
     flushPending |-> flushPending,
     notified |-> notified,
     flushPhase |-> flushPhase]

(* `fresh` is the sticky bit modelling e-on-java's RemotePromiseHandler.
   isFresh (set TRUE at construction, cleared FALSE the first time
   anything is pipelined through this RemotePromise's resolver wire).
   Consulted by the EJavaFlush fast path: a fresh RemotePromise can
   commit to the post-resolution path immediately, with no end-to-end
   flush sentinel, because no in-flight or downstream-buffered message
   could race the new path.  See the long "EJavaFlush protocol" block
   in spec/PromiseResolution.tla for the protocol-level rationale and
   source citations. *)
MkRemotePromise(resolverPeer, resolverRefId, localResolution,
                embargo, pending, listenSent, fresh) ==
    [kind |-> "RemotePromise",
     resolverPeer |-> resolverPeer,
     resolverRefId |-> resolverRefId,
     localResolution |-> localResolution,
     embargo |-> embargo,
     pending |-> pending,
     listenSent |-> listenSent,
     fresh |-> fresh]

----------------------------------------------------------------------------
(* host[i]: derived alias for "the peer hosting refId i's LocalX entry".  *)
(* Used by MCs to pin chain shape; the spec also uses it for routing.     *)

VARIABLES
    host,    \* [ChainRefs -> Peers]
    refs     \* [Peers -> [RefIds -> Entry]]

(* Resolution type (kind, peer?, refId?). *)
ResolutionType ==
    {ResNone}
    \cup [kind: {"ref"}, peer: Peers, refId: RefIds]

FlushPhases == {"idle", "out", "acked"}

(* Per-message-type Entry, with Messages a parameter. *)
RefEntryType(Messages) ==
    {EntryNone, MkLocalTarget}
    \cup [kind: {"RemoteTarget"}, targetPeer: Peers, targetRefId: RefIds]
    \cup [kind: {"LocalPromise"},
          queue: Seq(Messages),
          listeners: SUBSET Peers,
          resolution: ResolutionType,
          flushPending: SUBSET Peers,
          notified: BOOLEAN,
          flushPhase: FlushPhases]
    \cup [kind: {"RemotePromise"},
          resolverPeer: Peers,
          resolverRefId: RefIds,
          localResolution: ResolutionType,
          embargo: BOOLEAN,
          pending: Seq(Messages),
          listenSent: BOOLEAN,
          fresh: BOOLEAN]

(* Domain of allocated entries on peer p. *)
DOMrefs(p) == {r \in RefIds : refs[p][r] # EntryNone}

----------------------------------------------------------------------------
(* Per-actor locality accessors.  Every protocol action in
   spec/PromiseResolution.tla is required to read its own ref table only;
   these accessors give a name to the locality-respecting access pattern so
   a reviewer can grep for direct refs[X][Y] indexing and confirm every
   such site is either inside an accessor definition here or inside a
   tightly-scoped EXCEPT update.  See ../notes/locality-contract.md.

   `self` is the bound actor; passing any other peer in this slot is by
   convention a locality violation and should be justified inline. *)

LocalRefs(self)          == refs[self]
LocalRef(self, r)        == refs[self][r]
LocalRefAllocated(self, r) == refs[self][r] # EntryNone

(* EXCEPT-wrappers that thread `self` through the update.  These do not
   change the underlying semantics (TLA+ requires EXCEPT to be inlined at
   the call site for field updates), but they give a single place where
   a reviewer can verify that all in-place writes are scoped to the
   actor's own slice. *)
SetLocalRef(refs0, self, r, entry) ==
    [refs0 EXCEPT ![self][r] = entry]

----------------------------------------------------------------------------
(* PairingInvariant: every RemoteX has a matching LocalX on its target.  *)

PairingInvariant ==
    /\ \A p \in Peers : \A r \in DOMrefs(p) :
         refs[p][r].kind = "RemoteTarget" =>
            LET q == refs[p][r].targetPeer
                rq == refs[p][r].targetRefId
            IN /\ rq \in DOMrefs(q)
               /\ refs[q][rq].kind = "LocalTarget"
    /\ \A p \in Peers : \A r \in DOMrefs(p) :
         refs[p][r].kind = "RemotePromise" =>
            LET q == refs[p][r].resolverPeer
                rq == refs[p][r].resolverRefId
                \* A handoff withdraw-promise is keyed by the resolver-side
                \* refId, which is allocated above ChainLength by
                \* HandoffInitiate's nextRefId.  The holder-side refId (r) may
                \* be a chain ref (1..ChainLength) when the recipient binds
                \* the handoff onto an existing forwarder, so we cannot key
                \* the relaxation on r.
                isHandoffPromise == rq > ChainLength
            IN \/ /\ isHandoffPromise
                  /\ rq \notin DOMrefs(q)  \* transitional: target host has
                                            \* not yet pre-minted the LocalPromise
                                            \* (will happen on op:deposit-gift).
               \/ /\ rq \in DOMrefs(q)
                  /\ refs[q][rq].kind = "LocalPromise"

----------------------------------------------------------------------------
(* Chain-refs constructor: given a host function and a listeners function,  *)
(* build the pinned-chain refs table.  Used by the spec module to assemble  *)
(* Init in a policy-aware way.                                              *)

MkChainRefs(h, listenersFn) ==
    [p \in Peers |->
        [r \in RefIds |->
            IF r \notin ChainRefs THEN EntryNone
            ELSE IF r = TerminalPos
            THEN IF h[r] = p THEN MkLocalTarget
                 ELSE MkRemoteTarget(h[r], r)
            ELSE IF h[r] = p
            THEN MkLocalPromise(<< >>, listenersFn[r], ResNone, {},
                                FALSE, "idle")
            ELSE MkRemotePromise(h[r], r, ResNone, FALSE, << >>, FALSE, TRUE)
        ]
    ]

============================================================================
