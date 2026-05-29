# TLA+: OCapN-flavored reference taxonomy and `EndToEndRefFIFO`

A modular TLA+ spec for a **linear OCapN ref chain** with a refined
reference taxonomy (`LocalTarget`, `RemoteTarget`, `LocalPromise`,
`RemotePromise`), kind-discriminated routing dispatch, intra-vat
queue cascade on local resolution, and two end-to-end flush protocols
(`EJavaFlush` and `OpFlushProtocol`).

The model focuses on the **message-order invariant**
**`EndToEndRefFIFO`** under a small fixed surface (one sender, one
reference) and shows where it holds and where it fails for each
routing policy.

## Reference taxonomy

Per-peer state `vats[p].refs[r]` for every refId `r`:

| Kind            | Fields                                                                            |
|-----------------|-----------------------------------------------------------------------------------|
| `LocalTarget`   | (sink owned by `p`)                                                               |
| `RemoteTarget`  | `targetPeer`, `targetRefId`                                                       |
| `LocalPromise`  | `queue`, `listeners`, `resolution`, `flushPending`, `notified`, `flushPhase`      |
| `RemotePromise` | `resolverPeer`, `resolverRefId`, `localResolution`, `embargo`, `pending`, `listenSent`, `fresh` |

The pinned chain shape is

```
HeadPeer -> p_1@host[1] -> p_2@host[2] -> ... -> p_{N-1}@host[N-1] -> T@host[N]
```

where `host[1..ChainLength-1]` are promise resolvers and
`host[ChainLength]` hosts the terminal `LocalTarget`. RefIds are
**globally shared integers**: refId `i` names the same logical
capability on every peer that holds an entry for it. Promises are
1..ChainLength-1; the terminal is at `ChainLength`.

## Path changes (terminology)

A **path change** is any event that changes the network route a
future send on a ref will take. Path changes are the source of every
FIFO-violation hazard in this spec: an in-flight send on the *old*
path can race a new send on the *new* path and arrive at the terminal
out of order. The routing policies below are different answers to
the same question — *how do you commit to the new path without
letting later sends overtake earlier ones?*

The model distinguishes two kinds of path change:

- **Promise resolution** (`LocalPromise` -> `Target`). The promise
  resolves to a concrete capability (a `LocalTarget` or a
  `RemoteTarget`). Carried on the wire by
  `op:resolve(refId, desc:import-target | desc:export-target | ...)`.
  Import/export are from the **receiver's** perspective: a target
  hosted on the sender is `desc:import-target`; one hosted on the
  receiver is `desc:export-target`. Third-party introductions use
  `desc:handoff-give` only. **This is the only kind of path change
  the spec propagates over the wire** (for target resolutions).
- **Promise shortening** (`LocalPromise` -> another `Promise`):
  - *Intra-vat:* the new promise is on the same vat. The resolver
    drains the resolved promise's `queue` directly into the new
    promise (or recursively into whatever it points to). No wire
    traffic; tested by `Unit_LocalShorten_Cascade` and exercised as
    a side effect of every non-terminal `ResolverResolve` in the
    chain MCs.
  - *Inter-vat (distributed):* the new promise is on a different vat.
    **Two-party form modelled (Phase A) + three-party form modelled
    (Phase B) + 2-party flush extensions (Phase C).**
    `ResolverResolve` emits
    `op:resolve(refId, desc:import-promise|desc:export-promise)` when
    the resolution is promise-shaped and every listener can receive
    it two-party (across `NaivePromiseResolution`, `ShorteningUnsafe`,
    and `EJavaFlush`; `OpFlushProtocol` runs its full flush handshake
    around the promise-shaped resolution). When listeners are
    three-party, the resolver fires `desc:handoff-give` carrying a
    Promise cap (3PHO), gated to `NaivePromiseResolution` /
    `ShorteningUnsafe`, `EJavaFlush` (witness-gated), and
    `OpFlushProtocol` (always `op:flush` listeners first; no `fresh`
    gate). Phase D adds `RepropagatePromiseShorten` and Tribble MCs.
    See
    [`notes/path-changes.md`](notes/path-changes.md) §1.2.b, §3.1,
    §3.8, §3.9, and §3.10.

The word "shortening" in the policy name `ShorteningUnsafe` follows
the older OCapN-colloquial usage where "shortening" denotes the
umbrella act of changing a ref's route (i.e. a *path change* in our
terminology). The name is kept for continuity with the OCapN issue
threads; it is not specifically about promise-to-promise shortening.

## Routing policies

Set via the `RoutingPolicy` constant in
[`spec/PromiseResolution.tla`](spec/PromiseResolution.tla):

- **`"NoPromiseResolution"`** — listeners are empty, no `op:resolve`
  ever fires; ref-1 sends always ride the wire through the chain.
  No path change ⇒ no FIFO hazard. Holds.
- **`"NaivePromiseResolution"`** — listener installs `localResolution`
  immediately on `op:resolve` receipt with zero synchronisation
  against the old path. Path change is unguarded; in-flight pipelined
  ref-1 sends and post-resolve direct sends race at the terminal.
  Violates `EndToEndRefFIFO` on a 2-chain.
- **`"ShorteningUnsafe"`** — same shape as Naive, demonstrated on a
  longer chain (`MC_ShorteningUnsafe_3Chain`: 4 peers, 3 hops). Same
  unguarded path change. Violates `EndToEndRefFIFO`.
- **`"EJavaFlush"`** — faithful model of e-on-java's
  `DelayedRedirector`. Subscriber-initiated end-to-end flush: on
  `op:resolve` receipt at listener `L`, the fast path
  (`fresh = TRUE` or `sameConnection`) installs immediately;
  otherwise `L` emits an `op:e-flush-probe` down the chain along the
  same FIFO channels as previously-pipelined sends. The terminal
  acks back to `L`; `L` lifts the embargo and drains its locally-
  buffered `pending`. Holds for linear chains; the Tribble four-way
  scenario is a known inherited limitation (see
  [`notes/path-changes.md`](notes/path-changes.md) §3.1).
- **`"OpFlushProtocol"`** — resolver-initiated alternative
  (Ridley proposal, ocapn#11). `ResolverResolve` emits `op:flush(r)`
  to listeners instead of `op:resolve`; each listener atomically
  sets `embargo` and enqueues `op:flush-ack` on the same channel
  (FIFO carries the ordering). Once all acks return and the
  resolver's own queue is drained, the resolver emits an
  `op:e-flush-probe` to the terminal and waits for the matching
  `op:e-flush-probe-ack`; only then does it emit `op:resolve` to
  listeners. Locality-clean: every state transition is driven by
  an explicit protocol message; no peer reads another peer's
  channel state. Holds for linear chains.

## Message ordering invariant

> For a fixed sender peer and a fixed reference `R`, every
> `op:deliver-only` from that peer on `R` is applied at the terminal
> in strictly increasing send order.

The current model has a single originator (`HeadPeer`) on a single
reference (`ref = 1`), so the invariant collapses to "the seq numbers
in `delivered` are strictly increasing".

Two additional invariants:

- **`NoMessageLost`** — once `sent = NumMessages` and there are no
  ref-1 `op:deliver-only` messages anywhere (no `channels`, no
  `LocalPromise.queue`, no `RemotePromise.pending`), then
  `Len(delivered) = NumMessages`.
- **`PairingInvariant`** — every `RemoteTarget` has a matching
  `LocalTarget` on its target peer; every `RemotePromise` has a
  matching `LocalPromise` on its resolver peer.

## Modelled features

What the spec currently covers:

- Kind-discriminated reference taxonomy (`LocalTarget`,
  `RemoteTarget`, `LocalPromise`, `RemotePromise`) with single-
  dispatch `Route` and terminal-only `op:resolve` propagation.
- Intra-vat promise shortening via `LocalPromise.queue` cascade
  (no wire traffic; see `Unit_LocalShorten_Cascade`).
- Explicit `op:listen` subscription with subscribe-to-already-
  resolved reply (`MC_SubscribeAfterResolve`,
  `Unit_Listen_Subscribe_{Unresolved,AfterResolve}`).
- Opaque three-party handoff (`op:deposit-gift`,
  `desc:handoff-give`, `op:withdraw-gift`) with pre-mint of
  `LocalPromise(pw)` on deposit, withdraw-blocks-on-deposit
  serialization, gift-table one-shot semantics; `MC_TerminalHandoff_*`,
  `MC_ConcurrentHandoffs`, `Unit_Handoff_*`; `GiftOneShot` and
  `GiftHasOneRecipient` invariants.
- Five routing policies covering the spectrum from "no path change
  at all" through "unguarded path change" to "fully end-to-end-acked
  path change" (see *Routing policies* above).

What's deferred — see [`notes/path-changes.md`](notes/path-changes.md):

- Inter-vat distributed promise shortening Phases A–D are modelled
  (flush propagation is per-node local conditions only; no
  cross-node `op:flush` relay). Tribble MCs:
  `MC_EJavaFlush_TribbleFourWay` violates FIFO (faithful
  `DelayedRedirector`); `MC_OpFlushProtocol_TribbleFourWay` passes
  (see `notes/path-changes.md` §3.11).  Note: the OpFlushProtocol
  Tribble pass is **safety-only**; its `.cfg` omits `EventualDelivery`
  because per-node flush + re-propagation can stutter under weak
  fairness while FIFO still holds.  Read it as "no FIFO inversion
  under any reachable schedule" rather than "every send eventually
  reaches the terminal".
- Per-peer refId namespaces (mechanical translation, currently global).
- Ref-scoped flush drainage (currently whole-channel-empty).
- Multi-sender FIFO MCs.
- Flush protocols under handoff.

## Layout

```
ocapn-tla-plus/
├── lib/
│   ├── References.tla    # ref taxonomy + constructors, host, MkChainRefs
│   ├── Network.tla       # per-pair FIFO channels + inbox/outbox accessors
│   └── PeerState.tla     # vats[p].{refs,gifts,nextGiftId}, sent, delivered,
│                         # nextRefId, and per-actor accessor operators
├── spec/
│   └── PromiseResolution.tla
├── models/                # scenario MCs (policy-level race scenarios)
│   ├── MC_NoPromiseResolution.tla / .cfg
│   ├── MC_NoPromiseResolution_3Chain.tla / .cfg
│   ├── MC_NaivePromiseResolution.tla / .cfg
│   ├── MC_NaivePromiseResolution_PromiseShorten.tla / .cfg  (Phase A: 2-party violation)
│   ├── MC_NaivePromiseResolution_3Chain.tla / .cfg          (Phase B: 3-party violation)
│   ├── MC_ShorteningUnsafe_3Chain.tla / .cfg
│   ├── MC_EJavaFlush_3Chain.tla / .cfg
│   ├── MC_EJavaFlush_3Chain_PromiseShorten.tla / .cfg       (Phase C: 2-party EJava pass)
│   ├── MC_EJavaFlush_3Chain_PromiseShorten_3Party.tla / .cfg (Phase C: 3-party EJava pass)
│   ├── MC_EJavaFlush_4Chain.tla / .cfg
│   ├── MC_EJavaFlush_TribbleFourWay.tla / .cfg              (Phase D: Tribble, expect violation)
│   ├── MC_OpFlushProtocol_3Chain_PromiseShorten.tla / .cfg  (Phase C: 2-party OpFlush pass)
│   ├── MC_OpFlushProtocol_3Chain_PromiseShorten_3Party.tla / .cfg (Phase C: 3-party OpFlush pass)
│   ├── MC_OpFlushProtocol_TribbleFourWay.tla / .cfg         (Phase D: Tribble, expect pass)
│   ├── MC_OpFlushProtocol_4Chain.tla / .cfg
│   ├── MC_SubscribeAfterResolve.tla / .cfg       (op:listen subscription)
│   ├── MC_TerminalHandoff_Baseline.tla / .cfg    (3PHO baseline)
│   ├── MC_TerminalHandoff_WithForwarder.tla / .cfg (3PHO + forwarder race)
│   ├── MC_ConcurrentHandoffs.tla / .cfg          (gift-table sanity)
│   └── *_Debug.cfg            (sibling debug cfg per base MC; flips
│                               DebugTrace = TRUE + SPECIFICATION SpecDebug
│                               so `run-tests.sh --debug <MC>` renders the
│                               trace via the same .tla module)
├── tests/                 # unit-test MCs (focused, single-mechanism)
│   ├── Unit_LocalTarget_Direct.tla / .cfg
│   ├── Unit_LocalShorten_Cascade.tla / .cfg      (intra-vat shortening)
│   ├── Unit_RemoteTarget_Forward.tla / .cfg
│   ├── Unit_Pipelining_On_Promise.tla / .cfg
│   ├── Unit_Listen_Subscribe_Unresolved.tla / .cfg     (covers both
│                                  before- and after-resolve interleavings)
│   ├── Unit_Handoff_DepositWithdraw.tla / .cfg
│   ├── Unit_Handoff_Pipeline.tla / .cfg
│   ├── Unit_Handoff_Pipeline_BeforeDeposit.tla / .cfg
│   ├── Unit_Handoff_RejectWrongRecipient.tla / .cfg
│   ├── Unit_EJavaFlush_RefScopedEmbargo.tla / .cfg
│   ├── Unit_EJavaFlush_EmbargoFires.tla / .cfg       (positive witness: violation expected)
│   ├── Unit_EJavaFlush_HandoffChainProbe.tla / .cfg  (joint embargo+probe witness: violation expected)
│   ├── Unit_WireDesc_DescriptorChoice.tla / .cfg     (import/export/handoff wire contract)
│   ├── Unit_PromiseShorten_TwoParty.tla / .cfg       (Phase A two-party promise emission: violation expected)
│   └── Unit_PromiseShorten_ThreeParty.tla / .cfg     (Phase B three-party promise-cap handoff: violation expected)
├── notes/
│   ├── path-changes.md                           (terminology + tracked future work)
│   ├── flush-protocols.md                        (wire-level protocol reference)
│   ├── locality-contract.md                      (per-variable locality contract + reviewer checklist)
│   └── counterexample-naive-promise-resolution.txt
└── scripts/
    ├── run-tests.sh           # matrix + unit tests; --debug renders mermaid
    ├── trace-to-mermaid.sh
    └── trace_to_mermaid.py
```

TLC classpath: `lib:spec:models:tests`.

## How to run

Install `tla2tools.jar` (TLC 2.x):

```bash
mkdir -p ~/tla
curl -sSL -o ~/tla/tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
```

From the repo root:

```bash
./scripts/run-tests.sh
```

This runs the full **scenario MC matrix** and the **unit tests** and
exits non-zero on any unexpected outcome (`pass` vs `violation`).

### Debug trace + mermaid + Lamport space-time diagram

```bash
./scripts/run-tests.sh --debug MC_NaivePromiseResolution
./scripts/run-tests.sh --debug MC_EJavaFlush_3Chain
./scripts/run-tests.sh --debug MC_EJavaFlush_4Chain
./scripts/run-tests.sh --debug MC_OpFlushProtocol_4Chain
```

Outputs in `.tlc-logs/`:

- `.tlc-logs/<MC>.debug.log` — full TLC counterexample dump
- `.tlc-logs/<MC>.trace.md` — mermaid `sequenceDiagram` with each
  arrow tagged `[s_send → s_recv]` (transit gap) and explicit per-step
  dequeue notes
- `.tlc-logs/<MC>.trace.svg` — Lamport / space-time diagram with
  vertical peer lines and diagonal send→receive arrows whose slope
  encodes transit time (steeper = longer in-flight); colors per op
  kind (deliver / resolve / flush / listen / gift); dashed = still
  in-flight at trace end

### Single model

```bash
java -cp ~/tla/tla2tools.jar:lib:spec:models:tests tlc2.TLC \
     -workers auto \
     -config models/MC_NoPromiseResolution_3Chain.cfg \
     models/MC_NoPromiseResolution_3Chain.tla
```

## What this shows

- **Naive / ShorteningUnsafe**: any policy that commits to the new
  path without an end-to-end flush observably reorders messages.
- **EJavaFlush**: faithful end-to-end probe + ack along the old path
  preserves FIFO for linear chains; the Tribble four-way case still
  defeats it.
- **OpFlushProtocol**: resolver-initiated `op:flush` to listeners
  (FIFO carries the per-listener pre-flush draining) plus a
  resolver-to-target probe + ack (the same primitive EJavaFlush
  uses) preserves FIFO under the same locality contract — no peer
  reads another peer's channel state.

See [`notes/flush-protocols.md`](notes/flush-protocols.md) for the
wire-level spec of every mechanism above,
[`notes/path-changes.md`](notes/path-changes.md) for the path-change
taxonomy and tracked future work, and
[`notes/locality-contract.md`](notes/locality-contract.md) for the
precise per-variable locality contract every protocol action is
required to satisfy (and the reviewer checklist for new actions).

## Fingerprint collisions

TLC dedupes by 64-bit fingerprint; distinct states can collide.
Re-run with `-fp K` (`0 ≤ K ≤ 63`) for extra confidence on large
models.
