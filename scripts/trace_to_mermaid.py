#!/usr/bin/env python3
"""
Read a TLC log on stdin; print Markdown containing a mermaid sequenceDiagram.

Primary: diff `channels` between consecutive counterexample states and emit
`from->>to:` arrows for newly enqueued wire messages (cross-vat traffic).

Secondary: `lastAction` records as Notes (often spanning client+resolver).
Notes are emitted *before* channel diffs each step so the narrative (what a
vat intended) appears before the FIFO edge that carried bytes (the model may
serialize some forwards on `resolver->client` to avoid duplicate same-vat
FIFOs).

TLC counterexample order is not guaranteed to match wall-clock story order;
use `seq` labels and the final delivered-order note.
"""
import re
import sys
from collections import defaultdict


def esc(s: str) -> str:
    s = str(s).replace('"', "'")
    return re.sub(r"[^\w\-./]", "_", s)[:100]


def find_matching_bracket(s: str, start: int) -> int:
    """Match s[start]=='[' ... ']' ignoring brackets inside << ... >>."""
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


def esc_label(s: str) -> str:
    """Mermaid-safe label: keep parens/colons readable."""
    return str(s).replace('"', "'")[:120]


def extract_channels_raw(block: str):
    m = re.search(r"/\\ channels[ \t]*=[ \t]*", block)
    if not m:
        return None
    rest = block[m.end() :]
    start = rest.find("[")
    if start < 0:
        return None
    end = find_matching_bracket(rest, start)
    if end < 0:
        return None
    return rest[start : end + 1]


def parse_inner_queues(inner: str) -> dict[str, list[str]]:
    """Parse `to |-> << ... >>` entries inside one row `[ ... ]`."""
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
        inner_seq = body[j : k - 2].strip() if k >= j + 2 else ""
        targets[to_p] = split_tl_sequence(inner_seq)
        pos = k
        while pos < n and body[pos] in " \t\n,":
            pos += 1
    return targets


def split_tl_sequence(inner: str) -> list[str]:
    """Split TLA-printed sequence body inside << ... >> (no nested << in our model)."""
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


def parse_channel_matrix(raw: str) -> dict[str, dict[str, list[str]]]:
    """channels[from][to] = list of message print strings."""
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
        inner = body[start : end + 1]
        matrix[from_p] = parse_inner_queues(inner)
        i = end + 1
        while i < n and body[i] in " \t\n,":
            i += 1
    return dict(matrix)


def summarize_msg(msg: str) -> str:
    mo = re.search(r'op\s*\|\->\s*"([^"]*)"', msg)
    op = mo.group(1) if mo else "?"
    if op == "op:resolve":
        m2 = re.search(r"promise\s*\|\->\s*(\d+)", msg)
        pr = m2.group(1) if m2 else "?"
        return f'op:resolve(pr={pr})'
    if op == "op:deliver-only":
        ms = re.search(r"sender\s*\|\->\s*\"([^\"]*)\"", msg)
        seq = re.search(r"seq\s*\|\->\s*(\d+)", msg)
        ref = re.search(r"sentOnRef\s*\|\->\s*(\d+)", msg)
        pos = re.search(r"pos\s*\|\->\s*(\d+)", msg)
        return (
            f'op:deliver-only(seq={seq.group(1) if seq else "?"}, '
            f'ref={ref.group(1) if ref else "?"}, pos={pos.group(1) if pos else "?"})'
        )
    if op == "op:flush-fwd":
        t = re.search(r"target\s*\|\->\s*(\d+)", msg)
        h = re.search(r"hop\s*\|\->\s*(\d+)", msg)
        return (
            f'op:flush-fwd(target={t.group(1) if t else "?"}, '
            f'hop={h.group(1) if h else "?"})'
        )
    if op == "op:flush-ack":
        return "op:flush-ack"
    if op == "op:flush":
        r = re.search(r"refId\s*\|\->\s*(\d+)", msg)
        return f'op:flush(refId={r.group(1) if r else "?"})'
    if op == "op:listen":
        r = re.search(r"refId\s*\|\->\s*(\d+)", msg)
        return f'op:listen(refId={r.group(1) if r else "?"})'
    if op == "op:deposit-gift":
        g = re.search(r"giftId\s*\|\->\s*(\d+)", msg)
        rcp = re.search(r"recipient\s*\|\->\s*\"([^\"]*)\"", msg)
        pw = re.search(r"pw\s*\|\->\s*(\d+)", msg)
        return (
            f'op:deposit-gift(gid={g.group(1) if g else "?"}, '
            f'recipient={rcp.group(1) if rcp else "?"}, '
            f'pw={pw.group(1) if pw else "?"})'
        )
    if op == "op:withdraw-gift":
        g = re.search(r"giftId\s*\|\->\s*(\d+)", msg)
        gifter = re.search(r"gifter\s*\|\->\s*\"([^\"]*)\"", msg)
        pw = re.search(r"withdrawPromiseRefId\s*\|\->\s*(\d+)", msg)
        return (
            f'op:withdraw-gift(gid={g.group(1) if g else "?"}, '
            f'gifter={gifter.group(1) if gifter else "?"}, '
            f'pw={pw.group(1) if pw else "?"})'
        )
    return op


def channel_diff(
    old: dict[str, dict[str, list[str]]],
    new: dict[str, dict[str, list[str]]],
) -> list[tuple[str, str, str]]:
    """Return list of (from, to, summary) for each newly appended message."""
    out: list[tuple[str, str, str]] = []
    for frm, tomap in new.items():
        for to, nlist in tomap.items():
            olist = old.get(frm, {}).get(to, [])
            if len(nlist) <= len(olist):
                continue
            for msg in nlist[len(olist) :]:
                out.append((frm, to, summarize_msg(msg)))
    return out


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


def collect_peers(matrix: dict[str, dict[str, list[str]]]) -> set[str]:
    ps: set[str] = set()
    for f, tm in matrix.items():
        ps.add(f)
        for t in tm:
            ps.add(t)
    return ps


def note_from_last_action(fields: dict[str, str]) -> str | None:
    name = fields.get("name", "").strip()
    if name in ("", "init"):
        return None
    if name == "PeerSend":
        tag = fields.get("tag", "?")
        seq = fields.get("seq", "?")
        ref = fields.get("ref", "?")
        act = fields.get("actor", "?")
        res = fields.get("resolver", "?")
        se = fields.get("shortenEntry", "?")
        if tag == "local":
            return (
                f"Note over {esc(act)}: PeerSend local seq={esc(seq)} ref={esc(ref)} "
                f"(naive shorten to terminal; can race pipelined lower seq still in flight)"
            )
        if tag == "shorten":
            return (
                f"Note over {esc(act)}: PeerSend shorten seq={esc(seq)} ref-{esc(ref)} "
                f"to shortenEntry={esc(se)} (post-shortening path)"
            )
        return (
            f"Note over {esc(act)},{esc(res)}: PeerSend viaResolver seq={esc(seq)} ref-{esc(ref)} "
            f"(p1): {esc(act)} logically targets promise at resolver {esc(res)} "
            f"(wire may use {esc(res)}->>{esc(act)} hop in this MC)"
        )
    if name == "LocalDeliver":
        act = fields.get("actor", "?")
        seq = fields.get("seq", "?")
        return f"Note over {esc(act)}: deliver seq={esc(seq)} (localQueues)"
    if name == "ResolverResolve":
        act = fields.get("actor", "?")
        pr = fields.get("promise", "?")
        return f"Note over {esc(act)}: resolve promise {esc(pr)} (broadcast on wire)"
    if name == "ProcessPending":
        act = fields.get("actor", "?")
        seq = fields.get("seq", "?")
        pr = fields.get("promise", "?")
        np = fields.get("nextPos", "?")
        return (
            f"Note over {esc(act)}: ProcessPending pr={esc(pr)} seq={esc(seq)} "
            f"nextPos={esc(np)} (may deliver AFTER a higher seq already applied)"
        )
    if name == "ReceiveNetwork":
        kind = fields.get("kind", "")
        fro, to = fields.get("from", "?"), fields.get("to", "?")
        if kind == "resolve":
            pr = fields.get("promise", "?")
            return (
                f"Note over {esc(to)}: ReceiveNetwork {esc(fro)}->>{esc(to)} "
                f"resolve p={esc(pr)} (resolver tells client p1 is settled)"
            )
        if kind == "deliver-terminal":
            seq = fields.get("seq", "?")
            ref = fields.get("ref", "?")
            return (
                f"Note over {esc(to)}: ReceiveNetwork terminal: apply deliver-only "
                f"seq={esc(seq)} ref={esc(ref)} (may be after a higher seq already applied)"
            )
        if kind == "enqueue-pending":
            seq = fields.get("seq", "?")
            pos = fields.get("pos", "?")
            return (
                f"Note over {esc(to)}: ReceiveNetwork enqueue-pending seq={esc(seq)} pos={esc(pos)}"
            )
        if kind in ("forward-deliver", "forward-wire"):
            return (
                f"Note over {esc(to)}: ReceiveNetwork {esc(kind)} "
                f"{esc(fro)}->{esc(to)}"
            )
        if kind in ("flush-fwd", "flush-ack-send", "flush-ack-head"):
            hop = fields.get("hop", "?")
            tgt = fields.get("target", "?")
            return (
                f"Note over {esc(fro)},{esc(to)}: op:flush {esc(kind)} "
                f"hop={esc(hop)} target={esc(tgt)}"
            )
        if kind == "listen":
            ref = fields.get("refId", "?")
            replied = fields.get("replied", "?")
            return (
                f"Note over {esc(fro)},{esc(to)}: ReceiveNetwork op:listen "
                f"refId={esc(ref)} reply={esc(replied)}"
            )
        if kind == "flush":
            ref = fields.get("refId", "?")
            return (
                f"Note over {esc(fro)},{esc(to)}: ReceiveNetwork op:flush "
                f"refId={esc(ref)}"
            )
        if kind == "flush-ack":
            ref = fields.get("refId", "?")
            return (
                f"Note over {esc(fro)},{esc(to)}: ReceiveNetwork op:flush-ack "
                f"refId={esc(ref)}"
            )
        if kind == "deposit-gift":
            gid = fields.get("giftId", "?")
            rcp = fields.get("recipient", "?")
            pw = fields.get("pw", "?")
            return (
                f"Note over {esc(fro)},{esc(to)}: ReceiveNetwork op:deposit-gift "
                f"gid={esc(gid)} recipient={esc(rcp)} pw={esc(pw)} "
                f"(pre-mint LocalPromise(pw))"
            )
        if kind == "withdraw-gift":
            gid = fields.get("giftId", "?")
            gifter = fields.get("gifter", "?")
            pw = fields.get("pw", "?")
            acc = fields.get("accepted", "?")
            return (
                f"Note over {esc(fro)},{esc(to)}: ReceiveNetwork op:withdraw-gift "
                f"gid={esc(gid)} gifter={esc(gifter)} pw={esc(pw)} accepted={esc(acc)}"
            )
        if kind == "resolve-handoff":
            tr = fields.get("targetRefId", "?")
            pw = fields.get("pw", "?")
            tgt = fields.get("targetHost", "?")
            ch = fields.get("chain", "?")
            return (
                f"Note over {esc(fro)},{esc(to)}: ReceiveNetwork op:resolve "
                f"desc:handoff-give targetRefId={esc(tr)} pw={esc(pw)} "
                f"targetHost={esc(tgt)} chain={esc(ch)}"
            )
        return None
    if name == "Shorten":
        pol = fields.get("policy", "?")
        ent = fields.get("entry", "?")
        pipe = fields.get("pipelined", "?")
        head = fields.get("actor", "?")
        return (
            f"Note over {esc(head)}: Shorten policy={esc(pol)} "
            f"entry={esc(ent)} headPipelined={esc(pipe)}"
        )
    if name == "Listen":
        act = fields.get("actor", "?")
        res = fields.get("resolver", "?")
        ref = fields.get("refId", "?")
        return (
            f"Note over {esc(act)},{esc(res)}: Listen send op:listen refId={esc(ref)} "
            f"(dynamic subscription)"
        )
    if name == "HandoffInitiate":
        gifter = fields.get("gifter", "?")
        rcp = fields.get("recipient", "?")
        th = fields.get("targetHost", "?")
        gid = fields.get("giftId", "?")
        pw = fields.get("pw", "?")
        er = fields.get("existingRefId", "?")
        return (
            f"Note over {esc(gifter)}: HandoffInitiate gifter={esc(gifter)} "
            f"recipient={esc(rcp)} targetHost={esc(th)} gid={esc(gid)} "
            f"pw={esc(pw)} existingRefId={esc(er)} (3PHO: send deposit + resolve)"
        )
    if name == "EJavaRelease":
        ent = fields.get("entry", "?")
        head = fields.get("actor", "?")
        return (
            f"Note over {esc(head)}: EJavaRelease lift embargo, "
            f"shortenEntry={esc(ent)} (local signal: pending[host[1]][1] = 0)"
        )
    actor = fields.get("actor")
    if actor:
        return f"Note over {esc(actor)}: {esc(name)}"
    return None


def extract_delivered_seq_order(block: str) -> list[int]:
    m = re.search(r"/\\ delivered[ \t]*=[ \t]*<<([\s\S]*?)>>", block)
    if not m:
        return []
    inner = m.group(1).strip()
    if not inner:
        return []
    return [int(x) for x in re.findall(r"seq\s*\|\->\s*(\d+)", inner)]


log = sys.stdin.read()
parts = re.split(r"\n(?=State \d+:)", log)

lines_out = [
    "```mermaid",
    "sequenceDiagram",
    "    autonumber",
]

all_peers: set[str] = set()
matrices: list[dict[str, dict[str, list[str]]]] = []
for block in parts:
    raw = extract_channels_raw(block)
    if raw is None:
        matrices.append({})
        continue
    mat = parse_channel_matrix(raw)
    matrices.append(mat)
    all_peers |= collect_peers(mat)

for p in sorted(all_peers):
    lines_out.append(f"    participant {esc(p)} as {esc(p)}")

if not all_peers:
    lines_out.append("    Note over TLC: no channels in log")
elif len(all_peers) >= 2:
    pv = sorted(all_peers)
    lines_out.append(
        f"    Note over {esc(pv[0])},{esc(pv[-1])}: "
        "TLC order may reorder steps vs wall-clock; read seq numbers. "
        "Solid arrows = channel FIFO append."
    )

step = 0
for idx in range(len(parts)):
    block = parts[idx]
    if idx == 0:
        continue
    prev_m = matrices[idx - 1] if idx - 1 < len(matrices) else {}
    cur_m = matrices[idx] if idx < len(matrices) else {}
    fields = extract_last_action_record(block)
    if fields:
        n = note_from_last_action(fields)
        if n:
            lines_out.append(f"    {n}")
            step += 1
    for frm, to, summ in channel_diff(prev_m, cur_m):
        if frm == to:
            lines_out.append(
                f"    {esc(frm)}->>{esc(to)}: {esc_label(summ)} (same-vat wire)"
            )
        else:
            lines_out.append(f"    {esc(frm)}->>{esc(to)}: {esc_label(summ)}")
        step += 1

if parts:
    seq_order = extract_delivered_seq_order(parts[-1])
    if len(seq_order) >= 2 and seq_order != sorted(seq_order):
        ps = sorted(all_peers)
        if len(ps) >= 2:
            a, b = ps[0], ps[-1]
        else:
            a = b = ps[0] if ps else "vatA"
        inv = next(
            (
                (seq_order[i], seq_order[i + 1])
                for i in range(len(seq_order) - 1)
                if seq_order[i] > seq_order[i + 1]
            ),
            None,
        )
        story = ""
        if inv:
            hi, lo = inv
            story = (
                f" First inversion: seq {hi} before seq {lo} (higher seq applied first — "
                f"often parallel FIFO edges or a post-resolution shorten racing in-flight traffic)."
            )
        lines_out.append(
            f"    Note over {esc(a)},{esc(b)}: EndToEndRefFIFO violated: "
            f"delivered order {seq_order}.{story}"
        )

lines_out.append("```")

if step == 0 and not all_peers:
    print(
        "<!-- trace-to-mermaid: no channel or lastAction steps found -->",
        file=sys.stderr,
    )
    print("```mermaid\nsequenceDiagram\n    Note over TLC: empty trace\n```")
else:
    print("\n".join(lines_out))
