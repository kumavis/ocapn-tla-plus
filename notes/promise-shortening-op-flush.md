# Promise shortening, `op:flush`, and E-style sender flush (model notes)

This repo's [`spec/PromiseResolution.tla`](../spec/PromiseResolution.tla)
adds four **routing policies** on top of the original Naive / NoPromise
pair.

**Design rule:** no protocol is allowed to inspect state that a real
implementation could not observe locally. A policy that needs to know
about messages on `channels[X][Y]` for `X` or `Y` it doesn't own, or
about `pending[Z][k]` at a vat `Z` that has not sent it a callback, is
god-view and not realistic.

| `RoutingPolicy`        | Observable signal | Expected `EndToEndRefFIFO` |
|------------------------|-------------------|----------------------------|
| `ShorteningUnsafe`     | None — `Shorten` flips `shortenActive` immediately and the head shortens even while pipelined traffic is still in flight. | **Violated** |
| `EJavaFlush` (canonical) | LOCAL: head's immediate next hop `host[1]` reports its ref-1 queue (`pending[host[1]][1]`) has drained. Models [`DelayedRedirector`](https://github.com/kpreid/e-on-java/blob/a0b3b599cf267b3138eea5f5fb83f27cebd28373/src/jsrc/org/erights/e/elib/ref/DelayedRedirector.java). | **Violated** when `shortenEntry > 2` (kpreid concern materializes; see trace). |
| `EJavaFlushGlobal`     | UNREALISTIC god-view (`OldPathClear` AND `NoInFlightOldPath` AND `NoInFlightRef1`). Kept *only* as a minimal contrast — shows the assumption the local design is missing. **Do not implement this.** | Holds. |
| `OpFlushProtocol`      | LOCAL: head sends `op:flush-fwd` hop-by-hop along the original chain through `host[shortenEntry]` itself; each non-terminal hop's precondition is its own `pending[host[h]][h] = 0`; the entry vat `host[shortenEntry]` sends `op:flush-ack` back to the head. Head needs no other check at receipt. | Holds. |

**Wire records added:** `OpFlushFwd(target, hop)`, `OpFlushAck`.

**`ShortenPre(k)`** requires, for the chosen entry `k`, that promise `1`
is resolved, the head has learned `knownByPeer[Head][1]`, and for every
`j \in 1..(k-1)` both `resolved[j]` and `knownByPeer[Head][j]` hold (no
shortening while resolution notifies are still in flight for the head's
view).

## The kpreid race (canonical EJavaFlush violation)

[`.tlc-logs/MC_EJavaFlush_4Chain.trace.md`](../.tlc-logs/MC_EJavaFlush_4Chain.trace.md):

1. Head sends `seq=1` `viaResolver` → `pending[vatB][1]`.
2. `ProcessPending(vatB,1)` drains `seq=1` onto `channels[vatB][vatC]`.
   **`pending[vatB][1]` is now empty — the local DelayedRedirector
   signal fires.**
3. `seq=1` continues forwarding `vatC→vatD→vatE`. It is currently
   in flight on `channels[vatD][vatE]`.
4. `Shorten` (entry = 4, terminal). `EJavaRelease` is enabled because
   `pending[vatB][1] = 0`, even though `seq=1` is deep in the chain.
5. `shortenActive` becomes TRUE, head shortens `seq=2` directly to
   `vatE` on `channels[vatA][vatE]`.
6. `vatE` has two FIFOs feeding it: `channels[vatD][vatE]` with
   `seq=1` and `channels[vatA][vatE]` with `seq=2`. TLC delivers
   `seq=2` first.

The contrast with `MC_EJavaFlushGlobal_4Chain` (which passes) localizes
the missing assumption to exactly *"nothing for ref 1 is still on the
old chain beyond `host[1]`"* — something the head cannot know without
either god-view or extra protocol messages. The realistic answer is
`OpFlushProtocol`'s in-band token.

## Why the extended op:flush chain is local

The model's `op:flush-fwd` walks hops `1, 2, …, shortenEntry`
(*including* the entry vat). At each non-terminal hop, the only
precondition is the hop's own `pending[host[h]][h] = 0` — the hop has
finished draining its ref-1 queue into the downstream FIFO, so the
flush token rides that FIFO behind every prior ref-1 message. At
`h = shortenEntry`, the entry vat itself sends `op:flush-ack` to the
head. By the FIFO of `channels[host[shortenEntry-1]][host[shortenEntry]]`,
every pre-shortening ref-1 message has already been received at the
entry vat by the time the ack is sent. The post-ack shorten from the
head uses the *separate* FIFO `channels[head][host[shortenEntry]]`,
arriving strictly after everything the entry vat has already received.
No global check at ack receipt is required.

(For `shortenEntry = TerminalPos`, the entry vat is the terminal; the
pending precondition is dropped at that hop since the terminal delivers
directly instead of queuing.)

## Forwarding invariants the model relies on

For `EndToEndRefFIFO_MC` to hold for any policy at `ChainLength >= 4`,
three properties have to be true of `PeerSend` / `ReceiveNetwork` /
`op:flush`:

1. **`viaResolver` always enqueues at `pending[host[1]][1]`** — never
   bypass directly to `host[2]`. Otherwise the head writes
   `channels[head][host[2]]` while `ProcessPending` writes
   `channels[host[1]][host[2]]`: two parallel FIFOs into `host[2]` for
   the same logical stream. (At `ChainLength = 2` the
   `hopFrom = res1` trick hid this, because `host[2]` collapses with
   `head` in any two-peer placement.)

2. **`op:flush-fwd` requires `pending[to][hop] = 0` at every non-terminal
   hop** before forwarding or acking, so the flush token trails all
   ref-1 traffic on the same `channels[host[hop]][host[hop+1]]` FIFO.

3. **`PeerSend` is blocked while `headEmbargo` holds.** Otherwise the
   head keeps pushing new pipelined `viaResolver` messages behind the
   flush token, and those bytes race the post-ack shorten at
   `host[shortenEntry]`.

## Model-checking matrix (ChainLength = 4)

All four shortening policies run on `host = <<vatB,vatC,vatD,vatE>>`,
`HeadPeer = vatA` (five peers, four-hop chain), `NumMessages = 3`.

| Model | Expected | Distinct states |
|-------|----------|-----------------|
| `MC_ShorteningUnsafe_4Chain` | violation | — |
| `MC_EJavaFlush_4Chain` | **violation** (canonical local) | — |
| `MC_EJavaFlushGlobal_4Chain` | pass (god-view control) | ~500k |
| `MC_OpFlushProtocol_4Chain` | pass | ~580k |

### Debug traces + mermaid

`_Debug` modules expose the full `lastAction` stream so the trace
generator can render mermaid:

```bash
./scripts/run-tests.sh --debug MC_NaivePromiseResolution
./scripts/run-tests.sh --debug MC_EJavaFlush_4Chain
./scripts/run-tests.sh --debug MC_OpFlushProtocol_4Chain
```

Outputs: `.tlc-logs/<MC>.trace.md` and `.tlc-logs/<MC>.debug.log`.

## References

- [Promise Shortening — ocapn#11](https://github.com/ocapn/ocapn/issues/11)
  (Tribble four-party ordering / `op:flush` / `whenMoreSettled`).
- [DelayedRedirector — kpreid/e-on-java](https://github.com/kpreid/e-on-java/blob/a0b3b599cf267b3138eea5f5fb83f27cebd28373/src/jsrc/org/erights/e/elib/ref/DelayedRedirector.java).
- Comment trail: [#11 (4524938147)](https://github.com/ocapn/ocapn/issues/11#issuecomment-4524938147),
  [#11 (4525913499)](https://github.com/ocapn/ocapn/issues/11#issuecomment-4525913499),
  [#11 (4344960376)](https://github.com/ocapn/ocapn/issues/11#issuecomment-4344960376),
  [#11 (4442041860)](https://github.com/ocapn/ocapn/issues/11#issuecomment-4442041860).

============================================================================
