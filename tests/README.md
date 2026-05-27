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
| `Unit_Listen_Subscribe_Unresolved` | 1 vat hosts p_1, T (NaivePromise) | `op:listen` arrives before resolution; listener installed; eventual `op:resolve` fires |
| `Unit_Listen_Subscribe_AfterResolve` | 1 vat hosts p_1, T (NaivePromise) | `op:listen` arrives after resolution; immediate `op:resolve` reply |

Both use `EmptyInitialListeners = TRUE` + `EnableDynamicListen = TRUE`
so the only listener registration is via the `Listen` action.

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
| `Unit_WireDesc_DescriptorChoice`  | 3 peers, statically pre-staged channels   | Sanity check that `desc:import-target` / `desc:export-target` / `desc:handoff-give` are emitted only in the situations the wire contract allows (`WireDescriptorContract`, `TwoPartyWireDescsOnly` and the `*Classified_MC` shape predicates hold on the initial state) |

## Running

```
TLA_JAR=$HOME/tla/tla2tools.jar ./scripts/run-tests.sh
```

`run-tests.sh` includes the `tests/` directory in its classpath and
test list.
