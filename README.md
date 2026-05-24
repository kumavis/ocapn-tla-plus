# TLA+: OCapN-flavored reference taxonomy and `EndToEndRefFIFO`

A modular TLA+ spec for a **linear OCapN ref chain** with a refined
reference taxonomy (`LocalTarget`, `RemoteTarget`, `LocalPromise`,
`RemotePromise`), kind-discriminated routing dispatch, local
shortening, and two flush protocols (`EJavaFlush` and
`OpFlushProtocol`).

The model focuses on the **message-order invariant**
**`EndToEndRefFIFO`** under a small fixed surface (one sender, one
reference) and shows where it holds and where it fails for each
routing policy.

## Reference taxonomy

Per-peer state `refs[p][r]` for every refId `r`:

| Kind            | Fields                                                                            |
|-----------------|-----------------------------------------------------------------------------------|
| `LocalTarget`   | (sink owned by `p`)                                                               |
| `RemoteTarget`  | `targetPeer`, `targetRefId`                                                       |
| `LocalPromise`  | `queue`, `listeners`, `resolution`, `flushPending`, `notified`                    |
| `RemotePromise` | `resolverPeer`, `resolverRefId`, `localResolution`, `embargo`, `flushPhase`, `pending` |

The pinned chain shape is

```
HeadPeer -> p_1@host[1] -> p_2@host[2] -> ... -> p_{N-1}@host[N-1] -> T@host[N]
```

where `host[1..ChainLength-1]` are promise resolvers and
`host[ChainLength]` hosts the terminal `LocalTarget`. RefIds are
**globally shared integers**: refId `i` names the same logical
capability on every peer that holds an entry for it. Promises are
1..ChainLength-1; the terminal is at `ChainLength`.

## Routing policies

Set via the `RoutingPolicy` constant in
[`spec/PromiseResolution.tla`](spec/PromiseResolution.tla):

- **`"NaivePromiseResolution"`** — listener installs `localResolution`
  immediately on `op:resolve`; race when head's pipelined ref-1 sends
  meet head's direct local delivery. Violates `EndToEndRefFIFO`.
- **`"NoPromiseResolution"`** — listeners are empty, no `op:resolve`
  ever fires; ref-1 sends always ride the wire through the chain.
  Holds.
- **`"ShorteningUnsafe"`** — listener installs `localResolution` on
  `op:resolve` without any flush; same race as Naive but on longer
  chains. Violates.
- **`"EJavaFlush"`** — on receipt of `op:resolve` at listener `L`, if
  `L` has pipelined ref-1 sends in flight, embargo + remember value;
  wait for `channels[L][resolverPeer]` to drain of `op:deliver-only`,
  then install + lift. **Local-only signal**, blind to downstream
  hops; violates `EndToEndRefFIFO` on 4-chains (canonical
  [kpreid race](https://github.com/ocapn/ocapn/issues/11#issuecomment-4525913499)).
- **`"OpFlushProtocol"`** — resolver-initiated. `ResolverResolve`
  sends `op:flush(r)` instead of `op:resolve`; each listener embargos
  its `RemotePromise[r]`, drains its outgoing channel to the
  resolver, sends `op:flush-ack`. The resolver waits for all acks
  AND its own queue/outgoing-to-target drained, then sends
  `op:resolve`. Under embargo (or while `pending` is non-empty), new
  sends are held in `RemotePromise.pending` and drain via the
  shortened path after `op:resolve` arrives. Holds.

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

## Layout

```
ocapn-tla-plus/
├── lib/
│   ├── References.tla    # ref taxonomy, MkChainRefs, PairingInvariant
│   ├── Network.tla       # per-pair FIFO channels
│   └── PeerState.tla     # sent, delivered (global)
├── spec/
│   └── PromiseResolution.tla
├── models/                # scenario MCs (policy-level race scenarios)
│   ├── MC_NoPromiseResolution.tla / .cfg
│   ├── MC_NoPromiseResolution_3Chain.tla / .cfg
│   ├── MC_NaivePromiseResolution.tla / .cfg
│   ├── MC_ShorteningUnsafe_4Chain.tla / .cfg
│   ├── MC_EJavaFlush_4Chain.tla / .cfg
│   ├── MC_OpFlushProtocol_4Chain.tla / .cfg
│   └── *_Debug.tla / .cfg     (DebugTrace TRUE for mermaid)
├── tests/                 # unit-test MCs (focused, single-mechanism)
│   ├── Unit_LocalTarget_Direct.tla / .cfg
│   ├── Unit_LocalShorten_Cascade.tla / .cfg
│   ├── Unit_RemoteTarget_Forward.tla / .cfg
│   └── Unit_Pipelining_On_Promise.tla / .cfg
├── notes/
│   ├── flush-protocols.md
│   ├── counterexample-naive-promise-resolution.txt
│   └── promise-shortening-op-flush.md
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

### Debug trace + mermaid

```bash
./scripts/run-tests.sh --debug MC_NaivePromiseResolution
./scripts/run-tests.sh --debug MC_EJavaFlush_4Chain
./scripts/run-tests.sh --debug MC_OpFlushProtocol_4Chain
```

Outputs in `.tlc-logs/`:

- `.tlc-logs/<MC>.debug.log` — full TLC output
- `.tlc-logs/<MC>.trace.md` — mermaid `sequenceDiagram`

### Single model

```bash
java -cp ~/tla/tla2tools.jar:lib:spec:models:tests tlc2.TLC \
     -workers auto \
     -config models/MC_NoPromiseResolution_3Chain.cfg \
     models/MC_NoPromiseResolution_3Chain.tla
```

## What this shows

- **Naive / ShorteningUnsafe**: any policy that installs the
  shortened path without a flush observably reorders messages.
- **EJavaFlush**: a local-only embargo-and-drain (resolver-direction
  channel only) is *not* sufficient on chains of length ≥ 4; messages
  already past the immediate resolver hop race with post-embargo
  shortened sends.
- **OpFlushProtocol**: resolver-initiated upstream flush, plus
  listener-side `pending` holding for in-flight messages, preserves
  end-to-end FIFO.

## Roadmap

- Phase 2: explicit `op:listen` subscription + `MC_SubscribeAfterResolve`.
- Phase 3: opaque 3-Party Handoff (`op:deposit-gift`,
  `desc:handoff-give`, `op:withdraw-gift`) with `GiftOneShot` and
  `GiftHasOneRecipient` invariants and `MC_ConcurrentHandoffs`.

See [`notes/flush-protocols.md`](notes/flush-protocols.md) for the
precise wire-level spec of both flush protocols.

## Fingerprint collisions

TLC dedupes by 64-bit fingerprint; distinct states can collide.
Re-run with `-fp K` (`0 ≤ K ≤ 63`) for extra confidence on large
models.
