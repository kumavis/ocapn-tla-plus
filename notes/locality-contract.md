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
`lib/PeerState.tla`. Each variable has a notional **owner**: the
peer (or set of peers) that is the only legitimate read/write source
for that variable's slice.

| Variable           | Owner of slice `X[p]...`           | Permitted reads                                                                | Permitted writes                                                  |
|--------------------|------------------------------------|--------------------------------------------------------------------------------|-------------------------------------------------------------------|
| `refs[p][r]`       | peer `p`                           | only by `p`                                                                    | only by `p`                                                       |
| `channels[from][to]` | sender `from` (append-only) + receiver `to` (consume head) | receiver `to` may inspect head/tail of its own inbox; **sender may NOT inspect** | sender `from` may append; receiver `to` may consume the head      |
| `host[r]`          | topology (immutable)               | any peer (pure topology, set once at `Init`)                                   | none after `Init`                                                 |
| `sent`             | `HeadPeer`                         | any peer (it's a model counter, only `HeadPeer` mutates)                       | `HeadPeer` only                                                   |
| `delivered`        | terminal `LocalTarget` host        | any peer (model log)                                                           | the host whose `LocalTarget` is the sink                          |
| `gifts[t][g][i]`   | target host `t`                    | only by `t`                                                                    | only by `t` (in response to messages from gifter `g` / recipient) |
| `nextGiftId[p]`    | peer `p`                           | only by `p`                                                                    | only by `p`                                                       |
| `nextRefId`        | global allocator (see §5)          | any peer                                                                       | any peer                                                          |
| `lastAction`       | debug-only trace metadata          | TLC harness                                                                    | TLC harness                                                       |

The crucial row is `channels[from][to]`: the sender side is
**append-only** and may not be used as a signal. "Is my outbox empty?"
is not a question a peer is allowed to ask — even though it could
syntactically read the channel, doing so would be a locality violation.
A peer's only signal that the recipient has acted is an inbound
protocol message.

## 3. Per-action audit

The acting peer for each action — the peer whose state mutates and
whose perspective the action is taken from — is in bold. Every
read/write listed is justified by the row above.

### Local-only actions (no network)

- **`PeerSend`** — actor: **`HeadPeer`**. Reads `refs[HeadPeer][1]`
  and `sent`; writes `channels[HeadPeer][_]` (its own outbox), and
  may write `refs[HeadPeer][_]` via `ApplyRoute` (queue/hold tags) and
  `delivered` (deliver tag, if the terminal happens to be on
  `HeadPeer`).
- **`ProcessPending`** — actor: **bound `p`**. Reads `refs[p][r]`;
  writes `refs[p][_]`, `channels[p][_]`, possibly `delivered`.
- **`ProcessHold`** — actor: **bound `p`**. Same pattern as
  `ProcessPending`, draining `refs[p][r].pending` once `embargo` is
  lifted.

### Resolver-side actions

- **`ResolverResolve`** — actor: **bound `p`** with
  `host[r] = p` (`p` is the resolver of `LocalPromise(r)`). Reads
  `refs[p][r]` and `refs[p][res.refId]` (its own RemoteTarget to find
  the eventual target host); writes `refs[p][r]` and
  `channels[p][_]` (op:resolve or op:flush to its listeners).
- **`SendTargetFlushProbe`** *(OpFlushProtocol only)* — actor:
  **bound `p`**. Same locality as `ResolverResolve`; emits
  `op:e-flush-probe` on `channels[p][targetPeer]` where `targetPeer`
  is read out of `p`'s own RemoteTarget entry. Transitions
  `refs[p][r].flushPhase` `"idle" -> "out"` (or directly to
  `"acked"` if `p` is itself the target host).
- **`SendOpResolveAfterFlush`** *(OpFlushProtocol only)* — actor:
  **bound `p`**. Preconditioned on `refs[p][r].flushPhase = "acked"`
  (set only by an inbound `op:e-flush-probe-ack`); emits `op:resolve`
  to listeners on `channels[p][_]`.

### Network-receive actions

- **`ReceiveNetwork`** — actor: **bound `to`** (the receiver).
  Bound variables: `\E from, to \in Peers`. Reads
  `channels[from][to]` (own inbox), the message head, and
  `refs[to][r]` for whatever `r` the message addresses; writes
  `refs[to][_]`, `channels[to][_]` (responses fired in the same step:
  `op:flush-ack`, `op:e-flush-probe-ack`, the `op:resolve` reply to
  a withdraw-gift, etc.), possibly `delivered`, and possibly
  `gifts[to][from][_]` (for handoff messages targeting `to`'s gift
  table). The `from` variable appears in the channel index but is
  **not** used to read `from`'s state — only to identify the inbound
  channel and (where the protocol requires it) the sender's identity
  recorded in the message header.

### 3PHO actions

- **`HandoffInitiate`** — actor: **bound `gifter`**. Reads
  `refs[gifter][srcRef]` and `nextGiftId[gifter]`; writes
  `channels[gifter][_]` (deposit-gift and op:resolve), `nextGiftId`,
  and `nextRefId`. See §5 for the `existingRefId` modeling shortcut.

### Dynamic listener registration

- **`Listen`** — actor: **bound `p`**. Reads `refs[p][r]`; writes
  `channels[p][resolverPeer]` (op:listen) and `refs[p][r].listenSent`.

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
- `refs[other][_]` for any `other` that is not the actor. The `from`
  variable in `ReceiveNetwork` is never used to read `from`'s ref
  table; it appears only as a channel index and as the sender's
  identity carried in the message header.
- Mutating `gifts[other][_][_]` for any `other` that is not the
  actor. Only the target host writes its own gift table, and only
  in response to a message it has received.

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
- **`HandoffInitiate.existingRefId \in DOMrefs(recipient)`.** The
  gifter selects an existing refId on the recipient's ref table when
  building a chain-form (forwarder) handoff. In reality the gifter
  must have been told (or already know) that the recipient holds
  that refId via a previous introduction. The model bypasses the
  introduction step by quantifying directly over the recipient's
  domain. This does not violate the protocol contract — the field
  just represents knowledge the gifter would have acquired through
  some previous communication — but the bound is taken from
  `recipient`'s state, which a strict locality check would flag.
- **`nextRefId` global counter.** Handoff withdraw-promises allocate
  `pw` from a single global counter rather than from the gifter's
  own namespace. This is a uniqueness convenience that lets us avoid
  reasoning about per-peer refId collisions in the chain MCs. A
  per-gifter counter would be locality-clean and is a tractable
  follow-up.
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
   two bound peers (as in `ReceiveNetwork`'s `\E from, to`), one
   must be designated the actor and the other must only appear in
   channel indices or message headers.
2. **List every `refs[X][...]` access in the body.** Each `X` must
   be the actor or a chain of dereferences starting from the
   actor's own state (e.g. `refs[self][r].resolution.refId`).
3. **List every `channels[X][Y]` access in the body.**
   - For reads (head/non-empty/consume): `Y` must be the actor (own
     inbox); `X` is the sender of the inbound message.
   - For appends: `X` must be the actor (own outbox); `Y` is the
     destination.
   - For "length / contents" predicates used as guards on whether
     to act: **forbidden**. (Length-as-progress-marker for the
     actor's own outbox might look innocent — it isn't. The
     recipient may have processed nothing or everything; you have
     no way to know.)
4. **List every `gifts[X][...]` access.** `X` must be the actor.
5. **For each non-actor-keyed access, justify it** in a code
   comment and add it to §5 above if it is a new modeling
   shortcut, or fix it if it is an actual violation.

## 7. Per-actor accessor operators

To make violations visible at review time, the spec uses per-actor
accessor operators. Every action binds its acting peer as `self` and
threads `self` through every state access:

```tla
\* lib/References.tla
LocalRefs(self)            == refs[self]
LocalRef(self, r)          == refs[self][r]
LocalRefAllocated(self, r) == refs[self][r] # EntryNone
SetLocalRef(refs0, self, r, entry) ==
    [refs0 EXCEPT ![self][r] = entry]

\* lib/Network.tla
Inbox(self, from)                  == channels[from][self]
InboxHead(self, from)              == Head(channels[from][self])
InboxNonEmpty(self, from)          == Len(channels[from][self]) > 0
InboxTail(ch, self, from)          == [ch EXCEPT ![from][self] = Tail(@)]
AppendToOutbox(ch, self, to, msg)  == [ch EXCEPT ![self][to] = Append(@, msg)]
```

Two design choices are worth calling out:

- **No `OutboxLen` / `OutboxEmpty` accessor.** This is deliberate. A
  peer is allowed to *append* to its own outbox but **not to inspect
  it as a guard** (see §1 and §4: "outbox empty" is not an
  implementable signal). The accessor set encodes that asymmetry —
  every outbox operation is a write.
- **Plain `EXCEPT` for per-field ref updates.** TLA+ EXCEPT clauses
  for nested field updates (`.queue = Append(@, msg)`, etc.) cannot
  be hidden behind a single helper, so writes still appear as
  `[refs EXCEPT ![self][r].queue = ...]`. The accessor convention
  for these writes is "the bracket-key must be `[self]`"; reviewers
  can `rg 'refs EXCEPT !\[' spec/PromiseResolution.tla` and verify
  every site keys on `self`.

### How to spot a violation

```bash
# Direct reads that bypass LocalRef:
rg 'refs\[[^s]' spec/PromiseResolution.tla   # any refs[X] where X != self

# Direct outbox/inbox accesses:
rg 'channels\[' spec/PromiseResolution.tla   # all should be inside accessors

# Bare NetworkAppend/NetworkHead in spec (should be AppendToOutbox/InboxHead):
rg 'NetworkAppend|NetworkHead|NetworkTail|NetworkNonEmpty' spec/PromiseResolution.tla
```

After the refactor, the only `refs[X]` reads where `X` is not `self`
inside an action body are the three intentional modeling-shortcut
sites in `HandoffInitiate` (see §5), each preceded by an inline
"modeling shortcut" comment that references this document.
Invariants (`NoInFlightDeliverOnly`, `EndToEndRefFIFO`, etc.) are
meta-level safety properties evaluated by TLC over every state, not
peer actions, and are free to quantify over all peers; they appear
as `\A p \in Peers : \A r \in DOMrefs(p) : ...` reads of `refs[p][r]`
and `channels[p][q]` and are not subject to the locality contract.

There are no `channels[X]` direct accesses in any action body; all
network traffic flows through `InboxHead` / `InboxNonEmpty` /
`InboxTail` (reads) and `AppendToOutbox` (writes). The bare
`NetworkAppend` / `NetworkHead` helpers in `lib/Network.tla` remain
available for internal use but are no longer called from the spec.

### Notation reminder for ReceiveNetwork

`ReceiveNetwork` binds two peers: the receiver (= the actor, bound
as `self`) and the sender (`from`, used only as a channel index and
as the destination of acks or replies). The action's body never
reads `refs[from]` or `channels[from][_]`-with-`_`-different-from-`self`;
`from` only appears as the first index of `Inbox(self, from)` (which
expands to `channels[from][self]`) and as the destination of
`AppendToOutbox(ch, self, from, ack)` when emitting a reply.
