# TLA+: OCapN promise resolution, pipelining, and `EndToEndRefFIFO`

Modular TLA+ specs for **promise resolution** (here: a promise resolves to a
**remotable object**) plus pipelined **`op:deliver-only`**, with **per-pair
FIFO** transport between peers.

Routing is selected by the **`RoutingPolicy`** constant in
[`spec/PromiseResolution.tla`](spec/PromiseResolution.tla) (wired from each
MC module). The values match the protocol-module names:

- **`"NaivePromiseResolution"`** — after a peer learns a promise's resolution,
  sends on that **same promise reference** may take a local path to the
  terminal object when it is co-located with the sender (can break
  `EndToEndRefFIFO`).
- **`"NoPromiseResolution"`** — every send on a promise **always** goes via
  the resolver (`viaResolver`); no post-resolution shortcut. All calls remain
  pipelined on the original path.

"Pipelining" here means a sender may emit `op:deliver-only` on a promise
**before** the promise is resolved. Both policies pipeline; they differ only
in what happens after resolution.

**Shortening** in the broader protocol sense (chain shortening when a
promise resolves to another promise) is **not** modeled yet; it can be a
separate protocol module later.

## Message ordering: `EndToEndRefFIFO`

The property checked here is **only**:

> For a **fixed sender peer** and a **fixed reference** `R`, every
> `op:deliver-only` that peer sends **on `R`** is applied at the terminal
> value of `R` in **strictly increasing send order** (by the model's
> per-(peer, `R`) sequence numbers).

There is **no** claim about:

- messages from **different** senders, or
- **order across different references** — for example sends on a promise
  and sends on whatever it resolved to are two separate streams; the
  invariant does not relate them.

Wire messages use OCapN-shaped names (`op:deliver-only`, `op:listen`,
`op:resolve-notify`). `op:resolve-notify` is a real wire message in this
model: the resolver appends it to every other peer's channel at the moment
of resolution. `op:listen` is named but not yet exercised; see *Variant
ideas* below.

## Layout

```
ocapn-tla-plus/
├── lib/                       # Foundation modules (no protocol semantics)
│   ├── References.tla         # Objects, Promises, topology, resolution chain
│   ├── Network.tla            # Per-pair FIFO channels
│   └── PeerState.tla          # localQueues, pending, sent, delivered
├── protocols/                 # Stateless routing helpers
│   ├── NaivePromiseResolution.tla
│   └── NoPromiseResolution.tla
├── spec/
│   └── PromiseResolution.tla  # Top-level Init/Next/Spec + EndToEndRefFIFO
├── models/                    # One MC module + cfg per scenario
│   ├── MC_NaivePromiseResolution.tla
│   ├── MC_NaivePromiseResolution.cfg
│   ├── MC_NoPromiseResolution.tla
│   └── MC_NoPromiseResolution.cfg
├── notes/                     # Trace narratives, design notes
│   └── counterexample-naive-promise-resolution.txt
└── scripts/
    └── run-tests.sh           # Runs every MC, classifies outcomes
```

TLC finds modules by directory + Java classpath; the script wires
`lib:protocols:spec:models` into `-cp` so every module is reachable.

**Why one MC module per scenario:** TLA+'s `INSTANCE` substitution cannot
replace a state-dependent operator with an outer definition that closes
over primed variables. Routing therefore lives in a stateless module
(`protocols/*`) and is **extended** by `PromiseResolution`, which selects
between them via the `RoutingPolicy` constant.

**Scenarios:** Topology (`objHost`, `promResolver`) and resolver choices are
picked existentially in `Init`; TLC enumerates them in one run. Only sizes
(`NumMessages`, finite `Peers` / `Objects` / `Promises`) are fixed in the MC
module. `SYMMETRY` is omitted because `objHost` / `promResolver` maps are
not symmetric under arbitrary peer permutations.

## How to run

You need `tla2tools.jar` (TLC 2.x). One way to get it:

```bash
mkdir -p ~/tla
curl -sSL -o ~/tla/tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
```

Then, from the repo root:

```bash
./scripts/run-tests.sh
```

The script runs every model in `models/`, captures TLC's exit code per MC,
and prints a table:

```
MODEL                             EXPECTED    ACTUAL      DETAIL
--------------------------------  ----------  ----------  -------
MC_NaivePromiseResolution         violation   violation   Invariant EndToEndRefFIFO_MC is violated
MC_NoPromiseResolution            pass        pass        45132720 distinct / 122400388 generated
```

It exits non-zero only when an MC's actual outcome disagrees with the
expected one declared in the script's `TESTS` matrix. Full TLC output for
each MC is left in `.tlc-logs/<module>.log`. Override TLA jar location with
`TLA_JAR=/path/to/tla2tools.jar` and worker count with `WORKERS=N`.

To run a single MC directly:

```bash
java -cp ~/tla/tla2tools.jar:lib:protocols:spec:models tlc2.TLC \
     -workers auto \
     -config models/MC_NoPromiseResolution.cfg \
     models/MC_NoPromiseResolution.tla
```

### Run-time expectations (`NumMessages = 3`, two peers, one promise, one object)

| Model                          | Outcome   | States                              | Time (M2-class) |
|--------------------------------|-----------|-------------------------------------|------------------|
| `MC_NaivePromiseResolution`    | violation | ~4k explored before halt            | ~1 s             |
| `MC_NoPromiseResolution`       | pass      | ~45M distinct (~122M generated)     | ~3–12 min        |

`MC_NaivePromiseResolution` halts at the first invariant violation, so the
state count is "states until first counterexample," not the full reachable
set. Don't read it as "the naive variant has a smaller state space than the
no-promise variant" — to compare fairly, drop `INVARIANT
EndToEndRefFIFO_MC` from the Naive `.cfg` and re-run.

### Fingerprint-collision estimates

TLC dedupes states by 64-bit hash ("fingerprint"). Two distinct states can
share a hash, and TLC will silently skip the later one. The two
probabilities printed at the end of a successful run are upper bounds on
the chance this happened: a calculated estimate, and one based on actual
fingerprint distribution. Values around `1e-4` mean roughly 1 in 10,000
odds the run missed a state. To increase confidence, re-run with `-fp K`
for a different seed (`0 ≤ K ≤ 63`) and confirm the same result.

## What this does / doesn't prove

**Shows (naive):** `EndToEndRefFIFO` can fail when a sender learns a
resolution and may deliver locally while earlier `op:deliver-only` messages
on the **same** promise reference are still in flight on the resolver path.

**Shows (no-promise):** Under the same FIFO and topology model, with **no**
post-resolution shortcut on promises, **`EndToEndRefFIFO`** holds for the
checked configuration (`NumMessages = 3`, two peers, one promise, one
object — the smallest setting that admits the naive failure trace).

**Does not show:** Cross-sender scenarios, chain shortening to another
promise, partition, or any particular fix — only the hazard surface for the
stated invariant.

## Variant ideas (not yet implemented)

These are intended as additional `RoutingPolicy` values or as parallel
hooks; the seam is already in `PromiseResolution.RouteSend` /
`OnReceiveResolution`.

- **OCapN `op:listen`-based resolution propagation.** Currently the
  resolver broadcasts `op:resolve-notify` to every other peer at resolution
  time. In the [CapTP draft][captp], peers explicitly `op:listen` on a
  promise and the resolver-holder notifies each listener (often via
  `op:deliver` to the listener's resolver object). Adding this would mean
  modeling `op:listen` as an action (peer subscribes), tracking
  subscriptions per `(promise, listener)`, and replacing the broadcast in
  `ResolverResolve` with per-listener notification.

  Note that `op:deliver` (the request/response variant of `op:deliver-only`)
  carries an **implicit `op:listen`** via its optional `resolve-me-desc`
  field: when present, the resolver-holder MUST notify the named resolver
  on resolution, with no separate `op:listen` round-trip. So a future
  listen-based model only needs explicit `op:listen` for the case where a
  peer that previously sent `op:deliver-only` (or `op:deliver` without
  `resolve-me-desc`) later decides it wants the resolution.
- **Disembargo / `op:flush` / DelayedRedirector.** Each would add a
  protocol module with a non-empty `OnReceiveResolution` (fence message
  sequence) and corresponding `ProtocolNextExtra` actions to drain the
  pipeline before the path switchover.
- **Chain shortening** (promise-resolves-to-promise). Requires extending
  `resolution[pr]` to allow promise targets and revising `TerminalRef` to
  follow the chain across peers.

[captp]: https://github.com/ocapn/ocapn/blob/main/draft-specifications/CapTP%20Specification.md#promise-and-resolver-objects

## Pointers

- E-on-Java `DelayedRedirector`, Cap'n Proto `Disembargo`, Waterken flush,
  Ridley `op:flush` — candidate follow-on protocol modules
