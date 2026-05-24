--------------------------- MODULE References ---------------------------
(***************************************************************************)
(* Reference taxonomy (Phase 1b/1c refactor):                              *)
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
(* Higher refIds (> ChainLength) are reserved for Phase 3 withdraw-promise *)
(* allocations.                                                            *)
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
PromiseRefs == 1..(ChainLength - 1)
TerminalPos == ChainLength

IsObject(r) == r = TerminalPos
IsPromise(r) == r \in PromiseRefs

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

MkLocalPromise(queue, listeners, resolution, flushPending, notified) ==
    [kind |-> "LocalPromise",
     queue |-> queue,
     listeners |-> listeners,
     resolution |-> resolution,
     flushPending |-> flushPending,
     notified |-> notified]

MkRemotePromise(resolverPeer, resolverRefId, localResolution,
                embargo, flushPhase, pending, listenSent) ==
    [kind |-> "RemotePromise",
     resolverPeer |-> resolverPeer,
     resolverRefId |-> resolverRefId,
     localResolution |-> localResolution,
     embargo |-> embargo,
     flushPhase |-> flushPhase,
     pending |-> pending,
     listenSent |-> listenSent]

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

FlushPhases == {"idle", "out"}

(* Per-message-type Entry, with Messages a parameter. *)
RefEntryType(Messages) ==
    {EntryNone, MkLocalTarget}
    \cup [kind: {"RemoteTarget"}, targetPeer: Peers, targetRefId: RefIds]
    \cup [kind: {"LocalPromise"},
          queue: Seq(Messages),
          listeners: SUBSET Peers,
          resolution: ResolutionType,
          flushPending: SUBSET Peers,
          notified: BOOLEAN]
    \cup [kind: {"RemotePromise"},
          resolverPeer: Peers,
          resolverRefId: RefIds,
          localResolution: ResolutionType,
          embargo: BOOLEAN,
          flushPhase: FlushPhases,
          pending: Seq(Messages),
          listenSent: BOOLEAN]

(* Domain of allocated entries on peer p. *)
DOMrefs(p) == {r \in RefIds : refs[p][r] # EntryNone}

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
            THEN MkLocalPromise(<< >>, listenersFn[r], ResNone, {}, FALSE)
            ELSE MkRemotePromise(h[r], r, ResNone, FALSE, "idle", << >>, FALSE)
        ]
    ]

============================================================================
