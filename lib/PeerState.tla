----------------------------- MODULE PeerState -----------------------------
(***************************************************************************)
(* Per-peer state, bundled into a single `vats` VARIABLE indexed by peer.  *)
(* This bundling is the structural half of Option C (the locality          *)
(* refactor; see ../notes/locality-contract.md section 7): every per-peer  *)
(* write in spec/Core.tla is of the form                       *)
(*   vats' = [vats EXCEPT ![self].<slot>[...] = ...]                       *)
(* which makes it impossible at the EXCEPT-key level for one peer's       *)
(* action to mutate another peer's state.  A reviewer can grep for         *)
(*   rg "vats' = \[vats EXCEPT !\["                                        *)
(* and verify that every match keys on the bound actor `self`.            *)
(*                                                                         *)
(* A vat owns:                                                              *)
(*   - refs       : the peer's ref table (RefIds -> RefEntry).             *)
(*   - gifts      : [gifter -> [giftId -> GiftEntry]], the table of gifts  *)
(*                  this peer has had deposited TO it; atomically created  *)
(*                  on op:deposit-gift and removed on op:withdraw-gift.    *)
(*                  Keys (gifter, giftId) are gifter-scoped per the OCapN  *)
(*                  gift-table model.                                       *)
(*   - nextGiftId : this peer's monotonic counter as a GIFTER (the count   *)
(*                  of distinct giftIds this peer has issued via           *)
(*                  HandoffInitiate).                                       *)
(*                                                                         *)
(* Top-level model-only variables (not per-peer; not subject to the        *)
(* locality contract):                                                      *)
(*   - sent       : the head peer's monotonic send counter.                 *)
(*   - delivered  : the terminal's append-only delivery log.                *)
(*   - nextRefId  : global monotonic refId allocator for handoff           *)
(*                  withdraw-promises (chain refs 1..ChainLength are        *)
(*                  reserved).                                              *)
(***************************************************************************)

EXTENDS Naturals, Sequences, Network

CONSTANT MaxGifts

ASSUME /\ MaxGifts \in Nat

GiftIds == 1..MaxGifts

NoGift == [kind |-> "none"]

GiftEntry ==
    [kind: {"gift"},
     recipient: Peers,
     targetLocalRefId: Nat]

VARIABLES
    vats,          \* [Peers -> VatState]
    sent,          \* 0..NumMessages (head peer only)
    delivered,     \* Seq of delivery records (see PromiseResolution)
    nextRefId      \* Nat; global handoff refId allocator

----------------------------------------------------------------------------
(* Vat shape.  Each peer's slice of mutable state. *)

VatStateType(Messages) ==
    [refs:       [RefIds -> RefEntryType(Messages)],
     gifts:      [Peers -> [GiftIds -> GiftEntry \cup {NoGift}]],
     nextGiftId: 0..(MaxGifts + 1)]

(* Initial vat for peer p, given the freshly-built chain refs slice. *)
MkInitialVat(initialRefsForP) ==
    [refs       |-> initialRefsForP,
     gifts      |-> [g \in Peers |-> [i \in GiftIds |-> NoGift]],
     nextGiftId |-> 1]

PeerStateInit(initialRefsByPeer) ==
    /\ vats =
         [p \in Peers |-> MkInitialVat(initialRefsByPeer[p])]
    /\ sent = 0
    /\ delivered = << >>
    /\ nextRefId = ChainLength + 1

PeerStateTypeOK(DeliveredEntry, NumMessagesArg, MaxRefIdArg, Messages) ==
    /\ vats \in [Peers -> VatStateType(Messages)]
    /\ sent \in 0..NumMessagesArg
    /\ delivered \in Seq(DeliveredEntry)
    /\ nextRefId \in 0..(MaxRefIdArg + 1)

----------------------------------------------------------------------------
(* Per-actor locality accessors.  Every protocol action in
   spec/Core.tla binds its acting peer as `self` and reads
   its own slice through these operators.  Reviewers can grep for
   bare `vats[X]` outside accessor definitions to spot any direct
   cross-peer reads.  See ../notes/locality-contract.md sections 2-3
   and 7. *)

(* Refs *)
LocalRefs(self)            == vats[self].refs
LocalRef(self, r)          == vats[self].refs[r]
LocalRefAllocated(self, r) == vats[self].refs[r] # EntryNone

(* Gifts *)
LocalGift(self, gifter, gid) == vats[self].gifts[gifter][gid]

(* Gifter-side counter *)
LocalNextGiftId(self) == vats[self].nextGiftId

(* Domain of allocated entries on peer p.  Used by the spec for
   quantifier ranges (e.g. `\E r \in DOMrefs(self) : ...`).  Reads
   only vats[p].refs, so locality-clean when p is the bound actor. *)
DOMrefs(p) == {r \in RefIds : vats[p].refs[r] # EntryNone}

----------------------------------------------------------------------------
(* PairingInvariant: every RemoteX has a matching LocalX on its target.   *)
(* This is a global safety property evaluated by TLC across all peers; it *)
(* is not a peer action and is not subject to the locality contract.      *)

PairingInvariant ==
    /\ \A p \in Peers : \A r \in DOMrefs(p) :
         vats[p].refs[r].kind = "RemoteTarget" =>
            LET q == vats[p].refs[r].targetPeer
                rq == vats[p].refs[r].targetRefId
            IN /\ rq \in DOMrefs(q)
               /\ vats[q].refs[rq].kind = "LocalTarget"
    /\ \A p \in Peers : \A r \in DOMrefs(p) :
         vats[p].refs[r].kind = "RemotePromise" =>
            LET q == vats[p].refs[r].resolverPeer
                rq == vats[p].refs[r].resolverRefId
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
                  /\ vats[q].refs[rq].kind = "LocalPromise"

============================================================================
