# Unit tests

Small, focused TLA+ models that exercise specific pieces of the
`PromiseResolution` spec.  Each unit-test MC pins `host` so a precise
dispatch path is taken, then proves the corresponding invariants hold.

Unit tests intentionally use small `NumMessages` (2) and short chains
to keep state spaces tiny.

## Ref taxonomy + dispatch

| MC                              | Pinned topology              | What it exercises                               |
|---------------------------------|------------------------------|-------------------------------------------------|
| `Unit_LocalTarget_Direct`       | 1 vat, T at HeadPeer         | LocalPromise.queue + ProcessPending + LocalTarget deliver |
| `Unit_LocalShorten_Cascade`     | 3 chain, p_1+p_2 at HeadPeer | intra-vat promise shortening: LocalPromise -> LocalPromise queue cascade (no wire traffic) -- see ../notes/path-changes.md §1.2.a |
| `Unit_RemoteTarget_Forward`     | 2 chain, T at vatB           | RemoteTarget routing via wire                   |
| `Unit_Pipelining_On_Promise`    | 2 chain, p_1 at vatB, T at vatA | RemotePromise pipelined sends; LocalPromise queue+drain |

All four are run with `NoPromiseResolution` so the listener set is
empty and no `op:resolve` ever fires; we test only the dispatch and
queue/drain mechanics, not the resolution-propagation policies (which
are exercised by the policy MCs in `models/`).

## Dynamic listener registration (op:listen)

| MC                                 | Topology                          | What it exercises                                 |
|------------------------------------|-----------------------------------|---------------------------------------------------|
| `Unit_Listen_Subscribe_Unresolved` | 1 vat hosts p_1, T (NaivePromise) | `op:listen` exhaustively explored both before and after resolution; covers eventual / immediate `op:resolve` reply.  After-resolve case is also exercised by `MC_SubscribeAfterResolve`. |

Uses `EmptyInitialListeners = TRUE` + `EnableDynamicListen = TRUE` so
the only listener registration is via the `Listen` action.

## Opaque three-party handoff (3PHO)

| MC                                  | Topology                                     | What it exercises                                       |
|-------------------------------------|----------------------------------------------|---------------------------------------------------------|
| `Unit_Handoff_DepositWithdraw`      | gifter / recipient / targetHost (3 peers)    | minimal 3PHO round-trip; `pw` minted at recipient and resolved at targetHost; gift slot cleared |
| `Unit_Handoff_Pipeline`             | recipient holds `RemotePromise(targetHost, pw)` directly (post-resolve pre-state) | pipelined `op:deliver-only` on `pw` queue at targetHost's pre-minted `LocalPromise(pw)` and drain to `LocalTarget` after `op:withdraw-gift` resolves it |
| `Unit_Handoff_Pipeline_BeforeDeposit` | pipelined `op:deliver-only(pw)` reaches targetHost on `vatB->vatC` **before** `op:deposit-gift` on `vatA->vatC` (different wires) | targetHost's receive is disabled at the wire head until the deposit pre-mints `LocalPromise(pw)`; then the message enqueues at the promise (never an ad-hoc buffer) and drains to the target |
| `Unit_Handoff_RejectWrongRecipient` | adversarial pre-state with wrong-recipient `op:withdraw-gift` in flight | `ReceiveOpWithdrawGift` silently rejects non-named recipient; named recipient's later withdraw succeeds; `GiftHasOneRecipient` and `GiftOneShot` hold |

All three are run with `NoPromiseResolution` so no chain `op:resolve`
fires; we test only the 3PHO state machine and its interaction with
pipelined sends through `pw`.

## EJavaFlush gate precision

All three units below are 3-party scenarios introduced via
`desc:handoff-give` (the only descriptor shape the wire contract allows
for a third-party introduction).  They pin the chain-form
`chainEmbargo` arm of the `desc:handoff-give` receive in
`ReceiveNetwork`; see `notes/path-changes.md` §3.7.

| MC                                   | Topology                                          | What it exercises                                                  |
|--------------------------------------|---------------------------------------------------|--------------------------------------------------------------------|
| `Unit_EJavaFlush_RefScopedEmbargo`   | vatA holds `RemotePromise(1)->vatB` and `RemoteTarget(2)->vatC`; unrelated forward via ref 2 sits on `channels[vatA][vatC]`; `op:resolve(1, desc:handoff-give(vatB, vatC, _, 3))` in flight on `channels[vatB][vatA]` | EJavaFlush's per-ref `fresh` sticky bit is scoped to the specific RemotePromise under resolution: unrelated traffic on `vatA.refs[2]` does NOT clear `vatA.refs[1].fresh`, so `chainFresh = TRUE` and no spurious embargo lands on `vatA.refs[1]` (the fast path fires) |
| `Unit_EJavaFlush_EmbargoFires`       | 3 chain T@vatA <- vatC <- vatB; `vatC` resolves `p2` to `T@vatA` and emits `desc:handoff-give` to listener `vatB`; `vatB` has already pipelined a forward to its resolver (`vatB.refs[2].fresh = FALSE`) | Positive witness: the chain-form receive consults `vatB.refs[2].fresh`, computes `chainEmbargo = TRUE`, and sets `vatB.refs[2].embargo := TRUE`.  Expected outcome: violation (`EmbargoNeverFires_MC` is the negation of the witness) |
| `Unit_EJavaFlush_HandoffChainProbe`  | identical pre-state to `EmbargoFires` | Joint witness for the same slow path: asserts the negation of `(vats[vatB].refs[2].embargo = TRUE) /\ (op:e-flush-probe(originPeer=vatB, originRefId=2, refId=2)` in `channels[vatB][vatC])`, so the violation trace pins both effects in the SAME `ReceiveNetwork` step.  Catches asymmetric regressions (probe-without-embargo or embargo-without-probe) that `EmbargoFires` alone would miss.  Expected outcome: violation |

## Wire descriptor contract

| MC                                | Topology                                  | What it exercises                                                         |
|-----------------------------------|-------------------------------------------|---------------------------------------------------------------------------|
| `Unit_WireDesc_DescriptorChoice`  | 3 peers, statically pre-staged channels   | Sanity check that `desc:import-target` / `desc:export-target` / `desc:handoff-give` are emitted only in the situations the wire contract allows (`WireDescriptorContract`, `OnlyKnownResolveDescriptors` and the `*Classified_MC` shape predicates hold on the initial state) |

## Inter-vat promise shortening

| MC                                | Topology                                                                  | What it exercises                                                                                                                                                                                                                                                                                                                                  |
|-----------------------------------|---------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `Unit_PromiseShorten_TwoParty`    | 2 peers, ChainLength 3, `host = <<vatB, vatA, vatA>>` (Naive)             | Positive witness for Phase A's two-party promise emission (see `notes/path-changes.md` §1.2.b and §3.8): `vatB.ResolverResolve` at `r=1` MUST append `op:resolve(targetRefId=1, desc:export-promise(refId=2))` to `channels[vatB][vatA]` because `vatA` is both the sole listener AND the new promise's host. Expected outcome: violation (negation invariant) |
| `Unit_PromiseShorten_ThreeParty`  | 3 peers, ChainLength 3, `host = <<vatB, vatC, vatC>>`, HeadPeer = vatA (Naive) | Positive witness for Phase B's three-party promise-cap handoff (see `notes/path-changes.md` §1.2.b and §3.9): `vatB.ResolverResolve` at `r=1` MUST append `op:resolve(targetRefId=1, desc:handoff-give(_, vatC, _, _))` to `channels[vatB][vatA]`, where the gifted target is the `LocalPromise(2)` on vatC. The withdraw reply that completes the handoff later carries `desc:import-promise(2)` (Phase B's promise-cap withdraw branch). Expected outcome: violation (negation invariant `NoChainHandoffGiveForPromise_MC`) |

The race surfaces these unlock are exercised at policy level by:

- [`MC_NaivePromiseResolution_PromiseShorten`](../models/MC_NaivePromiseResolution_PromiseShorten.tla)
  (Phase A 2-party form, dual to `MC_NaivePromiseResolution` for the
  Target case).
- [`MC_NaivePromiseResolution_3Chain`](../models/MC_NaivePromiseResolution_3Chain.tla)
  (Phase B 3-party form; same race surface across three peers).
- [`MC_EJavaFlush_3Chain_PromiseShorten`](../models/MC_EJavaFlush_3Chain_PromiseShorten.tla)
  and [`MC_OpFlushProtocol_3Chain_PromiseShorten`](../models/MC_OpFlushProtocol_3Chain_PromiseShorten.tla)
  (Phase C 2-party flush extension; expected pass).
- [`MC_EJavaFlush_3Chain_PromiseShorten_3Party`](../models/MC_EJavaFlush_3Chain_PromiseShorten_3Party.tla)
  and [`MC_OpFlushProtocol_3Chain_PromiseShorten_3Party`](../models/MC_OpFlushProtocol_3Chain_PromiseShorten_3Party.tla)
  (Phase C 3-party; `NumMessages = 1`; expected pass).
- [`MC_EJavaFlush_TribbleFourWay`](../models/MC_EJavaFlush_TribbleFourWay.tla)
  (Phase D; expected `EndToEndRefFIFO_MC` violation).
- [`MC_OpFlushProtocol_TribbleFourWay`](../models/MC_OpFlushProtocol_TribbleFourWay.tla)
  (Phase D; expected `EndToEndRefFIFO_MC` pass with `NumMessages = 2`).

## Running

```
TLA_JAR=$HOME/tla/tla2tools.jar ./scripts/run-tests.sh
```

`run-tests.sh` includes the `tests/` directory in its classpath and
test list.
