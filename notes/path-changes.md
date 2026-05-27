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
wire). The intermediate chain MCs (`MC_*_3Chain`, `MC_*_4Chain`)
exercise the same mechanism as a side effect: each non-terminal
`ResolverResolve` records a `resolution = ResRef(host[r+1], r+1)`
on the LocalPromise without firing any wire message.

#### 1.2.b Inter-vat (distributed) promise shortening — NOT modelled

The new promise is hosted by a *different* vat. To preserve FIFO,
listeners would need to learn about the new promise's host so they can
shorten their own dispatch through it. This would require:

1. A `desc:remote-promise(peer, refId)` value variant for `op:resolve`,
   alongside the import/export target descriptors and `desc:handoff-give`.
2. Each chain node propagating learned downstream resolutions to its
   own listeners (the `RemotePromise.localResolution` field is already
   threaded through the spec's `Route` recursion as the substrate for
   this, but no action ever writes a `localResolution` value that
   points to another `RemotePromise`).
3. A flush mechanism for the new race surface: the old path goes
   through the original resolver; the new path goes through the new
   promise's host; an in-flight send on the old path can race a new
   send on the new path even though neither lands at a terminal yet.

This is the cornerstone of the **Tribble four-way scenario** (see
§3.1 below) — without it, there is never more than one path change
in flight at a time and the four-way race shape cannot arise. It is
the largest single item of tracked future work in this repo.

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
| `ShorteningUnsafe` | Same as Naive (the name is OCapN-colloquial for "installs the new path without a flush", not literally about §1.2 promise shortening). | Same hazard, demonstrated on longer chains. | Violates `EndToEndRefFIFO` on a 4-chain. |
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
four-way race shape doesn't arise). The work order is therefore:

1. Add a `desc:remote-promise` value variant to `op:resolve`.
2. Add an action that propagates a `RemotePromise.localResolution` to
   the holder's own listeners (a kind of `ResolverResolve` for
   subscribed `RemotePromise`s rather than locally-hosted
   `LocalPromise`s).
3. Add `MC_EJavaFlush_TribbleFourWay.tla` asserting
   `EndToEndRefFIFO_MC` and expected to **violate** (witness the
   kpreid race).
4. Add `MC_OpFlushProtocol_TribbleFourWay.tla` and extend
   `OpFlushProtocol` to the four-party form; expected to **pass** if
   the Ridley proposal's claim holds.

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

`spec/PromiseResolution.tla` defines two global invariants over
`channels`: `WireDescriptorContract` (no `desc:handoff-give` with
`targetHost \in {sender, receiver}`) and `TwoPartyWireDescsOnly` (every
non-handoff `op:resolve` descriptor is in `TargetWireDescs`). They are
currently checked only by the static-state `Unit_WireDesc_DescriptorChoice`
unit (`Spec == Init /\ [][Stutter]_vars`, 1 distinct state). Every
dynamic MC with `EnableHandoff = TRUE` should add both invariants to its
`.cfg`. Per-state cost is O(|Peers|² × FIFO depth) — a few percent at
most — and state counts are unchanged.

Affected configs: `MC_EJavaFlush_3Chain.cfg`, `MC_EJavaFlush_4Chain.cfg`,
`MC_OpFlushProtocol_4Chain.cfg`, `MC_ShorteningUnsafe_4Chain.cfg`,
`MC_TerminalHandoff_Baseline.cfg`, `MC_TerminalHandoff_WithForwarder.cfg`,
`MC_ConcurrentHandoffs.cfg`, and the four `Unit_Handoff_*.cfg` units.

### 3.6 EJavaFlush debug invariant `NoSlowPathCompletion_MC` no longer scopes the slow path

`MC_EJavaFlush_3Chain.tla` and `MC_EJavaFlush_4Chain.tla` define a debug
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
model files. (`MC_OpFlushProtocol_4Chain.tla`'s predicate is not
affected: it requires `flushPhase = "acked"`, which only the
resolver-side slow-path actions set, so handoff withdraw-promises
cannot satisfy it.)

### 3.7 Focused unit coverage for the chain-form `handoff-give` slow path

The chain MCs incidentally cover the `desc:handoff-give` chain-form
`chainEmbargo` branch in `ReceiveNetwork` (an `embargo=TRUE` invariant
violation is reachable in `MC_EJavaFlush_3Chain` within ~180 distinct
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

## References

- [Promise Shortening — ocapn#11](https://github.com/ocapn/ocapn/issues/11)
- [DelayedRedirector limitation (kpreid)](https://github.com/ocapn/ocapn/issues/11#issuecomment-4525913499)
- [op:flush proposal (Ridley)](https://github.com/ocapn/ocapn/issues/11#issuecomment-4344960376)
  with [addendum](https://github.com/ocapn/ocapn/issues/11#issuecomment-4442041860)
- [OCapN CapTP draft — Promise and Resolver Objects](https://github.com/ocapn/ocapn/blob/main/draft-specifications/CapTP%20Specification.md#promise-and-resolver-objects)
- [`notes/flush-protocols.md`](flush-protocols.md) — the wire-level
  protocol reference these definitions back.
