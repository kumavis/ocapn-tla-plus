#!/usr/bin/env python3
"""
Read a TLC log on stdin; emit:

  * a Markdown-wrapped mermaid sequenceDiagram (stdout), with each event
    prefixed by its TLC step number `[sN]` and each `op:deliver-only`
    arrow annotated with the recipient's later dequeue step
    (`[s5 → s12]`).  Per-step receive notes appear at the dequeue moment
    so enqueue/dequeue timing is unambiguous.

  * (when `--svg PATH` is given) a sibling Lamport / space-time SVG
    diagram written to PATH, with vertical peer lines and diagonal
    send→receive arrows whose slope encodes transit time (steps
    between enqueue and dequeue).

Mechanism: walk the consecutive `State N:` blocks of TLC's
counterexample dump, diff `channels[from][to]` to detect FIFO
enqueue + dequeue events, match them per channel (FIFO order), and
weave per-step `lastAction` Mark records into the narrative.  TLC
counterexample order isn't wall-clock; both outputs lean on `seq` /
step numbers for unambiguous correlation.
"""

import argparse
import html
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Optional


# ---------------------------------------------------------------------------
# Parsing helpers (unchanged from previous version)
# ---------------------------------------------------------------------------


def esc(s) -> str:
    s = str(s).replace('"', "'")
    return re.sub(r"[^\w\-./]", "_", s)[:100]


def esc_label(s) -> str:
    return str(s).replace('"', "'")[:120]


def find_matching_bracket(s: str, start: int) -> int:
    assert s[start] == "["
    depth = 0
    ang = 0
    i = start
    n = len(s)
    while i < n:
        if ang > 0:
            if s.startswith(">>", i):
                ang -= 1
                i += 2
                continue
            if s.startswith("<<", i):
                ang += 1
                i += 2
                continue
            i += 1
            continue
        if s.startswith("<<", i):
            ang += 1
            i += 2
            continue
        if s[i] == "[":
            depth += 1
        elif s[i] == "]":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def extract_channels_raw(block: str):
    m = re.search(r"/\\ channels[ \t]*=[ \t]*", block)
    if not m:
        return None
    rest = block[m.end():]
    start = rest.find("[")
    if start < 0:
        return None
    end = find_matching_bracket(rest, start)
    if end < 0:
        return None
    return rest[start:end + 1]


def split_tl_sequence(inner: str) -> list[str]:
    """Split TLA-printed record sequence inside << ... >> (no nested <<)."""
    inner = inner.strip()
    if not inner:
        return []
    parts: list[str] = []
    depth = 0
    start = 0
    for idx, ch in enumerate(inner):
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(inner[start:idx].strip())
            start = idx + 1
    parts.append(inner[start:].strip())
    return [p for p in parts if p]


def parse_inner_queues(inner: str) -> dict[str, list[str]]:
    body = inner.strip()
    if not (body.startswith("[") and body.endswith("]")):
        return {}
    body = body[1:-1].strip()
    targets: dict[str, list[str]] = {}
    pos = 0
    n = len(body)
    while pos < n:
        m = re.match(r",?\s*(\w+)\s*\|\->\s*<<", body[pos:])
        if not m:
            break
        to_p = m.group(1)
        j = pos + m.end()
        ang = 1
        k = j
        while k < n and ang > 0:
            if body.startswith("<<", k):
                ang += 1
                k += 2
            elif body.startswith(">>", k):
                ang -= 1
                k += 2
            else:
                k += 1
        inner_seq = body[j:k - 2].strip() if k >= j + 2 else ""
        targets[to_p] = split_tl_sequence(inner_seq)
        pos = k
        while pos < n and body[pos] in " \t\n,":
            pos += 1
    return targets


def parse_channel_matrix(raw: str) -> dict[str, dict[str, list[str]]]:
    if not raw:
        return {}
    body = raw.strip()
    if not (body.startswith("[") and body.endswith("]")):
        return {}
    body = body[1:-1]
    matrix: dict[str, dict[str, list[str]]] = defaultdict(dict)
    i = 0
    n = len(body)
    while i < n:
        m = re.match(r"\s*(\w+)\s*\|\->\s*\[", body[i:])
        if not m:
            break
        from_p = m.group(1)
        start = i + m.end() - 1
        end = find_matching_bracket(body, start)
        if end < 0:
            break
        inner = body[start:end + 1]
        matrix[from_p] = parse_inner_queues(inner)
        i = end + 1
        while i < n and body[i] in " \t\n,":
            i += 1
    return dict(matrix)


def _grp(pat: str, msg: str, default: str = "?") -> str:
    m = re.search(pat, msg)
    return m.group(1) if m else default


def summarize_msg(msg: str) -> str:
    op_pat = r'op\s*\|\->\s*"([^"]*)"'
    seq_pat = r'seq\s*\|\->\s*(\d+)'
    sor_pat = r'sentOnRef\s*\|\->\s*(\d+)'
    rid_pat = r'refId\s*\|\->\s*(\d+)'
    tri_pat = r'targetRefId\s*\|\->\s*(\d+)'
    desc_pat = r'desc\s*\|\->\s*"([^"]*)"'
    gifter_pat = r'gifter\s*\|\->\s*"([^"]*)"'
    targethost_pat = r'targetHost\s*\|\->\s*"([^"]*)"'
    giftid_pat = r'giftId\s*\|\->\s*(\d+)'
    pw_pat = r'pw\s*\|\->\s*(\d+)'
    recipient_pat = r'recipient\s*\|\->\s*"([^"]*)"'
    tlri_pat = r'targetLocalRefId\s*\|\->\s*(\d+)'
    wpr_pat = r'withdrawPromiseRefId\s*\|\->\s*(\d+)'
    answer_pat = r'answerPos\s*\|\->\s*(\d+)'
    rmd_pat = r'resolveMeRefId\s*\|\->\s*(\d+)'
    tdr_pat = r'toDescRefId\s*\|\->\s*(\d+)'

    op = _grp(op_pat, msg)
    if op == "op:deliver-only":
        seq = _grp(seq_pat, msg)
        sor = _grp(sor_pat, msg)
        rid = _grp(rid_pat, msg)
        return f'op:deliver-only(seq={seq}, sentOnRef={sor}, refId={rid})'
    if op == "op:resolve":
        target = _grp(tri_pat, msg)
        desc = _grp(desc_pat, msg)
        if desc in ("desc:import-target", "desc:export-target",
                    "desc:import-promise", "desc:export-promise",
                    "desc:import-object"):
            rid = _grp(rid_pat, msg)
            return f'op:resolve(targetRefId={target}, {desc}(refId={rid}))'
        if desc == "desc:handoff-give":
            gifter = _grp(gifter_pat, msg)
            th = _grp(targethost_pat, msg)
            gid = _grp(giftid_pat, msg)
            pw = _grp(pw_pat, msg)
            return (
                f'op:resolve(targetRefId={target}, desc:handoff-give'
                f'(gifter={gifter}, targetHost={th}, giftId={gid}, pw={pw}))'
            )
        return f'op:resolve(targetRefId={target})'
    if op == "op:flush":
        td = _grp(tdr_pat, msg)
        ap = _grp(answer_pat, msg)
        rm = _grp(rmd_pat, msg)
        return f'op:flush(toDescRefId={td}, answerPos={ap}, resolveMeRefId={rm})'
    if op == "op:flush-ack":
        rid = _grp(rid_pat, msg)
        return f'op:flush-ack(refId={rid})'
    if op == "op:listen":
        rid = _grp(rid_pat, msg)
        return f'op:listen(refId={rid})'
    if op == "op:deposit-gift":
        gid = _grp(giftid_pat, msg)
        rcp = _grp(recipient_pat, msg)
        tlri = _grp(tlri_pat, msg)
        pw = _grp(pw_pat, msg)
        return (
            f'op:deposit-gift(giftId={gid}, recipient={rcp}, '
            f'targetLocalRefId={tlri}, pw={pw})'
        )
    if op == "op:withdraw-gift":
        gid = _grp(giftid_pat, msg)
        gifter = _grp(gifter_pat, msg)
        pw = _grp(wpr_pat, msg)
        return f'op:withdraw-gift(giftId={gid}, gifter={gifter}, pw={pw})'
    return op


def short_msg_label(summary: str) -> str:
    """Compact label for SVG diagonals."""
    m = re.match(r"op:deliver-only\(seq=(\d+), sentOnRef=(\d+), refId=(\d+)\)", summary)
    if m:
        return f"dlv seq={m.group(1)} ref={m.group(3)}"
    m = re.match(r"op:resolve\(targetRefId=(\d+)", summary)
    if m:
        return f"resolve r={m.group(1)}"
    m = re.match(r"op:(\w[\w\-]*)\(", summary)
    if m:
        return f"op:{m.group(1)}"
    return summary[:24]


def msg_kind_of(summary: str) -> str:
    if summary.startswith("op:deliver-only"):
        return "deliver"
    if summary.startswith("op:resolve"):
        return "resolve"
    if summary.startswith("op:flush-ack"):
        return "flush"
    if summary.startswith("op:flush"):
        return "flush"
    if summary.startswith("op:listen"):
        return "listen"
    if summary.startswith("op:deposit") or summary.startswith("op:withdraw"):
        return "gift"
    return "other"


def extract_last_action_record(block: str) -> dict[str, str] | None:
    if "lastAction" not in block:
        return None
    m = re.search(r"/\\ lastAction[ \t]*=[ \t]*(\[)", block)
    if not m:
        return None
    i = m.start(1)
    depth = 0
    j = i
    while j < len(block):
        if block[j] == "[":
            depth += 1
        elif block[j] == "]":
            depth -= 1
            if depth == 0:
                j += 1
                break
        j += 1
    rec = block[i:j]
    fields: dict[str, str] = {}
    for fm in re.finditer(r'(\w+)[ \t]*\|\->[ \t]*("[^"]*"|[^,\]\n]+)', rec):
        k, v = fm.group(1), fm.group(2).strip()
        if v.startswith('"') and v.endswith('"'):
            v = v[1:-1]
        fields[k] = v
    return fields


def extract_delivered_seq_order(block: str) -> list[int]:
    m = re.search(r"/\\ delivered[ \t]*=[ \t]*<<([\s\S]*?)>>", block)
    if not m:
        return []
    inner = m.group(1).strip()
    if not inner:
        return []
    return [int(x) for x in re.findall(r"seq\s*\|\->\s*(\d+)", inner)]


def extract_host_map(block: str) -> list[str]:
    """Parse the `/\\ host = <<"vatB", "vatA", "vatB">>` line into a list
    indexed by refId 1..N.  Returns []  if no `host` field is present."""
    m = re.search(r"/\\ host[ \t]*=[ \t]*<<([\s\S]*?)>>", block)
    if not m:
        return []
    return re.findall(r'"([^"]+)"', m.group(1))


def chain_path_summary(block: str) -> str:
    """Build a one-line `r1@vatB → r2@vatA(LP→r3) → r3@vatB(LT)`-style
    chain summary from the Init state.  Each refId shows host and entry
    kind tag (LT=LocalTarget, LP=LocalPromise) and -- when LocalPromise
    has an initial resolution -- the next hop."""
    host = extract_host_map(block)
    if not host:
        return ""
    # Pull each peer's refs slice; pluck kind + (if LocalPromise) resolution.
    # The refs sequence is `<< [...], [...], ... >>`, but the entries can
    # contain nested `<<>>` (pending / queue), so we walk the `<<...>>`
    # with depth counting rather than non-greedy regex.
    refs_by_peer: dict[str, list[dict[str, str]]] = {}
    for pm in re.finditer(r'(\w+)\s*\|\->\s*\[\s*refs\s*\|\->\s*<<', block):
        peer = pm.group(1)
        j = pm.end()
        ang = 1
        n = len(block)
        while j < n and ang > 0:
            if block.startswith("<<", j):
                ang += 1
                j += 2
            elif block.startswith(">>", j):
                ang -= 1
                if ang == 0:
                    break
                j += 2
            else:
                j += 1
        refs_blob = block[pm.end():j]
        entries: list[dict[str, str]] = []
        depth = 0
        start = -1
        for i, c in enumerate(refs_blob):
            if c == '[':
                if depth == 0:
                    start = i
                depth += 1
            elif c == ']':
                depth -= 1
                if depth == 0 and start >= 0:
                    body = refs_blob[start:i + 1]
                    e: dict[str, str] = {}
                    km = re.search(r'kind\s*\|\->\s*"([^"]+)"', body)
                    if km:
                        e['kind'] = km.group(1)
                    rm = re.search(
                        r'resolution\s*\|\->\s*\[kind\s*\|\->\s*"ref"\s*,'
                        r'\s*peer\s*\|\->\s*"([^"]+)"\s*,\s*refId\s*\|\->\s*(\d+)\]',
                        body)
                    if rm:
                        e['res_peer'] = rm.group(1)
                        e['res_refId'] = rm.group(2)
                    entries.append(e)
                    start = -1
        refs_by_peer[peer] = entries
    short = {'LocalTarget': 'LT', 'LocalPromise': 'LP',
             'RemoteTarget': 'RT', 'RemotePromise': 'RP'}
    parts: list[str] = []
    for idx, h in enumerate(host, start=1):
        entries = refs_by_peer.get(h, [])
        e = entries[idx - 1] if idx - 1 < len(entries) else {}
        kind = e.get('kind', '?')
        tag = short.get(kind, kind)
        suffix = ''
        if 'res_peer' in e and 'res_refId' in e:
            suffix = f'→{e["res_peer"]}:r{e["res_refId"]}'
        parts.append(f'r{idx}@{h}({tag}{suffix})')
    return ' → '.join(parts)


def collect_peers(matrix: dict[str, dict[str, list[str]]]) -> set[str]:
    ps: set[str] = set()
    for f, tm in matrix.items():
        ps.add(f)
        for t in tm:
            ps.add(t)
    return ps


# ---------------------------------------------------------------------------
# Channel diff: FIFO-aware (returns dequeued prefix + enqueued suffix)
# ---------------------------------------------------------------------------


def diff_channel(olist: list[str], nlist: list[str]) -> tuple[list[str], list[str]]:
    """Return (dequeued_prefix_of_old, enqueued_suffix_of_new) consistent with
    `nlist == olist[k:] ++ enqueued` for some k.  Fallback returns (old, new)
    if no FIFO interpretation is possible (shouldn't happen for our model).
    """
    for k in range(0, len(olist) + 1):
        rest = olist[k:]
        if rest == nlist[:len(rest)]:
            return olist[:k], nlist[len(rest):]
    return olist, nlist


# ---------------------------------------------------------------------------
# Action notes from lastAction Mark records (structured: actors + body text)
# ---------------------------------------------------------------------------


@dataclass
class ActionNote:
    actors: tuple[str, ...]   # 1 or 2 actors for `Note over A` / `Note over A,B`
    body: str                 # human-readable body (no leading `[s..]`)
    short: str                # compact label for SVG (one or two words)
    delivers_at: Optional[str] = None
    """If non-None, this step appends to `delivered` at this peer.  The SVG
    renders a delivery-sink marker on that peer's column at this step.
    Covers both `deliver-terminal` (msg directly received at a LocalTarget)
    and `forward-deliver` (msg routed via cascade to a LocalTarget on the
    receiver; same end-state, no wire send out)."""


def action_note_from_fields(fields: dict[str, str]) -> ActionNote | None:
    name = fields.get("name", "").strip()
    if name in ("", "init"):
        return None
    g = lambda k: fields.get(k, "?")

    if name == "PeerSend":
        return ActionNote(
            (g("actor"),),
            f"PeerSend seq={g('seq')} ref={g('ref')} tag={g('tag')} "
            f"-> {g('toPeer')}/refId={g('toRefId')}",
            f"PeerSend seq={g('seq')}",
        )
    if name == "ResolverResolve":
        return ActionNote(
            (g("actor"),),
            f"ResolverResolve refId={g('refId')} resKind={g('resKind')} "
            f"notified={g('notified')} flushed={g('flushed')}",
            f"Resolve r={g('refId')} ({g('resKind')})",
        )
    if name == "ProcessPending":
        return ActionNote(
            (g("actor"),),
            f"ProcessPending fromRefId={g('fromRefId')} "
            f"-> nextRefId={g('nextRefId')} tag={g('tag')} seq={g('seq')}",
            f"Drain queue r={g('fromRefId')} seq={g('seq')}",
        )
    if name == "ProcessHold":
        return ActionNote(
            (g("actor"),),
            f"ProcessHold refId={g('refId')} tag={g('tag')} seq={g('seq')}",
            f"Drain hold r={g('refId')} seq={g('seq')}",
        )
    if name == "SendOpResolveAfterFlush":
        return ActionNote(
            (g("actor"),),
            f"SendOpResolveAfterFlush refId={g('refId')} "
            f"(OpFlushProtocol: acks in, queue+outbox drained)",
            f"SendResolve r={g('refId')}",
        )
    if name == "SendTargetFlushProbe":
        return ActionNote(
            (g("actor"), g("targetPeer")),
            f"SendTargetFlushProbe refId={g('refId')} -> {g('targetPeer')}",
            f"TargetProbe r={g('refId')}",
        )
    if name == "Listen":
        return ActionNote(
            (g("actor"), g("resolver")),
            f"Listen send op:listen refId={g('refId')}",
            f"Listen r={g('refId')}",
        )
    if name == "HandoffInitiate":
        return ActionNote(
            (g("gifter"),),
            f"HandoffInitiate gifter={g('gifter')} recipient={g('recipient')} "
            f"targetHost={g('targetHost')} giftId={g('giftId')} pw={g('pw')}",
            f"Handoff g={g('giftId')}",
        )
    if name == "ReceiveNetwork":
        kind = fields.get("kind", "")
        fro, to = g("from"), g("to")
        if kind == "deliver-terminal":
            return ActionNote(
                (to,),
                f"ReceiveNetwork deliver-terminal {fro}->{to} "
                f"seq={g('seq')} refId={g('refId')} (LocalTarget sink)",
                f"Deliver seq={g('seq')} r={g('refId')}",
                delivers_at=to,
            )
        if kind == "enqueue-pending":
            return ActionNote(
                (to,),
                f"ReceiveNetwork enqueue-pending seq={g('seq')} "
                f"refId={g('refId')} (LocalPromise.queue)",
                f"Recv seq={g('seq')} → queue",
            )
        if kind == "forward-deliver":
            return ActionNote(
                (to,),
                f"ReceiveNetwork forward-deliver {fro}->{to} "
                f"seq={g('seq')} refId={g('refId')} "
                f"(cascade via r={g('refId')} → LocalTarget on {to})",
                f"Deliver seq={g('seq')} (via r={g('refId')})",
                delivers_at=to,
            )
        if kind in ("forward-wire", "forward-queue",
                    "forward-remote", "forward-remote-deliver",
                    "forward-remote-queue", "forward-remote-hold",
                    "forward-remote-target"):
            extra = (f" nextRefId={g('nextRefId')}"
                     if kind == "forward-wire" else "")
            return ActionNote(
                (to,),
                f"ReceiveNetwork {kind} {fro}->{to} seq={g('seq')} "
                f"refId={g('refId')}{extra}",
                f"Fwd seq={g('seq')} r={g('refId')}",
            )
        if kind == "resolve":
            extra = ""
            if "fastPath" in fields:
                extra = f" fastPath={g('fastPath')}"
            return ActionNote(
                (fro, to),
                f"ReceiveNetwork op:resolve refId={g('refId')} "
                f"installed={g('installed')} embargoed={g('embargoed')}{extra}",
                f"Recv resolve r={g('refId')}",
            )
        if kind == "e-flush-probe":
            return ActionNote(
                (fro, to),
                f"ReceiveNetwork op:e-flush-probe refId={g('refId')} "
                f"tag={g('tag')} originPeer={g('originPeer')} "
                f"originRefId={g('originRefId')}",
                f"Recv probe r={g('refId')}",
            )
        if kind == "e-flush-probe-ack":
            return ActionNote(
                (fro, to),
                f"ReceiveNetwork op:e-flush-probe-ack refId={g('refId')} "
                f"(lift embargo)",
                f"Recv probe-ack r={g('refId')}",
            )
        if kind == "resolve-handoff":
            return ActionNote(
                (fro, to),
                f"ReceiveNetwork op:resolve desc:handoff-give "
                f"targetRefId={g('targetRefId')} pw={g('pw')} "
                f"gifter={g('gifter')} targetHost={g('targetHost')} "
                f"giftId={g('giftId')} chain={g('chain')}",
                f"Recv handoff pw={g('pw')}",
            )
        if kind == "flush":
            return ActionNote(
                (fro, to),
                f"ReceiveNetwork op:flush refId={g('refId')} "
                f"(set embargo)",
                f"Recv flush r={g('refId')}",
            )
        if kind == "flush-ack":
            return ActionNote(
                (fro, to),
                f"ReceiveNetwork op:flush-ack refId={g('refId')}",
                f"Recv ack r={g('refId')}",
            )
        if kind == "listen":
            return ActionNote(
                (fro, to),
                f"ReceiveNetwork op:listen refId={g('refId')} "
                f"replied={g('replied')}",
                f"Recv listen r={g('refId')}",
            )
        if kind == "deposit-gift":
            return ActionNote(
                (fro, to),
                f"ReceiveNetwork op:deposit-gift giftId={g('giftId')} "
                f"recipient={g('recipient')} pw={g('pw')}",
                f"Recv deposit g={g('giftId')}",
            )
        if kind == "withdraw-gift":
            return ActionNote(
                (fro, to),
                f"ReceiveNetwork op:withdraw-gift giftId={g('giftId')} "
                f"gifter={g('gifter')} pw={g('pw')} accepted={g('accepted')}",
                f"Recv withdraw g={g('giftId')}",
            )
        return None
    actor = fields.get("actor")
    if actor:
        return ActionNote((actor,), name, name)
    return None


# ---------------------------------------------------------------------------
# Step ingestion: build per-step events and matched messages
# ---------------------------------------------------------------------------


@dataclass
class ChannelEvent:
    step: int
    kind: str          # 'enqueue' or 'dequeue'
    from_peer: str
    to_peer: str
    msg_raw: str
    summary: str


@dataclass
class MatchedMessage:
    from_peer: str
    to_peer: str
    send_step: int
    recv_step: Optional[int]
    summary: str
    kind: str          # color bucket for SVG


@dataclass
class StepInfo:
    step: int
    note: Optional[ActionNote]
    enqueues: list[ChannelEvent] = field(default_factory=list)
    dequeues: list[ChannelEvent] = field(default_factory=list)


def ingest(log: str):
    """Parse the entire TLC log into a list of StepInfo, all_peers,
    matched messages, and the final delivered seq order."""
    parts = re.split(r"\n(?=State \d+:)", log)

    # Per-state: extract step, channels matrix, lastAction fields, peers.
    matrices: list[dict[str, dict[str, list[str]]]] = []
    steps: list[int] = []
    action_records: list[dict[str, str] | None] = []
    all_peers: set[str] = set()

    for block in parts:
        m = re.match(r"State (\d+):", block)
        if not m:
            steps.append(0)
            matrices.append({})
            action_records.append(None)
            continue
        steps.append(int(m.group(1)))
        raw = extract_channels_raw(block)
        mat = parse_channel_matrix(raw) if raw else {}
        matrices.append(mat)
        all_peers |= collect_peers(mat)
        action_records.append(extract_last_action_record(block))

    # Build per-step events from consecutive channel-matrix diffs.
    step_infos: list[StepInfo] = []
    for idx, block in enumerate(parts):
        if idx == 0:
            continue
        prev = matrices[idx - 1] if idx - 1 < len(matrices) else {}
        cur = matrices[idx]
        step = steps[idx]
        note = action_note_from_fields(action_records[idx] or {})
        si = StepInfo(step=step, note=note)
        # Iterate over union of (from, to) pairs.
        all_pairs = set()
        for f, tm in prev.items():
            for t in tm:
                all_pairs.add((f, t))
        for f, tm in cur.items():
            for t in tm:
                all_pairs.add((f, t))
        for f, t in sorted(all_pairs):
            olist = prev.get(f, {}).get(t, [])
            nlist = cur.get(f, {}).get(t, [])
            if olist == nlist:
                continue
            deq, enq = diff_channel(olist, nlist)
            for m_raw in deq:
                si.dequeues.append(ChannelEvent(
                    step=step, kind="dequeue",
                    from_peer=f, to_peer=t,
                    msg_raw=m_raw, summary=summarize_msg(m_raw),
                ))
            for m_raw in enq:
                si.enqueues.append(ChannelEvent(
                    step=step, kind="enqueue",
                    from_peer=f, to_peer=t,
                    msg_raw=m_raw, summary=summarize_msg(m_raw),
                ))
        step_infos.append(si)

    # Match enqueues to dequeues FIFO per (from, to) channel by raw string.
    pending: dict[tuple[str, str], list[ChannelEvent]] = defaultdict(list)
    matched: list[MatchedMessage] = []
    for si in step_infos:
        # Process dequeues before enqueues so a forward (deq + enq at same step)
        # doesn't accidentally match its own enqueue.
        for ev in si.dequeues:
            key = (ev.from_peer, ev.to_peer)
            q = pending[key]
            # Find earliest matching by msg_raw equality.
            idx = next((i for i, x in enumerate(q) if x.msg_raw == ev.msg_raw),
                       None)
            if idx is None:
                # Dequeue with no matching enqueue (shouldn't normally happen
                # — would mean message was in channel at Init).  Record as
                # incoming-only with no send_step.
                matched.append(MatchedMessage(
                    from_peer=ev.from_peer, to_peer=ev.to_peer,
                    send_step=0, recv_step=ev.step,
                    summary=ev.summary, kind=msg_kind_of(ev.summary),
                ))
            else:
                send_ev = q.pop(idx)
                matched.append(MatchedMessage(
                    from_peer=send_ev.from_peer, to_peer=send_ev.to_peer,
                    send_step=send_ev.step, recv_step=ev.step,
                    summary=send_ev.summary,
                    kind=msg_kind_of(send_ev.summary),
                ))
        for ev in si.enqueues:
            pending[(ev.from_peer, ev.to_peer)].append(ev)

    # Unmatched enqueues = in-flight at trace end.
    for key, q in pending.items():
        for ev in q:
            matched.append(MatchedMessage(
                from_peer=ev.from_peer, to_peer=ev.to_peer,
                send_step=ev.step, recv_step=None,
                summary=ev.summary, kind=msg_kind_of(ev.summary),
            ))

    delivered = extract_delivered_seq_order(parts[-1]) if parts else []
    # Initial state (parts[0] is the preamble before "State 1:"; parts[1] is
    # State 1 if present).  Parse the chain summary from State 1.
    chain = chain_path_summary(parts[1]) if len(parts) > 1 else ""
    return step_infos, sorted(all_peers), matched, delivered, chain


# ---------------------------------------------------------------------------
# Output: enhanced mermaid
# ---------------------------------------------------------------------------


def emit_mermaid(step_infos: list[StepInfo],
                 peers: list[str],
                 matched: list[MatchedMessage],
                 delivered: list[int],
                 chain: str = "") -> str:
    """Build the mermaid sequenceDiagram (string with leading/trailing ```)."""
    # Index recv_step per (send_step, msg_raw_summary, from, to) so each
    # enqueue arrow can show its later dequeue step.
    recv_at: dict[tuple[int, str, str, str], Optional[int]] = {}
    for m in matched:
        if m.send_step == 0:
            continue
        recv_at[(m.send_step, m.summary, m.from_peer, m.to_peer)] = m.recv_step

    lines: list[str] = ["```mermaid", "sequenceDiagram", "    autonumber"]
    for p in peers:
        lines.append(f"    participant {esc(p)} as {esc(p)}")
    if not peers:
        lines.append("    Note over TLC: no channels in log")
    elif len(peers) >= 2:
        if chain:
            lines.append(
                f"    Note over {esc(peers[0])},{esc(peers[-1])}: "
                f"Chain: {esc_label(chain)}"
            )
        lines.append(
            f"    Note over {esc(peers[0])},{esc(peers[-1])}: "
            "TLC step `[sN]` is the BFS state index. "
            "Arrows show channel enqueues "
            "(`[s_send → s_recv]` = transit gap); "
            "receive `Note`s mark the matching dequeue. "
            "Channels are FIFO per (from,to) only — distinct channels "
            "can interleave at a receiver."
        )

    any_events = False
    for si in step_infos:
        s = si.step
        if si.note:
            actors = ",".join(esc(a) for a in si.note.actors)
            lines.append(f"    Note over {actors}: [s{s}] {esc_label(si.note.body)}")
            any_events = True
        # Enqueues first emit arrows
        for ev in si.enqueues:
            rs = recv_at.get((s, ev.summary, ev.from_peer, ev.to_peer))
            tag = f"[s{s} → s{rs}]" if rs is not None else f"[s{s} → ?]"
            if ev.from_peer == ev.to_peer:
                lines.append(
                    f"    {esc(ev.from_peer)}->>{esc(ev.to_peer)}: "
                    f"{tag} {esc_label(ev.summary)} (same-vat wire)"
                )
            else:
                lines.append(
                    f"    {esc(ev.from_peer)}->>{esc(ev.to_peer)}: "
                    f"{tag} {esc_label(ev.summary)}"
                )
            any_events = True
        # Explicit dequeue notes (when not already covered by an action note
        # that has its own kind — we always add them for clarity, since the
        # action note describes what the receiver did, not when the message
        # was sent).
        for ev in si.dequeues:
            sent_step = next(
                (m.send_step for m in matched
                 if m.recv_step == s and m.from_peer == ev.from_peer
                 and m.to_peer == ev.to_peer and m.summary == ev.summary
                 and m.send_step != 0),
                None,
            )
            origin = f"sent@s{sent_step}" if sent_step is not None else "sent@init"
            lines.append(
                f"    Note over {esc(ev.to_peer)}: [s{s}] dequeue from "
                f"{esc(ev.from_peer)} ({esc_label(ev.summary)}, {origin})"
            )
            any_events = True

    if delivered:
        if len(delivered) >= 2 and delivered != sorted(delivered):
            a = peers[0] if peers else "vatA"
            b = peers[-1] if peers else a
            inv = next(
                ((delivered[i], delivered[i + 1])
                 for i in range(len(delivered) - 1)
                 if delivered[i] > delivered[i + 1]),
                None,
            )
            story = ""
            if inv:
                hi, lo = inv
                story = (
                    f" First inversion: seq {hi} before seq {lo} "
                    "(higher seq applied first — usually parallel FIFO edges "
                    "or a post-resolution path racing in-flight traffic)."
                )
            lines.append(
                f"    Note over {esc(a)},{esc(b)}: EndToEndRefFIFO violated: "
                f"delivered order {delivered}.{story}"
            )

    lines.append("```")
    if not any_events and not peers:
        return ("<!-- trace-to-mermaid: no channel or lastAction steps -->\n"
                "```mermaid\nsequenceDiagram\n    Note over TLC: empty trace\n```")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Output: SVG Lamport / space-time diagram
# ---------------------------------------------------------------------------


SVG_COLORS = {
    "deliver": "#1f77b4",   # blue: op:deliver-only
    "resolve": "#d62728",   # red: op:resolve
    "flush":   "#2ca02c",   # green: op:flush / op:flush-ack
    "listen":  "#9467bd",   # purple: op:listen
    "gift":    "#ff7f0e",   # orange: gift ops
    "other":   "#7f7f7f",   # gray
}


def xml_escape(s: str) -> str:
    return html.escape(str(s), quote=True)


def emit_svg(step_infos: list[StepInfo],
             peers: list[str],
             matched: list[MatchedMessage],
             delivered: list[int],
             chain: str = "") -> str:
    if not peers or not step_infos:
        return ('<?xml version="1.0" encoding="UTF-8"?>\n'
                '<svg xmlns="http://www.w3.org/2000/svg" width="200" '
                'height="60"><text x="10" y="30" font-family="monospace" '
                'font-size="12">empty trace</text></svg>')

    n_peers = len(peers)
    n_steps = len(step_infos)

    # Layout: add an extra header row when we have a chain summary to draw.
    margin_left = 80
    margin_right = 40
    margin_top = 80 + (16 if chain else 0)
    margin_bottom = 60
    col_width = 180
    row_height = 34

    # Width must accommodate the widest of: peer-column span, header text,
    # and legend.  720px is a safe floor for the 2-peer case.
    width = max(
        margin_left + col_width * (n_peers - 1) + margin_right + 220,
        720,
    )
    height = margin_top + row_height * n_steps + margin_bottom

    peer_x = {p: margin_left + 60 + i * col_width for i, p in enumerate(peers)}
    step_y = {si.step: margin_top + i * row_height
              for i, si in enumerate(step_infos)}

    parts: list[str] = []
    parts.append('<?xml version="1.0" encoding="UTF-8"?>')
    parts.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
        f'height="{height}" font-family="-apple-system, ui-monospace, '
        f'Menlo, monospace" font-size="11">'
    )
    # Arrowhead markers per color
    parts.append('<defs>')
    for cid, color in SVG_COLORS.items():
        parts.append(
            f'<marker id="arr-{cid}" viewBox="0 0 10 10" refX="9" refY="5" '
            f'markerWidth="8" markerHeight="8" orient="auto-start-reverse">'
            f'<path d="M0,0 L10,5 L0,10 z" fill="{color}"/></marker>'
        )
    parts.append('</defs>')

    # White background
    parts.append(f'<rect width="{width}" height="{height}" fill="white"/>')

    # Header: title
    parts.append(
        f'<text x="{margin_left}" y="22" font-size="13" font-weight="bold">'
        f'Lamport space-time (time ↓ = TLC step; diagonals = send→receive)'
        '</text>'
    )
    parts.append(
        f'<text x="{margin_left}" y="40" font-size="10" fill="#666">'
        'Solid = matched send/receive. Dashed = still in-flight at trace end.'
        ' Slope ≈ transit (more steps = steeper).'
        ' Filled square on a peer column = terminal delivery (msg appended'
        ' to `delivered` at that peer).'
        '</text>'
    )

    # Chain path summary, if the initial state had a `host` map we could
    # parse.  Sits just below the header text and above the peer columns.
    if chain:
        parts.append(
            f'<text x="{margin_left}" y="56" font-size="10" fill="#555">'
            f'Chain: {xml_escape(chain)}'
            '</text>'
        )

    # Peer columns + labels
    for p in peers:
        x = peer_x[p]
        parts.append(
            f'<line x1="{x}" y1="{margin_top - 20}" x2="{x}" '
            f'y2="{height - margin_bottom + 20}" stroke="#bbb" '
            f'stroke-width="1"/>'
        )
        parts.append(
            f'<text x="{x}" y="{margin_top - 28}" text-anchor="middle" '
            f'font-weight="bold" font-size="13" fill="#222">{xml_escape(p)}'
            '</text>'
        )

    # Step gutter (left)
    for si in step_infos:
        y = step_y[si.step]
        parts.append(
            f'<text x="30" y="{y + 4}" font-size="9" fill="#888" '
            f'text-anchor="end">s{si.step}</text>'
        )

    # Action note per step, placed at the first actor's column
    for si in step_infos:
        if not si.note:
            continue
        actor = si.note.actors[0]
        if actor not in peer_x:
            continue
        x = peer_x[actor] + 10
        y = step_y[si.step] + 4
        parts.append(
            f'<text x="{x}" y="{y}" font-size="9" fill="#555">'
            f'{xml_escape(si.note.short)}</text>'
        )
        # Terminal delivery sink: a filled square on the receiver's column
        # marks the step at which a seq lands in `delivered`.  Covers both
        # deliver-terminal (direct LocalTarget receive) and forward-deliver
        # (cascade via LocalPromise resolution to a LocalTarget on `to`).
        if si.note.delivers_at and si.note.delivers_at in peer_x:
            cx = peer_x[si.note.delivers_at]
            cy = step_y[si.step]
            color = SVG_COLORS["deliver"]
            parts.append(
                f'<rect x="{cx - 4}" y="{cy - 4}" width="8" height="8" '
                f'fill="{color}" stroke="white" stroke-width="1"/>'
            )

    # Diagonal arrows for each matched message
    for m in matched:
        if m.from_peer not in peer_x or m.to_peer not in peer_x:
            continue
        x1 = peer_x[m.from_peer]
        x2 = peer_x[m.to_peer]
        if m.send_step in step_y:
            y1 = step_y[m.send_step]
        else:
            y1 = margin_top - 10
        if m.recv_step is not None and m.recv_step in step_y:
            y2 = step_y[m.recv_step]
            dash = ""
        else:
            # Drop to bottom for in-flight
            y2 = height - margin_bottom + 5
            dash = ' stroke-dasharray="4,4"'
        color = SVG_COLORS.get(m.kind, SVG_COLORS["other"])
        if x1 == x2:
            # Same-peer hop: draw a small loop to the right of the column.
            loop_x = x1 + 15
            parts.append(
                f'<path d="M{x1},{y1} Q{loop_x},{(y1 + y2) / 2} {x2},{y2}" '
                f'fill="none" stroke="{color}" stroke-width="1.5"{dash} '
                f'marker-end="url(#arr-{m.kind})"/>'
            )
            label_x = loop_x + 4
            label_y = (y1 + y2) / 2
            anchor = "start"
        else:
            parts.append(
                f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" '
                f'stroke="{color}" stroke-width="1.5"{dash} '
                f'marker-end="url(#arr-{m.kind})"/>'
            )
            # Place label ~40% along the arrow.  Right-going arrows label
            # above the line, left-going below — so opposing-direction
            # arrows that cross don't pile labels on top of each other.
            t = 0.40
            label_x = x1 + t * (x2 - x1)
            base_y = y1 + t * (y2 - y1)
            if x2 > x1:
                label_y = base_y - 5
                anchor = "start"
            else:
                label_y = base_y + 10
                anchor = "end"
        parts.append(
            f'<text x="{label_x}" y="{label_y}" font-size="9" '
            f'fill="{color}" text-anchor="{anchor}">'
            f'{xml_escape(short_msg_label(m.summary))}</text>'
        )

    # Footer: legend + violation
    legend_x = margin_left
    legend_y = height - 24
    parts.append(
        f'<text x="{legend_x}" y="{legend_y}" font-size="10" fill="#444">'
        'Legend:</text>'
    )
    offset = 60
    for cid, color in SVG_COLORS.items():
        if cid == "other":
            continue
        parts.append(
            f'<line x1="{legend_x + offset}" y1="{legend_y - 3}" '
            f'x2="{legend_x + offset + 18}" y2="{legend_y - 3}" '
            f'stroke="{color}" stroke-width="1.5"/>'
        )
        parts.append(
            f'<text x="{legend_x + offset + 22}" y="{legend_y}" '
            f'font-size="10" fill="{color}">{cid}</text>'
        )
        offset += 80

    if len(delivered) >= 2 and delivered != sorted(delivered):
        inv = next(
            ((delivered[i], delivered[i + 1])
             for i in range(len(delivered) - 1)
             if delivered[i] > delivered[i + 1]),
            None,
        )
        story = ""
        if inv:
            hi, lo = inv
            story = f" (first inversion: seq {hi} before seq {lo})"
        parts.append(
            f'<text x="{legend_x}" y="{height - 8}" font-size="11" '
            f'fill="#d62728" font-weight="bold">EndToEndRefFIFO violated: '
            f'delivered order {delivered}{xml_escape(story)}</text>'
        )

    parts.append('</svg>')
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--svg",
        metavar="PATH",
        help="Also write a sibling Lamport/space-time SVG diagram to PATH.",
    )
    args = ap.parse_args()

    log = sys.stdin.read()
    step_infos, peers, matched, delivered, chain = ingest(log)

    md = emit_mermaid(step_infos, peers, matched, delivered, chain)
    print(md)
    if not step_infos and not peers:
        print("<!-- trace-to-mermaid: no channel or lastAction steps -->",
              file=sys.stderr)

    if args.svg:
        try:
            with open(args.svg, "w", encoding="utf-8") as f:
                f.write(emit_svg(step_infos, peers, matched, delivered, chain))
        except OSError as e:
            print(f"warning: could not write SVG to {args.svg}: {e}",
                  file=sys.stderr)


if __name__ == "__main__":
    main()
