# TLA+: ref-chain promise resolution, pipelining, and `EndToEndRefFIFO`

Modular TLA+ specs for a **linear ref-chain**: positions `1 .. ChainLength-1`
are promises, position `ChainLength` is the terminal object. Promise `i`
resolves implicitly to `i+1`. Each position `i` has a **host peer**
`host[i]` (resolver-holder for promises, object host for the terminal).
**Only the head peer** `host[1]` originates **`op:deliver-only`**, and only
on reference `1`; downstream hops **forward** the same message (same
`sender` / `seq` / `sentOnRef`) along the chain. Other wire messages (today:
`op:resolve-notify` from each resolver when it resolves) are sent by the
appropriate chain nodes.

Routing is selected by the **`RoutingPolicy`** constant in
[`spec/PromiseResolution.tla`](spec/PromiseResolution.tla) (wired from each
MC module):

- **`"NaivePromiseResolution"`** — after the head has learned resolutions
  along the whole chain, sends on ref `1` may take a **local** path to the
  terminal when it is co-located with the head (can break `EndToEndRefFIFO`).
- **`"NoPromiseResolution"`** — every send on ref `1` always goes
  **`viaResolver`** (queued or forwarded at `host[1]`); no post-resolution
  local shortcut.

**Primary knob:** `ChainLength` (with `Peers` fixed in the MC). Re-using the
same peer at several positions (`host` repeats a peer) models chains that
**loop through a node** without cyclic resolution.

## Message ordering: `EndToEndRefFIFO`

> For a **fixed sender peer** and a **fixed reference** `R`, every
> `op:deliver-only` that peer sends **on `R`** is applied at the terminal
> value of `R` in **strictly increasing send order** (by the model’s sequence
> numbers).

With the current “head-only sender” model, the only originator is
`(sender, ref) = (host[1], 1)`; the invariant is equivalent to “`delivered`
entries for that pair have strictly increasing `seq`.”

There is **no** claim about order across different senders or different
references.

Wire messages use OCapN-shaped names (`op:deliver-only`, `op:listen`,
`op:resolve-notify`). `op:resolve-notify` carries only the promise index; the
resolution target is implicit (`i` resolves to `i+1`). `op:listen` is named but
not exercised; see *Variant ideas* below.

## Layout

```
ocapn-tla-plus/
├── lib/
│   ├── References.tla         # ChainLength, host, resolved, knownByPeer
│   ├── Network.tla            # Per-pair FIFO channels
│   └── PeerState.tla          # localQueues, pending, sent, delivered
├── protocols/
│   ├── NaivePromiseResolution.tla
│   └── NoPromiseResolution.tla
├── spec/
│   └── PromiseResolution.tla  # Init/Next/Spec + EndToEndRefFIFO + lastAction
├── models/
│   ├── MC_NaivePromiseResolution.tla / .cfg
│   ├── MC_NaivePromiseResolution_Debug.tla / .cfg   (DebugTrace TRUE)
│   ├── MC_NoPromiseResolution.tla / .cfg
│   └── MC_NoPromiseResolution_3Chain.tla / .cfg
├── notes/
│   └── counterexample-naive-promise-resolution.txt
└── scripts/
    ├── run-tests.sh           # Matrix + optional --debug
    ├── trace-to-mermaid.sh    # Wrapper → trace_to_mermaid.py
    └── trace_to_mermaid.py    # TLC log → mermaid sequenceDiagram
```

TLC classpath: `lib:protocols:spec:models` (see `run-tests.sh`).

**Routing:** Stateless helpers live under `protocols/`; `PromiseResolution`
dispatches by `RoutingPolicy` (no `INSTANCE` substitution of stateful
operators).

**Scenarios:** `host` is chosen existentially in `Init`; TLC enumerates
topologies. Only `Peers`, `ChainLength`, `NumMessages`, and policy are fixed
in each MC. `SYMMETRY` is omitted because `host` is not symmetric under
arbitrary peer permutations.

## How to run

Install `tla2tools.jar` (TLC 2.x), e.g.:

```bash
mkdir -p ~/tla
curl -sSL -o ~/tla/tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
```

From the repo root:

```bash
./scripts/run-tests.sh
```

This runs every model in the `TESTS` matrix, records TLC logs under
`.tlc-logs/`, and exits non-zero if an outcome disagrees with the expected
one (`pass` vs `violation`).

### Debug trace + mermaid diagram

Re-run the naive counterexample with **`DebugTrace`** and emit a mermaid
`sequenceDiagram`: **arrows** from `channels` diffs, **notes** from `lastAction`.

```bash
./scripts/run-tests.sh --debug MC_NaivePromiseResolution
```

Outputs:

- `.tlc-logs/MC_NaivePromiseResolution.debug.log` — full TLC output  
- `.tlc-logs/MC_NaivePromiseResolution.trace.md` — mermaid `sequenceDiagram`

Participants are the MC’s `Peers` values (`vatA`, `vatB` in the stock MCs).
**Arrows** come from diffing `channels` between successive TLC states (new
tail on `channels[from][to]`). **Notes** come from `lastAction` for steps
that do not show as channel writes (local queues, self pending, etc.).

You can also pipe any TLC log manually:

```bash
python3 scripts/trace_to_mermaid.py < .tlc-logs/MC_NaivePromiseResolution.debug.log
```

### Single model (TLC CLI)

```bash
java -cp ~/tla/tla2tools.jar:lib:protocols:spec:models tlc2.TLC \
     -workers auto \
     -config models/MC_NoPromiseResolution_3Chain.cfg \
     models/MC_NoPromiseResolution_3Chain.tla
```

## What this shows

**Naive:** `EndToEndRefFIFO` can fail when the head learns full-chain
resolution and may deliver locally while earlier `op:deliver-only` messages
on ref `1` are still queued or in flight toward the terminal.

**No-promise:** With no post-resolution shortcut on ref `1`, the invariant
holds for the checked MCs (two-peer `ChainLength = 2`, `NumMessages = 3`, and
`ChainLength = 3`, `NumMessages = 2`).

**Not shown:** Multiple deliver-only originators, `op:listen`-based
propagation, Disembargo / `op:flush`, promise-to-promise shortening beyond
the implicit chain — only the hazard surface for the stated invariant.

## Variant ideas (not yet implemented)

- **`op:listen`-based resolution propagation** instead of broadcasting
  `op:resolve-notify` to every peer.
- **Disembargo / `op:flush` / DelayedRedirector** — fence the pipeline before
  path switchover.
- **Intermediate shortening** (skip intermediate resolver hops) as a
  separate `RoutingPolicy`.

See [CapTP draft](https://github.com/ocapn/ocapn/blob/main/draft-specifications/CapTP%20Specification.md#promise-and-resolver-objects).

## Fingerprint collisions

TLC dedupes by 64-bit fingerprint; distinct states can collide. Re-run with
`-fp K` (`0 ≤ K ≤ 63`) if you need extra confidence on large models.

## Pointers

- E-on-Java `DelayedRedirector`, Cap’n Proto `Disembargo`, Waterken flush,
  Ridley `op:flush` — candidate follow-on protocol modules
