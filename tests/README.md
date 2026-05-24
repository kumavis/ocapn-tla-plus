# Unit tests

Small, focused TLA+ models that exercise specific pieces of the
`PromiseResolution` spec.  Each unit-test MC pins `host` so a precise
dispatch path is taken, then proves the corresponding invariants hold.

Unit tests intentionally use small `NumMessages` (2) and short chains
to keep state spaces tiny.

## Phase 1: ref-taxonomy + dispatch

| MC                              | Pinned topology              | What it exercises                               |
|---------------------------------|------------------------------|-------------------------------------------------|
| `Unit_LocalTarget_Direct`       | 1 vat, T at HeadPeer         | LocalPromise.queue + ProcessPending + LocalTarget deliver |
| `Unit_LocalShorten_Cascade`     | 3 chain, p_1+p_2 at HeadPeer | LocalPromise -> LocalPromise local-shortening (queue spill) |
| `Unit_RemoteTarget_Forward`     | 2 chain, T at vatB           | RemoteTarget routing via wire                   |
| `Unit_Pipelining_On_Promise`    | 2 chain, p_1 at vatB, T at vatA | RemotePromise pipelined sends; LocalPromise queue+drain |

All four are run with `NoPromiseResolution` so the listener set is
empty and no `op:resolve` ever fires; we test only the dispatch and
queue/drain mechanics, not the resolution-propagation policies (which
are exercised by the policy MCs in `models/`).

## Phase 2: dynamic listener registration

| MC                                 | Topology                          | What it exercises                                 |
|------------------------------------|-----------------------------------|---------------------------------------------------|
| `Unit_Listen_Subscribe_Unresolved` | 1 vat hosts p_1, T (NaivePromise) | `op:listen` arrives before resolution; listener installed; eventual `op:resolve` fires |
| `Unit_Listen_Subscribe_AfterResolve` | 1 vat hosts p_1, T (NaivePromise) | `op:listen` arrives after resolution; immediate `op:resolve` reply |

Both use `EmptyInitialListeners = TRUE` + `EnableDynamicListen = TRUE`
so the only listener registration is via the `Listen` action.

## Phase 3: opaque three-party handoff (3PHO)

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

| MC                                   | Topology                                          | What it exercises                                                  |
|--------------------------------------|---------------------------------------------------|--------------------------------------------------------------------|
| `Unit_EJavaFlush_RefScopedEmbargo`   | vatA holds `RemotePromise(1)->vatB` and `RemoteTarget(2)->vatC`; pre-staged forward via ref 2 sits on `channels[vatA][vatC]`; `op:resolve(1, _)` in flight on `channels[vatB][vatA]` | `RefHasPipelinedForwards` examines only the wire used by the ref under resolution, so unrelated pre-resolve traffic on a different ref/wire does NOT trigger a spurious embargo |

## Running

```
TLA_JAR=$HOME/tla/tla2tools.jar ./scripts/run-tests.sh
```

`run-tests.sh` includes the `tests/` directory in its classpath and
test list.
