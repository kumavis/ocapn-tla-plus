# Plan: Invert the EXTENDS chain — event-based per-policy modules

## Context

The current refactor (`752a2eb`) put `PromiseResolution.tla` at the
*bottom* of the EXTENDS DAG: policy modules under `protocols/` are
shared-helper layers that `PromiseResolution` pulls in. The big action
bodies (`ReceiveNetwork`, `ResolverResolve`, `Next`, ...) still live in
`PromiseResolution` with `RoutingPolicy = "..."` guards woven through
them.

This satisfied "code lives in its own file" but did NOT achieve the
goal of "adding a new policy = create one new file." Doing that
requires inverting the EXTENDS chain so each policy module sits at the
*tip* of the DAG, and MCs INSTANCE the policy module rather than a
shared `PromiseResolution`.

The user proposed an **event-based approach** to keep the seams clean.
This document plans that.

## The Seam: protocol events

The current monolithic actions break into a small set of named events.
Each event has a well-defined shape (signature + return type), and
each policy provides a handler. The core declares the events as
CONSTANT operators; each policy module INSTANCEs the core with its
handlers substituted.

### Events identified

From the current `PromiseResolution.tla`, the policy-conditional code
falls into these buckets (operators per event):

1. **`OnResolveReceive(self, from, msg, ch0)`** — the op:resolve
   receive branch. Returns a post-state record
   `[channels, vats, nextRefId, accepted]`. Today this contains
   `installNow`, `embargoInstead`, `fastPath`, `handoffPwBlocked`
   logic, all gated on `RoutingPolicy`.

2. **`OnResolverResolveNotify(self, r, res, listeners)`** — what
   `ResolverResolve` does at the resolver-side notify step. Today's
   `fireOpResolveNow` / `firePromiseShorten` / `firePromiseShorten3Party`
   logic. Returns the post-state.

3. **`OnHandoffGiveReceive(self, from, msg, ...)`** — chain-form
   handoff-give receive. EJavaFlush's `chainEmbargo` + `chainProbe`
   logic lives here. Returns post-state.

4. **`PolicyExtraReceiveBranches(self, from, msg, ch0)`** — disjunction
   of receive branches that only this policy emits. EJavaFlush:
   `op:e-flush-probe`, `op:e-flush-probe-ack`. OpFlushProtocol:
   `op:flush`. Returns disabled if `msg.op` is not one of this
   policy's ops.

5. **`PolicyExtraActions`** — disjunction of top-level actions only
   this policy fires. EJavaFlush: `ProcessHold`. OpFlushProtocol:
   `InitiateFlush`. Returns disabled if precondition not met. Each
   policy's `Next` includes its own `PolicyExtraActions` via
   `\/`-composition.

6. **`PolicyRouteHold(self, r)`** — predicate the core's `Route` consults
   when classifying a `RemotePromise` route. EJavaFlush returns
   `entry.embargo # {} \/ Len(entry.pending) > 0`; other policies
   return FALSE.

7. **`PolicyFairness`** — fairness conjunct for policy-specific actions.

### TLA+ mechanism: parametric core + INSTANCE WITH

```tla
\* spec/Core.tla
EXTENDS Naturals, Sequences, TLC, References, Network, PeerState

\* CONSTANTs for the policy hooks.  Each is an operator-shaped
\* CONSTANT declaration -- the higher-order parameter pattern.
CONSTANT
    _OnResolveReceive(_, _, _, _),
    _OnResolverResolveNotify(_, _, _, _),
    _OnHandoffGiveReceive(_, _, _, _),
    _PolicyExtraReceiveBranches(_, _, _, _),
    _PolicyExtraActions,        \* a Boolean / action predicate
    _PolicyRouteHold(_, _),
    _PolicyFairness

CONSTANT
    NumMessages, RoutingPolicy, DebugTrace,
    EmptyInitialListeners, EnableDynamicListen,
    EnableHandoff, EnableHandoffInitiate,
    EnableRepropagate, EnableShorten

VARIABLES channels, host, vats, sent, delivered, nextRefId, lastAction

\* Core defines the common actions in terms of the hooks:
PeerSend == ...  \* unchanged
ProcessPending == ...  \* unchanged
Listen == ...  \* unchanged
HandoffInitiate == ...  \* unchanged

\* The receive dispatcher consults the hooks:
ReceiveNetwork ==
    \E self, from \in Peers :
    /\ InboxNonEmpty(self, from)
    /\ LET msg == InboxHead(self, from)
           ch0 == ... \* dequeue
       IN \/ ReceiveOpDeliverOnly(self, from, msg, ch0)
          \/ ReceiveOpResolveCore(self, from, msg, ch0)  \* uses _OnResolveReceive
          \/ ReceiveOpListen(self, from, msg, ch0)
          \/ ReceiveDepositGift(self, from, msg, ch0)
          \/ ReceiveWithdrawGift(self, from, msg, ch0)  \* uses _OnHandoffGiveReceive
          \/ _PolicyExtraReceiveBranches(self, from, msg, ch0)

\* ResolverResolve uses the notify hook:
ResolverResolve == ...
    /\ _OnResolverResolveNotify(self, r, res, listeners) ...

\* Route uses the hold-predicate hook:
Route(self, r) == ...
    IF _PolicyRouteHold(self, r) THEN "hold" ELSE ...

\* Next pulls in policy extras:
Next ==
    \/ PeerSend
    \/ ResolverResolve
    \/ ReceiveNetwork
    \/ ProcessPending
    \/ Listen
    \/ HandoffInitiate
    \/ _PolicyExtraActions

Fairness ==
    /\ WF_vars(PeerSend) /\ WF_vars(ResolverResolve)
    /\ WF_vars(ReceiveNetwork) /\ WF_vars(ProcessPending)
    /\ WF_vars(Listen) /\ WF_vars(HandoffInitiate)
    /\ _PolicyFairness

Spec == Init /\ [][Next]_vars /\ Fairness

\* Common invariants
TypeOK == ...
EndToEndRefFIFO == ...
\* etc.
```

```tla
\* spec/protocols/EJavaFlush.tla
EXTENDS Naturals, Sequences, TLC, References, Network, PeerState

VARIABLES channels, host, vats, sent, delivered, nextRefId, lastAction
CONSTANT NumMessages, DebugTrace, ... (same as Core)
\* RoutingPolicy not needed -- this module IS the policy.

\* Wire ops:
OpEFlushProbe(...) == ...
OpEFlushProbeAck(...) == ...

\* Hooks:
EJF_OnResolveReceive(self, from, msg, ch0) ==
    \* Includes installNow / embargoInstead / fastPath / etc.
    \* The full op:resolve receive logic for EJavaFlush.
    ...

EJF_OnResolverResolveNotify(self, r, res, listeners) ==
    \* fireOpResolveNow + firePromiseShorten + firePromiseShorten3Party
    \* with EJavaFlush gating (ListenersWitnessPipelined etc.)
    ...

EJF_OnHandoffGiveReceive(self, from, msg, ch0) ==
    \* chainEmbargo + chainProbe slow path
    ...

EJF_PolicyExtraReceiveBranches(self, from, msg, ch0) ==
    \/ ReceiveEFlushProbe(self, from, msg, ch0)
    \/ ReceiveEFlushProbeAck(self, from, msg, ch0)

ProcessHold == ...  \* EJavaFlush-specific action

EJF_PolicyExtraActions ==
    \/ ProcessHold

EJF_PolicyRouteHold(self, r) ==
    LocalRef(self, r).kind = "RemotePromise" /\
    (LocalRef(self, r).embargo # {} \/ Len(LocalRef(self, r).pending) > 0)

EJF_PolicyFairness == WF_vars(ProcessHold)

\* Instantiate the core with our hooks:
C == INSTANCE Core WITH
    _OnResolveReceive             <- EJF_OnResolveReceive,
    _OnResolverResolveNotify      <- EJF_OnResolverResolveNotify,
    _OnHandoffGiveReceive         <- EJF_OnHandoffGiveReceive,
    _PolicyExtraReceiveBranches   <- EJF_PolicyExtraReceiveBranches,
    _PolicyExtraActions           <- EJF_PolicyExtraActions,
    _PolicyRouteHold              <- EJF_PolicyRouteHold,
    _PolicyFairness               <- EJF_PolicyFairness

\* Re-export what the MCs need:
Init     == C!Init
Next     == C!Next
Fairness == C!Fairness
Spec     == C!Spec
TypeOK   == C!TypeOK
EndToEndRefFIFO == C!EndToEndRefFIFO
\* ... etc.
```

```tla
\* spec/protocols/OpFlushProtocol.tla -- same pattern with OpFlush hooks.
```

```tla
\* spec/protocols/NaivePromiseResolution.tla -- minimal hooks:
NPR_OnResolveReceive == ...  \* just install immediately
NPR_OnResolverResolveNotify == ...  \* immediate notify
NPR_OnHandoffGiveReceive == ...  \* no embargo, no probe
NPR_PolicyExtraReceiveBranches == FALSE  \* no extra ops
NPR_PolicyExtraActions == FALSE  \* no extra actions
NPR_PolicyRouteHold == FALSE  \* no hold
NPR_PolicyFairness == TRUE
```

And `NoPromiseResolution` and `ShorteningUnsafe` similarly trivial.

### MC update

```tla
\* models/MC_EJavaFlush_3Chain.tla (before):
PS == INSTANCE PromiseResolution

\* (after):
PS == INSTANCE protocols/EJavaFlush
```

The `RoutingPolicy` constant goes away — the choice of policy is now
encoded in which module the MC INSTANCEs.

## What we gain

1. **Adding a new policy = one new file** under `protocols/`. No
   touches to Core or other policy modules. Concretely: add
   `protocols/MyNewFlush.tla`, define the seven hooks, INSTANCE Core,
   re-export. Done.
2. **Reading a policy = reading one file**. All EJavaFlush-specific
   logic (wire ops, receive branches, slow-path logic, fairness) lives
   in `protocols/EJavaFlush.tla`. No need to grep `EJavaFlush` across
   the codebase.
3. **No more `RoutingPolicy = "..."` guards** scattered through the
   core. The dispatcher knows which policy is active because it IS
   the policy module. Cleaner reads at every action site.
4. **TLA+ idiomatic.** Higher-order CONSTANT operators + `INSTANCE
   WITH` is the standard way to parameterize a TLA+ module.

## What we lose / accept

1. **Core action bodies become more abstract.** Each big action calls
   into a hook for the policy-specific bits. Readers tracing the spec
   need to look up which hook the active policy provides. Mitigation:
   crisp naming + clear hook signatures + one short comment per hook
   in Core explaining what the hook is supposed to compute.
2. **One `Core.tla` + N policy modules** means N modules each
   re-export Init / Next / Spec / Fairness / TypeOK / invariants.
   Boilerplate, but mechanical. Could be reduced via a helper module
   or just lived with.
3. **`RoutingPolicy` constant goes away in MCs**. Existing MCs all
   declare `RoutingPolicy == "<policy>"` as a constant. The migration
   needs to update every MC file (~36 of them) to swap `INSTANCE
   PromiseResolution` for `INSTANCE protocols/<policy>` and drop the
   `RoutingPolicy` declaration. Mechanical.
4. **Stale `RoutingPolicy = "..."` guards** within `Core.tla` would
   become dead code that needs cleanup. Some of the existing guards
   in `ResolverResolve` etc. compare to multiple policy strings
   (`{"NaivePromiseResolution", "ShorteningUnsafe", "EJavaFlush"}`);
   those need to be replaced with explicit hook composition (e.g. a
   `_PolicyIsPushImmediately` predicate the policy provides).
5. **Tests / debug invariants per MC** stay where they are; the MC
   instantiates the policy module instead of `PromiseResolution`.

## What stays the same

- `lib/{References,Network,PeerState}.tla` — unchanged.
- `protocols/Common.tla` — folded into `spec/Core.tla` (no need for
  a separate Common file once Core is the central spec).
- All test outcomes — pure structural refactor; state spaces
  identical to the post-`a7d1c4f` baseline.
- All wire-op constructors that are shared (`OpDeliverOnly`,
  `OpResolve`, `OpListen`, `OpDepositGift`, `OpWithdrawGift`,
  `DescImport*` / `DescExport*` / `DescHandoffGive`) stay in
  `Core.tla`.
- All invariants (`TypeOK`, `EndToEndRefFIFO`, `EventualDelivery`,
  `WireDescriptorContract`, etc.) stay in `Core.tla`.

## Step-by-step migration

1. **Stage 0 — name the events.** Sketch the seven hook signatures in
   `spec/Core.tla` (no implementation yet, just CONSTANT operator
   declarations). Smoke: parse-only check (TLC will complain about
   unsubstituted operators; that's expected at this stage).

2. **Stage 1 — Naive scaffold.** Extract `NaivePromiseResolution`'s
   hook implementations from the current `PromiseResolution.tla`
   into `spec/protocols/NaivePromiseResolution.tla`. Wire it via
   `INSTANCE Core WITH ...`. Update one MC
   (`MC_NaivePromiseResolution.tla`) to `INSTANCE protocols/Naive...`.
   Smoke: that MC's state count matches baseline (3 distinct / 6
   generated, or wherever it lands today).

3. **Stage 2 — port NoPromise + Shortening.** Same shape; trivial
   hook impls. Update both MCs.

4. **Stage 3 — port EJavaFlush.** This is the big one. Lift
   `installNow` / `embargoInstead` / `fastPath` / `handoffPwBlocked`
   logic + the probe receive branches into `protocols/EJavaFlush.tla`.
   Update the 5-ish EJavaFlush MCs. Smoke: each matches baseline state
   count (`MC_EJavaFlush_3Chain`: 1249/3532).

5. **Stage 4 — port OpFlushProtocol.** Lift the InitiateFlush action
   + the op:flush receive branch + the immediate-install logic into
   `protocols/OpFlushProtocol.tla`. Update the 5 OpFlush MCs. Smoke:
   matches baseline (the new violations under faithful Ridley should
   persist).

6. **Stage 5 — delete `spec/PromiseResolution.tla`.** All MCs now
   INSTANCE policy modules. The old central spec is dead. Move the
   common helpers (`Route`, `ApplyRoute`, `AppendResolveNotifications`,
   etc.) to `spec/Core.tla` if not already there.

7. **Stage 6 — folder layout.** Decide whether the policy modules
   live at `protocols/` (top-level, current) or `spec/protocols/`
   (inside spec). The user prefers `protocols/` (already chosen).

## Risks

- **TLA+ higher-order CONSTANT operators** are sometimes finicky in
  TLC. The substitution may need careful ordering. Mitigation: smoke
  early (after stage 1); if TLC chokes, fall back to manual
  composition (each policy module copies the relevant action bodies
  rather than INSTANCEing a parameterized Core).
- **`ReceiveOpResolveCore`** is the biggest action. Lifting its body
  into a hook with the right signature is the trickiest part of the
  refactor; it touches `vats`, `channels`, `nextRefId`. The hook
  needs to return all three.
- **Diamond inheritance via `Common.tla`** in the current refactor
  works because EXTENDS pulls each module exactly once. The proposed
  INSTANCE pattern is different — each policy module is its own root
  of an EXTENDS DAG and there's no shared ancestor for MCs. This is
  cleaner but loses the implicit sharing; common helpers must live
  in `Core.tla` explicitly.

## Estimate

- Stages 0–2 (Naive + NoPromise + Shortening): ~1–2 hours; mostly
  mechanical.
- Stage 3 (EJavaFlush): ~2–3 hours; the slow-path receive logic is
  intricate.
- Stage 4 (OpFlushProtocol): ~1 hour.
- Stage 5–6 (cleanup): ~1 hour.

Total: ~5–7 hours of focused work. Pure refactor; no semantic
changes (faithful Ridley findings stay as violations).
