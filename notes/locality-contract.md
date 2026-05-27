# Protocol locality contract

This note pins down the locality contract that every protocol in
`spec/PromiseResolution.tla` is required to satisfy, and audits every
action against it. The contract exists because the spec is a model of
a distributed system on top of OCapN sessions — anything implementable
in real OCapN must be representable as actions that only touch their
own peer's state and explicit protocol messages.

If you are reviewing a new action or refactoring an existing one,
this is the checklist.

## 1. Why locality matters

Every routing policy in the spec is a different answer to the same
question: how do you commit to a new path without letting later sends
overtake earlier ones (see [`path-changes.md`](path-changes.md))?
Some "answers" look correct on paper but tacitly rely on signals
that no real implementation can compute, e.g.:

- "Wait until my outbox is empty, then I know my recipient has
  processed everything." A peer cannot in general observe what its
  TCP peer has dequeued; bytes leaving its socket buffer does not
  mean they were applied at the recipient.
- "Look at the resolver's `LocalPromise.queue` to decide whether to
  flush." A subscriber does not have a handle on the resolver's
  state; it can only act on messages it has received.
- "Read peer P's ref table to find out what P knows." There is no
  remote-read primitive in OCapN; every cross-peer fact transfer
  happens via an `op:*` message.

Any protocol that compiles in this spec but tacitly does one of the
above is unimplementable. Catching such violations at spec time —
before they propagate into real implementations of OCapN — is the
whole point of the locality contract.

## 2. The contract (per state variable)

The model's mutable state lives in a small set of top-level variables
declared in `lib/References.tla`, `lib/Network.tla`, and
`lib/PeerState.tla`. All per-peer state is consolidated into a single
`vats[p]` record (see `VatStateType` in `lib/PeerState.tla`) so that
locality of writes is enforced structurally: every write to per-peer
state has the shape `[vats EXCEPT ![self].<field>... = ...]`, which
makes a violation visible by inspection of the bracket-key alone.

| Variable                | Owner of slice                                              | Permitted reads                                                                | Permitted writes                                                  |
|-------------------------|-------------------------------------------------------------|--------------------------------------------------------------------------------|-------------------------------------------------------------------|
| `vats[p].refs[r]`       | peer `p`                                                    | only by `p`                                                                    | only by `p`                                                       |
| `vats[p].gifts[g][i]`   | peer `p` (in its role as target host of the gift `g/i`)     | only by `p`                                                                    | only by `p`                                                       |
| `vats[p].nextGiftId`    | peer `p`                                                    | only by `p`                                                                    | only by `p`                                                       |
| `channels[from][to]`    | sender `from` (append-only) + receiver `to` (consume head)  | receiver `to` may inspect head/tail of its own inbox; **sender may NOT inspect** | sender `from` may append; receiver `to` may consume the head      |
| `host[r]`               | topology (immutable)                                        | any peer (pure topology, set once at `Init`)                                   | none after `Init`                                                 |
| `sent`                  | `HeadPeer`                                                  | any peer (it's a model counter, only `HeadPeer` mutates)                       | `HeadPeer` only                                                   |
| `delivered`             | terminal `LocalTarget` host                                 | any peer (model log)                                                           | the host whose `LocalTarget` is the sink                          |
| `nextRefId`             | global allocator (see §5)                                   | any peer                                                                       | any peer                                                          |
| `lastAction`            | debug-only trace metadata                                   | TLC harness                                                                    | TLC harness                                                       |

The crucial row is `channels[from][to]`: the sender side is
**append-only** and may not be used as a signal. "Is my outbox empty?"
is not a question a peer is allowed to ask — even though it could
syntactically read the channel, doing so would be a locality violation.
A peer's only signal that the recipient has acted is an inbound
protocol message.

## 3. Per-action audit

The acting peer for each action — the peer whose state mutates and
whose perspective the action is taken from — is bound as `self` in
the action body. Every read/write listed is justified by the row
above. Reads go through the accessor operators in `lib/PeerState.tla`
(`LocalRef(self, r)`, `LocalGift(self, g, i)`,
`LocalNextGiftId(self)`); writes are `[vats EXCEPT ![self]...]`.

### Local-only actions (no network)

- **`PeerSend`** — actor: **`HeadPeer`**. Reads
  `LocalRef(HeadPeer, 1)` and `sent`; writes
  `channels[HeadPeer][_]` (its own outbox via `AppendToOutbox`), and
  may write `vats[HeadPeer].refs[_]` via `ApplyRoute` (queue/hold
  tags) and `delivered` (deliver tag, if the terminal happens to be
  on `HeadPeer`).
- **`ProcessPending`** — actor: **bound `self`**. Reads
  `LocalRef(self, r)`; writes `vats[self].refs[_]`,
  `channels[self][_]`, possibly `delivered`.
- **`ProcessHold`** — actor: **bound `self`**. Same pattern as
  `ProcessPending`, draining `vats[self].refs[r].pending` once
  `embargo` is lifted.

### Resolver-side actions

- **`ResolverResolve`** — actor: **bound `self`** with
  `host[r] = self` (`self` is the resolver of `LocalPromise(r)`).
  Reads `LocalRef(self, r)` and `LocalRef(self, res.refId)` (its
  own RemoteTarget to find the eventual target host); writes
  `vats[self].refs[r]` and `channels[self][_]` (op:resolve or
  op:flush to its listeners).
- **`SendTargetFlushProbe`** *(OpFlushProtocol only)* — actor:
  **bound `self`**. Same locality as `ResolverResolve`; emits
  `op:e-flush-probe` on `channels[self][targetPeer]` where
  `targetPeer` is read out of `self`'s own RemoteTarget entry.
  Transitions `vats[self].refs[r].flushPhase` `"idle" -> "out"`
  (or directly to `"acked"` if `self` is itself the target host).
- **`SendOpResolveAfterFlush`** *(OpFlushProtocol only)* — actor:
  **bound `self`**. Preconditioned on
  `LocalRef(self, r).flushPhase = "acked"` (set only by an inbound
  `op:e-flush-probe-ack`); emits `op:resolve` to listeners on
  `channels[self][_]`.

### Network-receive actions

- **`ReceiveNetwork`** — actor: **bound `self`** (the receiver).
  Bound variables: `\E self, from \in Peers`. Reads
  `Inbox(self, from)` (own inbox), the message head, and
  `LocalRef(self, r)` for whatever `r` the message addresses;
  writes `vats[self].refs[_]`, `channels[self][_]` (responses fired
  in the same step: `op:flush-ack`, `op:e-flush-probe-ack`, the
  `op:resolve` reply to a withdraw-gift, etc.), possibly
  `delivered`, and possibly `vats[self].gifts[from][_]` (for
  handoff messages targeting `self`'s gift table). The `from`
  variable appears in the channel index but is **not** used to
  read `from`'s state — only to identify the inbound channel and
  (where the protocol requires it) the sender's identity recorded
  in the message header.

### 3PHO actions

- **`HandoffInitiate`** — actor: **bound `self`** (the gifter).
  Reads `LocalRef(self, srcRef)` and `LocalNextGiftId(self)` and
  `nextRefId`; writes `channels[self][_]` (deposit-gift and
  op:resolve), `vats[self].nextGiftId`, and `nextRefId`. Crucially,
  no read of any peer's state other than `self`'s: the recipient's
  ref table is **not** inspected, even to validate that the chain-
  form's `existingRefId` exists at the recipient. Validation is
  performed by the recipient when it processes
  `op:resolve(desc:handoff-give)` (see `ReceiveNetwork`); invalid
  combinations are silently dropped at the recipient.
- **`ResolverResolve`** (3PHO branch) — actor: **bound `self`** (the
  resolver of `LocalPromise(r)`). When a listener `L` requires a
  third-party introduction (resolution target host `H` is neither
  `self` nor `L`), the resolver allocates `(gid, pw)` from its own
  `nextGiftId` and `nextRefId`, appends `op:deposit-gift` on
  `channels[self][H]`, and appends `op:resolve(r, desc:handoff-give(
  self, H, gid, pw))` on `channels[self][L]`. All writes are
  `channels[self][_]`, `vats[self].nextGiftId`, and `nextRefId`. The
  resolver does not inspect `L`'s or `H`'s state.
- **`ReceiveNetwork[desc:handoff-give chain-form]`** — actor: the
  recipient `self`. Rebinds an existing
  `vats[self].refs[targetRefId]` (its `localResolution` and
  `embargo`), mints `vats[self].refs[pw]`, and appends
  `op:withdraw-gift` on `channels[self][targetHost]`. Under
  `"EJavaFlush"` with non-fresh `targetRefId`, also appends an
  `op:e-flush-probe` on `channels[self][resolverPeer]` (the old
  wire). All reads via `LocalRef(self, _)`; all writes
  `vats[self].refs[_]` and `channels[self][_]`. The same flush
  dispatch the import/export branch performs applies here — see
  `../notes/flush-protocols.md` §7 "Chain-form `desc:handoff-give`
  and the flush dispatch".

### Dynamic listener registration

- **`Listen`** — actor: **bound `self`**. Reads `LocalRef(self, r)`;
  writes `channels[self][resolverPeer]` (op:listen) and
  `vats[self].refs[r].listenSent`.

## 4. What is *not* used as a signal

To make the contract concrete, here are the patterns that are
explicitly forbidden and **do not appear** anywhere in the spec:

- `Len(channels[self][q]) = 0` as a guard for any action whose
  semantics depend on "the recipient has processed". An earlier
  iteration of `OpFlushProtocol` used a `~ChannelHasDeliverOnly`
  predicate of this shape; it was removed in favour of the explicit
  `op:e-flush-probe` / `op:e-flush-probe-ack` roundtrip. The probe
  rides the same FIFO channel as previously-pipelined sends, so by
  the time the ack returns, the recipient has actually processed
  everything that was queued behind the probe.
- `vats[other].refs[_]` for any `other` that is not the actor. The
  `from` variable in `ReceiveNetwork` is never used to read `from`'s
  ref table; it appears only as a channel index and as the sender's
  identity carried in the message header.
- Mutating `vats[other].gifts[_][_]` or `vats[other].nextGiftId`
  for any `other` that is not the actor. Because every write is of
  the form `[vats EXCEPT ![self]... = ...]`, this is enforced
  structurally — a violation requires writing `![other]` for some
  `other # self`, which is easy to spot.

## 5. Known modeling shortcuts (not implementation bugs)

The model takes a few documented shortcuts that lift the locality
constraint slightly. None of these affect the protocol's correctness;
they are bookkeeping simplifications for tractability.

- **Globally-shared refIds (`v0` convention).** A single integer
  `r` identifies the same logical capability on every peer that
  holds an entry for it. Real OCapN uses per-peer import/export
  tables, and messages reference refIds in the destination peer's
  namespace. The translation is mechanical; see
  [`flush-protocols.md`](flush-protocols.md) §1.
- **`HandoffInitiate.existingRefId` selected from gifter's promises.**
  When building a chain-form (forwarder) handoff, the gifter
  quantifies `existingRefId` over its own promise-typed entries
  (`LocalRef(self, r).kind \in {"LocalPromise", "RemotePromise"}`).
  In reality the gifter only "knows" the recipient holds a given
  refId because of a previous introduction; the model collapses that
  introduction into the same step but does so without ever reading
  the recipient's ref table. Any chain-form whose `existingRefId`
  does not actually bind at the recipient is detected and silently
  dropped by the recipient when it processes the
  `op:resolve(desc:handoff-give)`.
- **`nextRefId` global counter.** Handoff withdraw-promises allocate
  `pw` from a single global counter rather than from the gifter's
  own namespace. This is a uniqueness convenience that lets us avoid
  reasoning about per-peer refId collisions in the chain MCs. A
  per-gifter counter (analogous to `vats[p].nextGiftId`) would be
  locality-clean and is a tractable follow-up.
- **`host[r]`** is initialised once at `Init` and read by all peers
  thereafter. It encodes pure topology — "which peer hosts the
  `LocalX` entry for chain refId `r`?" — and would not exist in a
  real implementation (each peer just has its own `LocalX` entries).
  It's a model-only shorthand for stating chain shape in tests.
- **`sent` and `delivered`** are model-only counters used by the
  `EndToEndRefFIFO` and `NoMessageLost` invariants. Only `HeadPeer`
  writes `sent`; only terminal `LocalTarget` hosts append to
  `delivered`.

## 6. Reviewer checklist

When adding or modifying an action, walk this list:

1. **Identify the actor.** It must be a single bound peer
   (`\E self \in Peers : ...`) or fixed (`HeadPeer`). If you need
   two bound peers (as in `ReceiveNetwork`'s `\E self, from`), one
   must be designated the actor (bound as `self`) and the other
   must only appear in channel indices or message headers.
2. **All reads of per-peer state must use accessors.** Every read
   of `vats[_]` should go through `LocalRef(self, r)`,
   `LocalRefs(self)`, `LocalRefAllocated(self, r)`,
   `LocalGift(self, g, i)`, `LocalNextGiftId(self)`, or
   `DOMrefs(self)`. Each accessor takes `self` as its first
   argument and expands to `vats[self].<field>`; a direct read of
   `vats[other]` for `other # self` is a locality violation.
3. **All writes of per-peer state must key on `![self]`.** Every
   write must have the shape
   `vats' = [vats EXCEPT ![self].refs[r]... = ..., ![self].gifts[g][i] = ..., ![self].nextGiftId = ...]`.
   A bracket-key other than `![self]` indicates the action is
   mutating another peer's state — forbidden.
4. **List every `channels[X][Y]` access in the body.**
   - For reads (head/non-empty/consume): use `Inbox(self, from)`
     / `InboxHead(self, from)` / `InboxNonEmpty(self, from)` /
     `InboxTail(ch, self, from)`. `Y` (the second index) must
     be `self`.
   - For appends: use `AppendToOutbox(ch, self, to, msg)`. `X`
     (the first index) must be `self`.
   - For "length / contents" predicates used as guards on whether
     to act: **forbidden**. (Length-as-progress-marker for the
     actor's own outbox might look innocent — it isn't. The
     recipient may have processed nothing or everything; you have
     no way to know.) No accessor exists for outbox introspection
     by design.
5. **For each non-actor-keyed access, justify it** in a code
   comment and add it to §5 above if it is a new modeling
   shortcut, or fix it if it is an actual violation.

## 7. Structural enforcement: the `vats` record + per-actor accessors

Two design choices together enforce write-locality structurally and
make read-locality violations easy to spot at review time:

1. **All per-peer state lives in a single `vats[p]` record.** This
   means every write must be of the form
   `[vats EXCEPT ![self].<field>... = ...]`. A reviewer (or `rg`)
   can scan for `vats EXCEPT !\[` and verify the bracket-key on
   every site is `[self]`. The record shape (`refs`, `gifts`,
   `nextGiftId`) is defined as `VatStateType` in
   `lib/PeerState.tla`.
2. **Per-actor accessor operators** for reads. The spec never reads
   `vats[_]` directly; instead each read goes through an accessor
   that takes `self` as its first parameter:

```tla
\* lib/PeerState.tla
LocalRefs(self)              == vats[self].refs
LocalRef(self, r)            == vats[self].refs[r]
LocalRefAllocated(self, r)   == vats[self].refs[r] # EntryNone
LocalGift(self, gifter, gid) == vats[self].gifts[gifter][gid]
LocalNextGiftId(self)        == vats[self].nextGiftId
DOMrefs(p)                   == {r \in RefIds : vats[p].refs[r] # EntryNone}

\* lib/Network.tla
Inbox(self, from)                  == channels[from][self]
InboxHead(self, from)              == Head(channels[from][self])
InboxNonEmpty(self, from)          == Len(channels[from][self]) > 0
InboxTail(ch, self, from)          == [ch EXCEPT ![from][self] = Tail(@)]
AppendToOutbox(ch, self, to, msg)  == [ch EXCEPT ![self][to] = Append(@, msg)]
```

Two further design choices are worth calling out:

- **No `OutboxLen` / `OutboxEmpty` accessor.** This is deliberate.
  A peer is allowed to *append* to its own outbox but **not to
  inspect it as a guard** (see §1 and §4: "outbox empty" is not an
  implementable signal). The accessor set encodes that asymmetry —
  every outbox operation is a write.
- **`DOMrefs(p)` takes `p` not `self`** because it is used as a
  bound for `\E r` quantifiers (`\E r \in DOMrefs(self) : ...`) and
  also from invariants (`\A p \in Peers : \A r \in DOMrefs(p) :
  ...`). Inside an action body it must be called with `self`; in
  invariants any peer is fine (invariants are not peer actions).

### How to spot a violation

```bash
# Direct reads of another peer's state (should never appear in an action
# body; only DOMrefs(self) and the accessors should appear):
rg 'vats\[[^s]' spec/PromiseResolution.tla   # any vats[X] where X != self

# Writes that don't key on self (the bracket-key must be ![self]):
rg 'vats EXCEPT !\[' spec/PromiseResolution.tla

# Direct outbox/inbox accesses (should be via accessors):
rg 'channels\[' spec/PromiseResolution.tla   # all should be inside accessors

# Bare Network* helpers in spec (should be Inbox*/AppendToOutbox):
rg 'NetworkAppend|NetworkHead|NetworkTail|NetworkNonEmpty' spec/PromiseResolution.tla
```

After the Option C refactor:
- All writes to per-peer state in action bodies are of the form
  `vats' = [vats EXCEPT ![self]... = ...]`. There are no
  exceptions in the spec.
- The only `vats[X]` reads where `X` is not `self` inside an action
  body do not exist; all reads go through the accessors above.
- Invariants (`NoInFlightDeliverOnly`, `EndToEndRefFIFO`,
  `GiftOneShot`, `GiftHasOneRecipient`, etc.) are meta-level safety
  properties evaluated by TLC over every state, not peer actions,
  and are free to quantify over all peers; they appear as
  `\A p \in Peers : \A r \in DOMrefs(p) : ...` and read
  `vats[p].refs[r]` / `vats[p].gifts[...]` directly. They are not
  subject to the locality contract.

There are no `channels[X]` direct accesses in any action body; all
network traffic flows through `InboxHead` / `InboxNonEmpty` /
`InboxTail` (reads) and `AppendToOutbox` (writes). The bare
`NetworkAppend` / `NetworkHead` helpers in `lib/Network.tla` remain
available for internal use but are no longer called from the spec.

### Notation reminder for ReceiveNetwork

`ReceiveNetwork` binds two peers: the receiver (= the actor, bound
as `self`) and the sender (`from`, used only as a channel index and
as the destination of acks or replies). The action's body never
reads `vats[from]` or `channels[from][_]`-with-`_`-different-from-`self`;
`from` only appears as the first index of `Inbox(self, from)` (which
expands to `channels[from][self]`) and as the destination of
`AppendToOutbox(ch, self, from, ack)` when emitting a reply.
