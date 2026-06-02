# Path changes: resolution, shortening, and what this spec models

This note pins down the terminology used throughout the spec and READMEs,
distinguishes what the model currently covers from what it doesn't, and
catalogues tracked future work. It is the canonical home for the
terminology that [`README.md`](../README.md) references and for forward-
looking items that don't belong in the protocol reference
([`notes/flush-protocols.md`](flush-protocols.md)).

## 1. Definitions

**Path change.** Any event that changes the network route a future send
on a ref will take. A path change is the source of the FIFO-violation
hazard in promise pipelining: an in-flight send on the *old* path may
race with a new send on the *new* path and arrive at the terminal out
of order. Every routing policy in this spec is a different answer to
the same question: *how do you commit to the new path without letting
later sends overtake earlier ones?*

The model recognises two flavours of path change, distinguished by what
a `LocalPromise` ends up resolving to.

### 1.1 Promise resolution — `LocalPromise` -> `Target`

A `LocalPromise` resolves to a `Target` (`LocalTarget` or
`RemoteTarget`) — a concrete capability, not another promise.

- **Wire propagation:** `op:resolve(refId, desc:import-target | desc:export-target | desc:handoff-give)`
  is sent from the resolver to every listener.
- **Listener effect:** the listener installs `RemotePromise.localResolution`
  to the new target; future sends route directly through the target
  instead of being pipelined through the resolver.
- **Modelled by:** every `MC_*` flush-protocol test
  (`NaivePromiseResolution`, `ShorteningUnsafe`, `EJavaFlush`,
  `OpFlushProtocol`). The chain `H -> p_1 -> ... -> p_{N-1} -> T@host[N]`
  emits exactly one `op:resolve` of this form: from `host[N-1]` (which
  is adjacent to the terminal) carrying `desc:import-target` or
  `desc:export-target` as appropriate for each listener.

This is the **only** kind of path change that travels over the wire in
the current spec.

### 1.2 Promise shortening — `LocalPromise` -> `Promise`

A `LocalPromise` resolves to another `Promise`, not yet a value. Two
sub-cases:

#### 1.2.a Intra-vat promise shortening — modelled

The new promise is hosted by the *same* vat as the resolving promise.
The resolver silently drains the resolved promise's `queue` into the
new promise's `queue` (or, recursively, into whatever the new promise
points to, cascading until something terminal). **No wire traffic** is
emitted by the shortening itself; remote listeners stay on their
`RemotePromise` to the original ref and only observe the eventual
*terminal-target* resolution via the regular `op:resolve` mechanism
(§1.1).

Modelled by `Unit_LocalShorten_Cascade` (chain
`HeadPeer = vatA hosts p_1, p_2; vatB hosts the terminal`; `p_1`
resolves to `p_2`, both on vatA, then `p_2` resolves to the terminal —
sends pipelined into `p_1.queue` cascade into `p_2.queue` and out the
wire). The intermediate linear-chain MCs (the `MC_*_NParty` models,
e.g. `MC_EJavaFlush_4Party` / `MC_EJavaFlush_5Party`)
exercise the same mechanism as a side effect: each non-terminal
`ResolverResolve` records a `resolution = ResRef(host[r+1], r+1)`
on the LocalPromise without firing any wire message.

#### 1.2.b Inter-vat (distributed) promise shortening — partially modelled (Phase A)

The new promise is hosted by a *different* vat. To preserve FIFO,
listeners learn about the new promise's host so they can shorten their
own dispatch through it. The protocol surface decomposes into:

1. **Wire descriptors.** `desc:import-promise(refId)` /
   `desc:export-promise(refId)` exist in the spec's value alphabet
   (analogous to the target descriptors, sender/receiver-relative).
   `desc:handoff-give` now carries a Promise cap too (Phase B).
   — **Done** (Phases A + B).
2. **Resolver-side emission.** `ResolverResolve` fires
   `op:resolve(refId, desc:export-promise|import-promise)` to a
   listener when its `LocalPromise.resolution` points at a Promise on
   another vat AND every listener can receive the resolution
   two-party. — **Done** (Phase A; extended to `EJavaFlush` and
   `OpFlushProtocol` in Phase C). For three-party listeners, the
   resolver fires `desc:handoff-give` (3PHO) for the Promise cap.
   — **Done** (Phase B; witness-gated under flush policies — §3.10).
3. **Listener-side install.** The existing
   [`ReceiveNetwork`](../spec/Core.tla) branch at
   `msg.value.desc \in TargetWireDescs` handles `desc:import-promise`
   and `desc:export-promise` via `DescToResRef` under all policies;
   the EJavaFlush `sameConn` fast path is restricted to
   `desc:import-target` only (Phase C — promise descriptors take the
   slow embargo + probe path). — **Done** (Phase A, refined in
   Phase C).
4. **Re-propagation to upstream listeners.** When a non-head chain
   peer locally learns a downstream shortening, it notifies its
   own upstream listeners via `RepropagatePromiseShorten` (Phase D;
   `EnableRepropagate`). — **Done** (see §3.11).
5. **Flush mechanism for the new race surface.** — **Done** for
   2-party and 3-party shortening under `EJavaFlush` /
   `OpFlushProtocol` (Phase C; per-node conditions only — see §3.10).
   EJavaFlush 3-party is witness-gated; OpFlush is not. Tribble:
   EJava violates FIFO; OpFlush passes (§3.11).

Phase A surfaces the race directly:
[`MC_NaivePromiseResolution_2Party_PromiseShorten.tla`](../models/MC_NaivePromiseResolution_2Party_PromiseShorten.tla)
violates `EndToEndRefFIFO_MC` on the new code path, dual to the
canonical `MC_NaivePromiseResolution_2Party` for Targets. The Phase A
two-party form alone is not enough to reproduce the **Tribble
four-way scenario** (see §3.1) — the multi-hop re-propagation in
step 4 and the flush extension in step 5 are still required.

### 1.3 Local routing recursion is not a separate path change

When `Route(p, r)` encounters a resolved `LocalPromise` or a
`RemotePromise` with a non-empty `localResolution`, it recurses through
that resolution. This is **send-time outbound routing only** — a
sender skipping a logical hop because it has already learned the new
target. It is the *operational consequence* of a path change (§1.1 or
§1.2.a), not a third category.

Earlier drafts of these docs called this "local shortening at send
time"; that phrase is dropped because it conflated routing with the
state-changing path-change events.

## 2. How each routing policy handles a path change

| Policy | Path-change handling | Path-change hazard model | FIFO outcome |
|---|---|---|---|
| `NoPromiseResolution` | No `op:resolve` is ever emitted; listeners stay on their `RemotePromise`s forever. | No path change ⇒ no hazard. | Holds. |
| `NaivePromiseResolution` | Listener installs `localResolution` immediately on `op:resolve` receipt. | Path change with zero synchronisation — in-flight pipelined sends on the old path race against new sends on the new path. | Violates `EndToEndRefFIFO` on a 2-chain (canonical counterexample). |
| `ShorteningUnsafe` | Same as Naive (the name is OCapN-colloquial for "installs the new path without a flush", not literally about §1.2 promise shortening). | Same hazard, demonstrated on longer chains. | Violates `EndToEndRefFIFO` on a 3-chain (`MC_ShorteningUnsafe_4Party`). |
| `EJavaFlush` | Faithful e-on-java `DelayedRedirector` model: subscriber-initiated end-to-end probe + ack along the old path before committing to the new one. New sends buffer locally until the ack returns. | Probe rides the same FIFO channels as in-flight sends, so the ack is a protocol-level guarantee that everything pre-flush has been processed at the terminal. | Holds for linear chains; **does not** hold for Tribble four-way (§3.1). |
| `OpFlushProtocol` | Resolver-initiated: `op:flush` to listeners (each listener acks via FIFO of its own outbox), then resolver-initiated probe + ack to the terminal target, only then `op:resolve` to listeners. Locality-clean: every state transition is driven by an explicit protocol message; no peer reads another peer's channel state. | Same end-to-end primitive (probe + ack) as EJavaFlush, layered under a listener-flush handshake. | Holds for linear chains (modelled three-party form of the Ridley proposal); the four-party form is future work (§3.1). |

The `Shortening` in `ShorteningUnsafe` is a historical OCapN-colloquial
usage where "shortening" denotes the umbrella act of changing a ref's
route — what this note calls a **path change**. The policy name is
kept for continuity with the OCapN discussion threads; it is not
specifically about §1.2 promise shortening.

## 3. Tracked future work

### 3.1 Tribble four-way scenario

The canonical four-party scenario in which a faithful `DelayedRedirector`
([kpreid race](https://github.com/ocapn/ocapn/issues/11#issuecomment-4525913499))
is defeated: intermediate hops on the chain are themselves
concurrently shortening while the EJavaFlush sentinel is in transit.
The probe rides a single linear path; parallel path-changes on the
same path can race past it. The Ridley proposal claims the four-party
form of `op:flush` addresses this; this spec models only the
three-party form.

Reproducing this in a model check requires the inter-vat distributed
promise shortening machinery in §1.2.b (each chain node must be able
to propagate learned downstream resolutions to its own upstream
listeners — otherwise there's only one shortening per run and the
four-way race shape doesn't arise). The work decomposes into four
phases; Phases A, B, C (2- and 3-party flush), and Phase D
(re-propagation + Tribble MCs) are landed. Flush “propagation” is
**emergent from per-node local predicates only** (no cross-node
`op:flush` relay); see §3.10–§3.11.

**Phase A — two-party promise shortening (done; see §3.8).** Resolver
emits `desc:import-promise` / `desc:export-promise` when listeners are
two-party-reachable. Receive path was already wired. Gated to
`NaivePromiseResolution` and `ShorteningUnsafe`.
[`MC_NaivePromiseResolution_2Party_PromiseShorten`](../models/MC_NaivePromiseResolution_2Party_PromiseShorten.tla)
and [`Unit_PromiseShorten_TwoParty`](../tests/Unit_PromiseShorten_TwoParty.tla)
exercise it.

**Phase B — three-party promise shortening (done; see §3.9).**
Extended `desc:handoff-give` and the deposit/withdraw machinery to
gift a `LocalPromise` cap; withdraw reply now uses
`desc:export-promise` when the gifted `targetLocalRefId` resolves to
a `LocalPromise` on the target host (`ReceiveOpWithdrawGift`
dispatches on `LocalRef(self, tlr).kind`). `HandoffInitiate` accepts
`srcRef.kind \in {RemoteTarget, RemotePromise}` and derives the
target host / target local refId from `srcEntry`'s resolver fields
when promise-shaped (subject to a `srcRef # existingRefId` guard
that prevents a degenerate self-cycle under v0 globally-shared chain
refIds). `ResolverResolve` fires the 3-party handoff path
(`firePromiseShorten3Party`) under `NaivePromiseResolution` and
`ShorteningUnsafe`. Witnessed by `Unit_PromiseShorten_ThreeParty`
and exercised by `MC_NaivePromiseResolution_3Party` (Naive surfaces
the new race with `EndToEndRefFIFO_MC` violation; the chain MC is
the dual of `MC_NaivePromiseResolution_2Party_PromiseShorten` for
three-party chains).

**Phase C — flush extensions (done; see §3.10).** 2-party and
3-party forms under `EJavaFlush` / `OpFlushProtocol`.
`ListenersWitnessPipelined` (`pipelinedListeners` on the resolver's
`LocalPromise`, updated when listener traffic arrives) gates
**EJavaFlush** 3-party emission only; **OpFlushProtocol** uses `OpFlushCoversPromise` /
`OpFlushResolverCoversPromise` (no `fresh` gate). Head-hop (`r = 1`)
and `CoTerminalPromiseHost` limit resolver-initiated 3PHO on long
chains (`MC_EJavaFlush_5Party` ~2554 states). Witnessed by `MC_EJavaFlush_2Party_PromiseShorten`,
`MC_OpFlushProtocol_2Party_PromiseShorten`,
`MC_EJavaFlush_3Party_PromiseShorten`, and
`MC_OpFlushProtocol_3Party_PromiseShorten` (the latter pair
use `NumMessages = 1` for a single in-flight send; the two-message
race remains in `MC_NaivePromiseResolution_3Party`).

**Phase D — re-propagation + Tribble MCs (done; see §3.11).**
`RepropagatePromiseShorten` (gated by `EnableRepropagate`) notifies
upstream listeners when a peer locally learns a downstream
shortening. Tribble MCs on the three-peer co-terminal topology:
`MC_EJavaFlush_TribbleFourWay` (**violates** `EndToEndRefFIFO_MC`);
`MC_OpFlushProtocol_TribbleFourWay` (**passes** with `NumMessages = 2`
after OpFlush listener flush is no longer gated on `fresh`; see §3.11).

### 3.2 Per-peer refId namespaces

The v0 spec uses globally-shared refIds: a single integer `r` names
the same logical capability on every peer that holds an entry for it.
Real OCapN uses per-peer (per-session) import/export tables; messages
reference refIds in the destination peer's namespace. The translation
is mechanical (per-pair refId map state) but adds bookkeeping without
changing any of the protocols. Out of scope for the current spec.

### 3.3 Ref-scoped flush drainage

The flush protocols currently drain a whole channel rather than
filtering for the specific ref being resolved. For our linear chains
this is equivalent (ref-1 traffic dominates) and the simpler form
keeps the spec readable. A ref-scoped variant is a tractable
optimisation if multi-ref scenarios become relevant.

### 3.4 Multi-sender FIFO testing

`EndToEndRefFIFO` is already stated per-`(sender, ref)`. Multi-sender
scenarios fall out naturally once handoff produces multiple ref
holders, but no MC currently exercises this. A small `MC_MultiSender`
that drives two `HeadPeer`s into the same chain would close the gap.

### 3.5 Wire descriptor invariants in dynamic MCs

`spec/Core.tla` defines two global invariants over
`channels`: `WireDescriptorContract` (no `desc:handoff-give` with
`targetHost \in {sender, receiver}`) and `OnlyKnownResolveDescriptors` (every
non-handoff `op:resolve` descriptor is in `TargetWireDescs`). They are
currently checked only by the static-state `Unit_WireDesc_DescriptorChoice`
unit (`Spec == Init /\ [][Stutter]_vars`, 1 distinct state). Every
dynamic MC with `EnableHandoff = TRUE` should add both invariants to its
`.cfg`. Per-state cost is O(|Peers|² × FIFO depth) — a few percent at
most — and state counts are unchanged.

Affected configs: `MC_EJavaFlush_4Party.cfg`, `MC_EJavaFlush_5Party.cfg`,
`MC_OpFlushProtocol_4Party.cfg`, `MC_ShorteningUnsafe_4Party.cfg`,
`MC_TerminalHandoff_Baseline.cfg`, `MC_TerminalHandoff_WithForwarder.cfg`,
`MC_ConcurrentHandoffs.cfg`, and the four `Unit_Handoff_*.cfg` units.

### 3.6 EJavaFlush debug invariant `NoSlowPathCompletion_MC` no longer scopes the slow path

`MC_EJavaFlush_4Party.tla` and `MC_EJavaFlush_5Party.tla` define a debug
invariant intended to force TLC's BFS to render the shortest trace that
exercises the EJavaFlush slow path (`OpEFlushProbe -> OpEFlushProbeAck
-> ProcessHold` drain). The predicate matches a `RemotePromise` with
`localResolution # ResNone, fresh = FALSE, embargo = FALSE`.

With `EnableHandoff = TRUE`, BFS now finds a shorter satisfying state on
a *handoff withdraw-promise* `pw > ChainLength`: the recipient pipelines
through `refs[pw]` (clears `fresh`), then `op:withdraw-gift` resolves
the target host's `LocalPromise(pw)` and the resulting
`op:resolve(pw, desc:import-target)` takes the `isHandoffPw ->
installNow` branch in `ReceiveNetwork`, which writes `embargo := FALSE`
without ever sending a probe. The debug log then has zero
`op:e-flush-probe*` events (verified on the current 3-Chain and 4-Chain
debug runs).

Fix: scope the existential to chain refs only — replace
`\E r \in 1..MaxRefId` with `\E r \in 1..ChainLength` in both EJavaFlush
model files. (`MC_OpFlushProtocol_4Party.tla`'s predicate is not
affected: it requires `flushPhase = "acked"`, which only the
resolver-side slow-path actions set, so handoff withdraw-promises
cannot satisfy it.)

### 3.7 Focused unit coverage for the chain-form `handoff-give` slow path

The chain MCs incidentally cover the `desc:handoff-give` chain-form
`chainEmbargo` branch in `ReceiveNetwork` (an `embargo=TRUE` invariant
violation is reachable in `MC_EJavaFlush_4Party` within ~180 distinct
states), but the focused units that were supposed to pin this slow path
had been silently downgraded by the descriptor refactor into 2-party
`desc:export-target` / `desc:import-target` scenarios. Restored as
follows:

  - **`tests/Unit_EJavaFlush_EmbargoFires.tla`** — rewritten back to its
    original 3-party intent, with `vatC` introducing `T@vatA` to its
    listener `vatB` via `desc:handoff-give`. `vatB` has already
    pipelined a forward through its chain ref to `vatC`, so
    `chainEntry.fresh = FALSE` and the chain-form receive takes
    `chainEmbargo = TRUE`. Witness invariant `EmbargoNeverFires_MC`
    fires (expected: violation).
  - **`tests/Unit_EJavaFlush_RefScopedEmbargo.tla`** — rewritten as the
    matching 3-party negative test: `vatB` introduces `T@vatC` to
    `vatA` via `desc:handoff-give`, with unrelated pre-resolve traffic
    on `channels[vatA][vatC]` keyed by `vatA.refs[2]`. Because
    `vatA.refs[1].fresh = TRUE`, `chainEmbargo = FALSE` and no
    spurious embargo lands on `vatA.refs[1]` (expected: pass).
  - **`tests/Unit_EJavaFlush_HandoffChainProbe.tla` (new)** — same
    pre-state as `EmbargoFires`, with a stronger joint witness:
    `HandoffChainNoSlowPath_MC` asserts the negation of
    `(vats[recipient].refs[targetRefId].embargo = TRUE) /\
    (channels[recipient][resolverPeer]` contains
    `op:e-flush-probe(originPeer=recipient, originRefId=targetRefId,
    refId=chainEntry.resolverRefId))`. TLC reports a violation; the
    counterexample's terminal state has both effects in the same
    `ReceiveNetwork` step (expected: violation). Catches asymmetric
    regressions (probe-without-embargo or embargo-without-probe) that
    `EmbargoFires` alone would miss.

All three units are wired into `scripts/run-tests.sh` with their
expected outcomes.

### 3.8 Phase A: two-party inter-vat promise shortening

Implements §1.2.b's two-party form — `ResolverResolve` emits
`op:resolve(refId, desc:import-promise | desc:export-promise)` to
listeners when a `LocalPromise` shortens to a Promise on another vat
and every listener can receive the resolution two-party. Receive path
was already wired (the `desc \in TargetWireDescs` branch in
[`ReceiveNetwork`](../spec/Core.tla) accepts both target
and promise descriptors uniformly across all policies); only the
emission side was missing.

Spec delta in [`spec/Core.tla`](../spec/Core.tla):

- `TargetHostPeer` / `TargetWireRefId` generalised from two-arm
  (`LocalTarget` vs else-`targetPeer`/`targetRefId`) to four-arm
  (`LocalTarget`/`LocalPromise` -> resolver, `RemoteTarget` ->
  `targetPeer`/`targetRefId`, `RemotePromise` ->
  `resolverPeer`/`resolverRefId`). Previously the else arm returned
  garbage on Promise-kind entries; safe pre-refactor because nothing
  reached it.
- New helpers `IsResolutionPromise(self, res)` (dual of
  `IsResolutionTarget`) and `AllListenersTwoParty(resolver, res,
  listeners)` (negates `NeedsHandoffIntro` over the listener set).
- New disjunct `firePromiseShorten` inside `ResolverResolve`'s
  `fireOpResolveNow` LET-binding, gated in Phase A to
  `NaivePromiseResolution` and `ShorteningUnsafe` (Phase C later
  added `EJavaFlush`; `OpFlushProtocol` runs its full flush
  handshake around the promise emission via `fireOpFlush` —
  see §3.10). In Phase A, `fireOpFlush` and `needsHandoff` stayed
  `isTarget`-only; the Phase A emission therefore never triggered
  `OpFlushProtocol`'s flush machinery, nor `desc:handoff-give`.

Tests added:

- **[`tests/Unit_PromiseShorten_TwoParty.tla`](../tests/Unit_PromiseShorten_TwoParty.tla)**
  — pins the `desc:export-promise` wire shape on
  `channels[vatB][vatA]` after vatB's `ResolverResolve` fires.
  Witness invariant `NoExportPromiseEmitted_MC` is the negation;
  expected outcome: violation.
- **[`models/MC_NaivePromiseResolution_2Party_PromiseShorten.tla`](../models/MC_NaivePromiseResolution_2Party_PromiseShorten.tla)**
  — surfaces the new race surface. Two peers, ChainLength = 3,
  `host = <<vatB, vatA, vatA>>` (so the new promise's host vatA is
  also the listener; chain terminus on vatA). Expected outcome:
  `EndToEndRefFIFO_MC` violation, dual to the Target form in
  `MC_NaivePromiseResolution_2Party`.

Why gated to Naive + Shortening only:

- The new race surface (in-flight forwards on the old path through
  the original resolver racing direct sends on the new path through
  the new promise's host) is exactly what those policies are designed
  to surface.
- `EJavaFlush` and `OpFlushProtocol` would need extensions for
  promise-shaped chains (Phase C). Without them, enabling promise
  emission under those policies would silently introduce FIFO
  violations on flush-protocol MCs that currently pass — masking
  real bugs.
- The existing flush-protocol chain MCs (`MC_EJavaFlush_4Party`,
  `MC_EJavaFlush_5Party`, `MC_OpFlushProtocol_4Party`) all use 3+
  distinct peers, so even after Phase B introduces three-party
  promise shortening, they need Phase C before they exercise
  promise-shaped chains end-to-end.

### 3.9 Phase B: three-party inter-vat promise shortening

Extends §1.2.b to the three-party form, where the listener and the
new promise's host are distinct peers from the resolver, so the
resolver must introduce the cap via `desc:handoff-give` rather than
emitting `desc:export-promise` / `desc:import-promise` directly.

Spec delta in [`spec/Core.tla`](../spec/Core.tla):

- `ReceiveOpWithdrawGift` now dispatches on
  `LocalRef(self, tlr).kind`. For `LocalTarget` the reply remains
  `desc:import-target(tlr)`; for `LocalPromise` it is
  `desc:import-promise(tlr)`. Same code path otherwise — the gift
  table still records the `targetLocalRefId` and pre-mints the
  `pw` `LocalPromise` at deposit time; only the resolution descriptor
  flips.
- `HandoffInitiate` accepts `srcRef.kind \in {RemoteTarget,
  RemotePromise}`. For `RemotePromise`, `targetHost` is
  `srcEntry.resolverPeer` and `targetLocalRef` is
  `srcEntry.resolverRefId`. An additional `existingRefId # srcRef`
  guard prevents a degenerate self-cycle: under v0 globally-shared
  chain refIds, chain-binding the gifter's own `srcRef` as the
  `existingRefId` makes the receiver install
  `refs[srcRef].localResolution = ResRef(_, pw)` while the
  withdraw reply `desc:import-promise(srcRef)` makes
  `refs[pw].localResolution = ResRef(_, srcRef)` — a `Route`
  recursion cycle that crashes TLC with a `StackOverflowError`.
- `ResolverResolve` distinguishes `firePromiseShorten` (2-party,
  Phase A) from `firePromiseShorten3Party` (3-party, Phase B).
  `needsHandoff` fires when `isTarget` OR
  `firePromiseShorten3Party`. The 3-party gate is restricted to
  `NaivePromiseResolution` and `ShorteningUnsafe` (see §3.10 for
  why `EJavaFlush`/`OpFlushProtocol` are deferred).

Tests added:

- **[`tests/Unit_PromiseShorten_ThreeParty.tla`](../tests/Unit_PromiseShorten_ThreeParty.tla)**
  — witnesses the `desc:handoff-give` wire shape carrying a Promise
  cap on `channels[vatB][vatA]` after vatB's `ResolverResolve` fires
  in a three-peer topology (`host = <<vatB, vatC, vatC>>`,
  HeadPeer = vatA, listener vatA, capHost vatC). Witness invariant
  `NoChainHandoffGiveForPromise_MC` is the negation; expected
  outcome: violation.
- **[`models/MC_NaivePromiseResolution_3Party.tla`](../models/MC_NaivePromiseResolution_3Party.tla)**
  — surfaces the three-party race under Naive: vatB's chain
  resolution becomes a 3PHO at runtime, vatA's withdraw replies
  `desc:import-promise(2)` (Phase B's `LocalPromise` withdraw
  branch), and the resulting shortened path through the new pw
  RemotePromise races the in-flight forwards on the old path.
  Expected outcome: `EndToEndRefFIFO_MC` violation, dual to
  `MC_NaivePromiseResolution_2Party_PromiseShorten` but with three peers
  and an extra chain hop.

### 3.10 Phase C: 2-party flush extension; scope tightening

Extends `EJavaFlush` and `OpFlushProtocol` to inter-vat promise
shortening (2-party and resolver-initiated 3-party on co-terminal
topologies; see scope tightening below).

Spec delta in [`spec/Core.tla`](../spec/Core.tla):

- `firePromiseShorten` policy gate now includes `EJavaFlush`.
- `fireOpFlush` gate accepts promise-shaped resolutions when
  `AllListenersTwoParty` holds (the same condition that gates the
  2-party `desc:export-promise` / `desc:import-promise` emission).
- `SendTargetFlushProbe` uses `Route(self, res.refId)` rather than
  pattern-matching on `LocalRef(self, res.refId).kind`. The probe
  fires for both Target and Promise (2-party) resolutions and
  follows the cascade to the actual next-hop wire target; a `queue`
  or `hold` route disables the action and lets the chain advance
  first.
- `SendOpResolveAfterFlush` gate extended to
  `IsResolutionPromise(self, res) /\ AllListenersTwoParty(...)`,
  same condition as `fireOpFlush`.
- `sameConn` in `ReceiveNetwork`'s `op:resolve(target-wire-desc)`
  branch is restricted to `desc:import-target` (was: import-target
  + import-promise). For `desc:import-promise` / `desc:export-*`,
  the receiver always takes the slow embargo + probe path when
  `fresh = FALSE`. Rationale: in chains with `LocalPromise`
  intermediaries, the new direct path through a shortened
  intermediary can bypass that intermediary's queue while
  already-forwarded sends sit there waiting — the slow path's
  probe rides FIFO behind them and gates the new path's drainage.
- `ReceiveNetwork`'s `op:deliver-only` LocalPromise route branch
  accepts `route.tag = "hold"` (was: only `deliver | wire | queue`).
  This is reachable when the LocalPromise's resolution chains
  through to an embargoed `RemotePromise`; without this fix the
  receive action becomes disabled and the system deadlocks instead
  of holding the message until the embargo lifts.

Tests added:

- **[`models/MC_EJavaFlush_2Party_PromiseShorten.tla`](../models/MC_EJavaFlush_2Party_PromiseShorten.tla)**
  — `host = <<vatB, vatA, vatB>>` (terminal on vatB). vatA's
  chain advance emits `desc:export-target` (not `import-target`),
  which is never on the `sameConn` fast path, so vatB takes the
  slow embargo + probe path on its `RemotePromise`. Expected
  outcome: pass.
- **[`models/MC_OpFlushProtocol_2Party_PromiseShorten.tla`](../models/MC_OpFlushProtocol_2Party_PromiseShorten.tla)**
  — same topology, `OpFlushProtocol`. The resolver-initiated
  `op:flush` -> `op:flush-ack` -> `SendTargetFlushProbe` ->
  `SendOpResolveAfterFlush` handshake runs for the
  promise-shaped resolution. Expected outcome: pass.

Why naive 3-party widening exploded state (historical) and how it
was fixed:

- Naively widening `firePromiseShorten3Party` to flush policies at
  every middle hop blew up `MC_EJavaFlush_5Party` (>1.3M states).
- **Fix:** `ListenersWitnessPipelined` (`pipelinedListeners` on the
  resolver's `LocalPromise`, not a cross-peer `fresh` read) + head-hop
  (`r = 1`) + `CoTerminalPromiseHost` for **EJavaFlush** 3-party only
  (state-space + e-on-java pipelining rule). **OpFlushProtocol** uses
  `OpFlushResolverCoversPromise` (no pipelining witness; resolver always
  `op:flush` listeners for covered promises). Downstream hops use
  `RepropagatePromiseShorten` (`OpFlushCoversPromise`, no `r = 1`
  gate) when `EnableRepropagate = TRUE`.
- Additional single-node guards: `handoffPwBlocked` (EJavaFlush:
  defer `desc:import-promise` on `pw` while chain binder embargo is
  up), `chainOpFlushEmbargo` (OpFlush: keep listener embargo on chain
  ref through withdraw-promise resolve).

### 3.11 Phase D: re-propagation and Tribble MCs

- **`RepropagatePromiseShorten`** in [`spec/Core.tla`](../spec/Core.tla):
  when `self` installs `localResolution` on `recvR` and hosts a
  `LocalPromise` `chainR` with `resolution.refId = recvR` and
  `~repropNotified`, run the same local notify/flush predicates as
  `ResolverResolve` for the learned `res =
  LocalRef(self, recvR).localResolution`. Gated by
  `EnableRepropagate` (default `FALSE` on existing MCs).
- **`repropNotified`** on `LocalPromise` (see [`lib/References.tla`](../lib/References.tla))
  prevents notification loops.
- **Tribble MCs** (three-peer co-terminal chain +
  `EnableRepropagate = TRUE`):
  [`MC_EJavaFlush_TribbleFourWay`](../models/MC_EJavaFlush_TribbleFourWay.tla)
  — **violates** `EndToEndRefFIFO_MC` (expected: faithful
  `DelayedRedirector` limitation).
  [`MC_OpFlushProtocol_TribbleFourWay`](../models/MC_OpFlushProtocol_TribbleFourWay.tla)
  — **passes** `EndToEndRefFIFO_MC` with `NumMessages = 2` on the
  three-peer co-terminal topology (resolver `op:flush` to listeners
  is not gated on listener `fresh`; re-propagation via
  `OpFlushCoversPromise`).

## §4. Review follow-ups (autopilot pass)

### §4.1 `ListenersWitnessPipelined` is EJavaFlush-only

`firePromiseShorten3Party` in both `ResolverResolve` and
`RepropagatePromiseShorten` previously gated all three of
`NaivePromiseResolution`, `ShorteningUnsafe`, and `EJavaFlush` on
`ListenersWitnessPipelined`. The comment at the predicate
("EJavaFlush 3-party only") was correct; the code was over-restricting.

Under `NaivePromiseResolution` and `ShorteningUnsafe` the resolver has
no synchronization with listeners by design — the race surface is the
whole point. Requiring a pipelined-listener witness suppressed real
violations and made the policies appear safer than they are. The gate
is now `PolicyRequiresWitnessForShorten3Party => ListenersWitnessPipelined(...)`
(applied via disjunction). Naive/Shortening MCs still find their
expected `EndToEndRefFIFO` violations; under EJavaFlush the witness
gate is unchanged (listener-side embargo reachability still requires
the pipelined-listener witness).

### §4.2 Late 3-party `op:listen` is currently a silent gap

The `alreadyResolvedToTarget` arm of the `op:listen` receive in
`ReceiveNetwork` used to call `ResolveValueFor(self, res, from)`
unconditionally. When `NeedsHandoffIntro(self, from, capHost)` held
(third-party listener, target on a different vat), `ResolveValueFor`'s
`OTHER` arm silently fell through to `DescImportTarget(refId)`, putting
a wrong-shape `op:resolve` on the wire that the receiver would install
pointing at the resolver rather than the actual target.

Two-part fix:

- `ResolveValueFor`'s OTHER arm now `Assert(FALSE, ...)` so any missed
  caller fails loudly.
- `alreadyResolvedToTarget` is narrowed to exclude the needs-handoff
  case. Late 3-party listeners fall through to the OTHER arm of the
  `op:listen` receive: they are recorded in `listeners` but receive
  **no** `op:resolve`.

This trades the silent wrong-descriptor bug for a silent
no-notification gap. Implementing the full late-3-party path requires
allocating a fresh gift inside the listen-receive (mirroring the
`AppendResolveNotifications` handoff-give branch) and is deferred.
`MC_SubscribeAfterResolve_ThreeParty` locks in the current behaviour
under `WireDescriptorContract`.

### §4.3 `RepropagatePromiseShorten` deliberately re-notifies listeners

The autopilot brief proposed adding `~LocalRef(self, chainR).notified`
to the precondition (alongside the existing `~repropNotified` guard) to
prevent listeners from receiving a second `op:resolve`. **This would
break the shortening cascade**: the second `op:resolve` carries the
deeper target that the listener should install, replacing the
intermediate hop the first wave told it about. The two flags are
distinct by design — `notified` tracks the original chain
`ResolverResolve`, `repropNotified` tracks the re-propagation wave.

The genuine fragility (the second `op:resolve` overwriting `localResolution`
while EJavaFlush has staged a slow-path probe-ack against the first)
is left for a follow-up: it is masked in the Tribble MCs by the
current single-`op:resolve`-per-ref pattern but could surface under
broader topologies. Tracked as a future-work item.

### §4.4 Same-vat listener and self-loop FIFOs

`AppendToManyOutboxes` and the listener-set bindings in
`ResolverResolve`, `RepropagatePromiseShorten`, and
`SendOpResolveAfterFlush` now skip `q = self`. Previously a topology
with `host[r-1] = host[r] = self` (e.g. `host = <<vatA, vatA, _>>`)
under a flush policy would enqueue `op:flush` on `channels[self][self]`
in an inbox arm that requires `entry.kind = "RemotePromise"` — but the
self-receiver holds a LocalPromise (it is the resolver), so the
receive is disabled and the self-loop FIFO blocks every subsequent
message. `MC_EJavaFlush_2Party_SameVatListener` exercises the fix.

### §4.5 EJavaFlush 3-party promise-shortening does NOT preserve FIFO

`MC_EJavaFlush_3Party_PromiseShorten` previously declared
`NumMessages = 1` and passed — but a single delivery has no FIFO
surface to test, so the pass was vacuous. Bumping to `NumMessages = 2`
surfaces a real FIFO inversion (seq 2 delivered before seq 1) and the
MC is now declared `violation` to be honest about the gap.

The companion `MC_OpFlushProtocol_3Party_PromiseShorten` with
the same bump still passes — OpFlushProtocol's per-node flush handles
the 3-party shortening case that EJavaFlush's listener-side embargo
does not.

The EJavaFlush 3-party gap likely needs the same staged
flush-on-shorten that OpFlushProtocol applies. Fixing it is out of
scope for this review pass and is tracked as a follow-up.

### §4.7 Faithful Ridley op:flush — findings

The `OpFlushProtocol` policy was rewritten to faithfully implement
Ridley's draft (see `notes/flush-protocols.md` §9, transcribed
verbatim from ocapn#11 comments 4344960376 + 4442041860). The previous
implementation was a separate resolver-pushed design that used
`op:e-flush-probe` / `op:e-flush-probe-ack` for an end-to-end drain
proof — a mechanism Ridley's proposal does not have. Per user
direction, the new implementation adds no compensating mechanisms.
This section documents what the model actually shows under faithful
Ridley.

**Implementation summary.** `InitiateFlush` action fires shortener-side
when peer X holds a `RemotePromise` whose `localResolution.peer` is a
third party (not X, not the resolver-holder) and `~entry.flushSent`.
On `op:flush` receipt, the resolver-holder mints a fresh
`LocalPromise` `p'`, sets the old resolver's `resolution =
ResRef(self, p')` (the standard intra-vat promise cascade then
buffers future sends at `p'`), and replies with `op:resolve(resolveMe,
desc:import-promise(p'))`. No probe; no listener-side flush-ack
handshake. The drain proof rests on per-session FIFO and the
intra-vat queue cascade, exactly as Ridley §9 describes.

**MC outcomes.**

| MC | Before (resolver-pushed) | After (faithful Ridley) |
|---|---|---|
| `MC_OpFlushProtocol_2Party_PromiseShorten` | pass | **violation** |
| `MC_OpFlushProtocol_3Party_PromiseShorten` | pass | **violation** |
| `MC_OpFlushProtocol_4Party` (then `_4Chain`, 5 peers) | pass | **violation** |
| `MC_OpFlushProtocol_TribbleFourWay` | pass (safety only) | **violation** |
| `MC_OpFlushProtocol_2Party_SameVatListener` | pass | pass (same 35/57) |

The four "before → violation" transitions are the finding: **Ridley's
`op:flush` proposal AS SPECIFIED in the cited comments does NOT
preserve `EndToEndRefFIFO` in any of the chain-shaped topologies this
spec exercises.** The `SameVatListener` MC still passes only because
its topology has no shortening race (all references are local to one
vat).

**Counterexample shape (representative of all four violations).**
Shortest trace on `MC_OpFlushProtocol_2Party_PromiseShorten`,
topology `host = <<vatB, vatA, vatB>>`, `NumMessages = 2`. **Notably,
`InitiateFlush` never fires in this trace** — Ridley's flush
machinery is never invoked. The violation surfaces purely from the
immediate-install behavior of `fireOpResolveNow` that OpFlushProtocol
now shares with Naive/Shortening/EJavaFlush (the resolver still pushes
`op:resolve` to listeners eagerly):

1. `[s2]` vatA pipelines `seq=1` on `refs[1]` → `channels[vatA][vatB]`
   targeted at `refs[1]` (vatB's LocalPromise).
2. `[s3]` vatA's `ResolverResolve` fires for `refs[2]`: resolution =
   `ResRef(vatB, 3)` (Target on vatB). Listener is vatB; vatA emits
   `op:resolve(targetRefId=2, desc:export-target(refId=3))` on
   `channels[vatA][vatB]`.
3. `[s4]` vatA pipelines `seq=2` on `refs[1]` → `channels[vatA][vatB]`.
   At this point vatA's `refs[1]` is still a RemotePromise with no
   `localResolution`, so `seq=2` enters the wire targeted at vatB's
   `refs[1]` (not the new shortcut yet).
4. `[s5]` vatB's `ResolverResolve` fires for `refs[1]`: resolution =
   `ResRef(vatA, 2)` (Promise on vatA). vatB has no listeners on
   `refs[1]` so no `op:resolve` is emitted (`notified = FALSE`).
5. `[s6]` vatB receives `seq=1` on `refs[1]`. `refs[1]` is now a
   resolved `LocalPromise` (resolution → vatA's `refs[2]`); `Route`
   forwards `seq=1` via wire to vatA targeted at `refs[2]` on
   `channels[vatB][vatA]`.
6. **`[s7]` vatB receives `op:resolve(targetRefId=2, desc:export-target(3))`.**
   vatB's `refs[2]` is a RemotePromise; under faithful Ridley,
   the OpFlushProtocol policy's `PolicyInstallNowOnResolve` hook
   returns TRUE, so the op:resolve receive (`spec/Core.tla` around
   line 1257) takes the `installNow = TRUE` arm. vatB **immediately
   installs**
   `refs[2].localResolution = ResRef(vatB, 3)`. No embargo. No flush.
7. `[s8]` vatB receives `seq=2` on `refs[1]`. `Route(vatB, 1)`
   recurses through `refs[1].resolution` → `Route(vatB, 2)` →
   `refs[2].localResolution` → `Route(vatB, 3)`. `refs[3]` is a
   `LocalTarget` → `"deliver"` tag → `seq=2` appended to `delivered`
   directly. **seq=2 delivered.**
8. `[s9]` vatA receives `seq=1` on `refs[2]`. `refs[2]` is vatA's own
   resolved `LocalPromise`; `ProcessPending` forwards `seq=1` to vatB
   targeted at `refs[3]` on `channels[vatA][vatB]`.
9. `[s10]` vatB receives `seq=1` on `refs[3]`. LocalTarget → delivered.
   **seq=1 delivered second.** `delivered = [seq=2, seq=1]`.
   `EndToEndRefFIFO` violated.

**Root cause.** The race is between two routes for ref-1 sends at
vatB: the *old path* through `refs[1]` (vatB's LocalPromise) that
forwards back to vatA's `refs[2]` for cascade through to vatB's
`refs[3]`, and the *new path* through `refs[1].resolution`'s cascade
that recurses through `refs[2].localResolution` directly to
`refs[3]`. The new path is installed atomically at step 6 by an
incoming `op:resolve`, and step 7 (a `seq=2` send still in flight
from step 3) immediately takes it.

**`InitiateFlush` is irrelevant here.** Ridley's `op:flush` is a
shortener-initiated mechanism for a shortener to *acquire a fresh
resolver*, but the listener-side path-change install (step 6) happens
the moment the listener receives `op:resolve` — which it does whether
or not it ever planned to shorten. The protocol-level race is
already lost before any shortener-initiated machinery comes into
play. This is the same hazard `NaivePromiseResolution` exhibits;
faithful Ridley inherits it because:

- The current `fireOpResolveNow` includes `"OpFlushProtocol"` in its
  policy gate (`spec/Core.tla` around line 822), so the
  resolver still eagerly pushes `op:resolve` to listeners.
- Ridley's §9 does not specify whether the resolver pushes
  `op:resolve` eagerly or only on demand from a shortener-initiated
  flush. The §9 text describes the shortening 3PHO flow but is silent
  on the "ordinary listener learns about resolution" path. Our model
  assumed eager push (matching the other policies); a strict
  no-eager-push variant might preserve FIFO at the cost of listeners
  never learning a resolution unless they initiate a flush.

**Implications.** Ridley's published draft is sufficient for the
specific Alice→Bob→Carol scenario in §9 where Bob is the only sender
and the resolver never eagerly notifies anyone. It does NOT
generalize to a chain model with eager `op:resolve` propagation; the
listener-side immediate install reintroduces the Naive race. To make
faithful Ridley preserve FIFO, the spec would need to either:

- (a) Suppress eager `op:resolve` from the resolver under
  OpFlushProtocol — listeners learn about resolutions only via flush
  responses they themselves request. Listeners that never shorten
  never learn, and never route directly; ref-1 sends keep riding the
  chain forever.
- (b) Add a probe-like end-to-end signal or an embargo at the
  listener — but that is the "compensating mechanism" the user
  directed against, and it would no longer be faithful Ridley.

The user-visible takeaway: **the basic immediate-install hazard is
unaffected by Ridley's flush**, because the flush only governs the
shortener's path-change behaviour, not the listener's. The model
exposes this distinction clearly.

## References

- [Promise Shortening — ocapn#11](https://github.com/ocapn/ocapn/issues/11)
- [DelayedRedirector limitation (kpreid)](https://github.com/ocapn/ocapn/issues/11#issuecomment-4525913499)
- [op:flush proposal (Ridley)](https://github.com/ocapn/ocapn/issues/11#issuecomment-4344960376)
  with [addendum](https://github.com/ocapn/ocapn/issues/11#issuecomment-4442041860)
- [OCapN CapTP draft — Promise and Resolver Objects](https://github.com/ocapn/ocapn/blob/main/draft-specifications/CapTP%20Specification.md#promise-and-resolver-objects)
- [`notes/flush-protocols.md`](flush-protocols.md) — the wire-level
  protocol reference these definitions back.
