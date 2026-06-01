--------------------------- MODULE References ---------------------------
(***************************************************************************)
(* Reference taxonomy:                                                      *)
(*   Reference        = Promise | Target                                   *)
(*   Promise          = LocalPromise | RemotePromise                       *)
(*   Target           = LocalTarget | RemoteTarget                         *)
(*                                                                         *)
(* All per-peer state lives in a single `vats[p]` record declared in     *)
(* lib/PeerState.tla, so every per-peer write structurally takes the form *)
(*   vats' = [vats EXCEPT ![self].refs[r]... = ...]                       *)
(* and a reviewer can grep `[vats EXCEPT !\[` to verify every site keys   *)
(* on `self`.  See ../notes/locality-contract.md section 7 for the full   *)
(* locality contract that this shape enforces.                            *)
(*                                                                         *)
(* This module owns the Reference taxonomy types and constructors, the    *)
(* immutable chain-topology VARIABLE `host`, and the MkChainRefs           *)
(* constructor used by Init to lay down the initial refs slice of vats.   *)
(*                                                                         *)
(* Per-peer accessors (LocalRef, LocalRefs, ...) and PairingInvariant     *)
(* live in lib/PeerState.tla, where the `vats` VARIABLE is in scope.      *)
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

MkLocalPromise(queue, listeners, resolution, flushPending,
               notified, repropNotified, pipelinedListeners) ==
    [kind |-> "LocalPromise",
     queue |-> queue,
     listeners |-> listeners,
     resolution |-> resolution,
     flushPending |-> flushPending,
     notified |-> notified,
     repropNotified |-> repropNotified,
     pipelinedListeners |-> pipelinedListeners]

(* `fresh` is the sticky bit on a *local* RemotePromise presence only
   (e-on-java RemotePromiseHandler.myFreshFlag / EProxyHandler.isFresh).
   TRUE at construction; cleared FALSE the first time this peer pipelines
   anything through that imported promise (wire send or local hold buffer).
   Not stored on the resolver's paired LocalPromise and never read
   cross-vat.  Consulted by the EJavaFlush fast path: a fresh RemotePromise can
   commit to the post-resolution path immediately, with no end-to-end
   flush sentinel, because no in-flight or downstream-buffered message
   could race the new path.  See the long "EJavaFlush protocol" block
   in spec/PromiseResolution.tla for the protocol-level rationale and
   source citations.
   `flushSent` is OpFlushProtocol's shortener-side bookkeeping: TRUE
   after this peer has fired InitiateFlush against this entry, FALSE
   otherwise.  Prevents re-firing for the same RemotePromise.  Unused
   under other policies. *)
MkRemotePromise(resolverPeer, resolverRefId, localResolution,
                embargo, pending, listenSent, fresh, flushSent) ==
    [kind |-> "RemotePromise",
     resolverPeer |-> resolverPeer,
     resolverRefId |-> resolverRefId,
     localResolution |-> localResolution,
     embargo |-> embargo,
     pending |-> pending,
     listenSent |-> listenSent,
     fresh |-> fresh,
     flushSent |-> flushSent]

----------------------------------------------------------------------------
(* host[i]: derived alias for "the peer hosting refId i's LocalX entry".  *)
(* Used by MCs to pin chain shape; the spec also uses it for routing.     *)

VARIABLES
    host    \* [ChainRefs -> Peers]

(* Resolution type (kind, peer?, refId?). *)
ResolutionType ==
    {ResNone}
    \cup [kind: {"ref"}, peer: Peers, refId: RefIds]

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
          repropNotified: BOOLEAN,
          pipelinedListeners: SUBSET Peers]
    \cup [kind: {"RemotePromise"},
          resolverPeer: Peers,
          resolverRefId: RefIds,
          localResolution: ResolutionType,
          \* embargo: refId-scoped — set of source peers with an
          \* outstanding flush against this listener-ref.  Empty set =
          \* not embargoed.  Add the source on flush-event (EJavaFlush
          \* slow path / chain handoff-give slow path), remove on
          \* resolution-event (matching probe-ack).  Boolean
          \* check `# {}` everywhere the old code tested `entry.embargo`.
          \* OpFlushProtocol no longer uses embargo at all (under
          \* faithful Ridley, buffering happens at the resolver-holder
          \* via the standard LocalPromise queue cascade once the old
          \* resolver is fulfilled with the fresh p').
          embargo: SUBSET Peers,
          pending: Seq(Messages),
          listenSent: BOOLEAN,
          fresh: BOOLEAN,
          flushSent: BOOLEAN]

----------------------------------------------------------------------------
(* Chain-refs constructor: given a host function and a listeners function,  *)
(* build the pinned-chain refs table -- the `refs` slice of a freshly       *)
(* initialised vat.  Used by PromiseResolutionInit to assemble vats in a    *)
(* policy-aware way.                                                        *)

MkChainRefs(h, listenersFn) ==
    [p \in Peers |->
        [r \in RefIds |->
            IF r \notin ChainRefs THEN EntryNone
            ELSE IF r = TerminalPos
            THEN IF h[r] = p THEN MkLocalTarget
                 ELSE MkRemoteTarget(h[r], r)
            ELSE IF h[r] = p
            THEN MkLocalPromise(<< >>, listenersFn[r], ResNone, {},
                                FALSE, FALSE, {})
            ELSE MkRemotePromise(h[r], r, ResNone, {}, << >>,
                                 FALSE, TRUE, FALSE)
        ]
    ]

============================================================================
