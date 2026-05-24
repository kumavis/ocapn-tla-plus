------------------------- MODULE PromiseResolution -------------------------
(***************************************************************************)
(* Linear ref-chain, per-pair FIFO, HeadPeer emits op:deliver-only on ref 1. *)
(*                                                                         *)
(* RoutingPolicy:                                                          *)
(*   "NaivePromiseResolution" | "NoPromiseResolution" — original.         *)
(*   "ShorteningUnsafe" — optional Shorten: client may jump to             *)
(*      host[shortenEntry] (promise-to-promise / terminal shortening)      *)
(*      without flush; breaks EndToEndRefFIFO when pipelined.               *)
(*   "EJavaFlush" — CANONICAL DelayedRedirector model: head only learns    *)
(*      from its immediate next hop (host[1]) that the latter's ref-1      *)
(*      queue drained.  Local-only signal — no god-view.  Expected to      *)
(*      VIOLATE EndToEndRefFIFO when shortenEntry > 2 (kpreid concern).     *)
(*   "EJavaFlushGlobal" — UNREALISTIC strong variant kept only as a probe: *)
(*      embargo holds until OldPathClear AND NoInFlightOldPath AND          *)
(*      NoInFlightRef1 (god-view).  Shows what assumption the local        *)
(*      design is missing; should make EndToEndRefFIFO hold.                *)
(*   "OpFlushProtocol" — Ridley-style op:flush-fwd chain forwarded through *)
(*      hop = shortenEntry, then op:flush-ack to head.  Each hop's         *)
(*      precondition is only its own pending queue; ack-receive at head    *)
(*      has no global check.                                                *)
(***************************************************************************)

EXTENDS Naturals, Sequences, TLC,
        NaivePromiseResolution,
        NoPromiseResolution,
        ShorteningFlushRouting,
        PeerState

VARIABLE lastAction
VARIABLE shortenActive
VARIABLE shortenEntry
VARIABLE headPipelined
VARIABLE headEmbargo
VARIABLE opFlushPhase

CONSTANT
    NumMessages,
    ExtraOps,
    RoutingPolicy,
    DebugTrace

ASSUME NumMessages \in Nat \ {0}
ASSUME RoutingPolicy \in {
    "NaivePromiseResolution",
    "NoPromiseResolution",
    "ShorteningUnsafe",
    "EJavaFlush",
    "EJavaFlushGlobal",
    "OpFlushProtocol"
}
ASSUME DebugTrace \in BOOLEAN

----------------------------------------------------------------------------
(* Wire messages.  pos = chain position this hop targets.                   *)

OpDeliverOnly(sender, sentOnRef, seq, pos) ==
    [op |-> "op:deliver-only",
     sender |-> sender,
     sentOnRef |-> sentOnRef,
     seq |-> seq,
     pos |-> pos]

OpResolveNotify(promise) ==
    [op |-> "op:resolve-notify",
     promise |-> promise]

OpListen(subscriber, promise) ==
    [op |-> "op:listen",
     subscriber |-> subscriber,
     promise |-> promise]

(* op:flush chain: target = shortenEntry (first remote hop index after cut). *)
OpFlushFwd(target, hop) ==
    [op |-> "op:flush-fwd",
     target |-> target,
     hop |-> hop]

OpFlushAck ==
    [op |-> "op:flush-ack"]

BaseMessages ==
    { OpDeliverOnly(HeadPeer, r, n, pos) :
        r \in {1}, n \in 1..NumMessages, pos \in Refs }
    \cup { OpResolveNotify(i) : i \in PromiseRefs }
    \cup { OpListen(sub, pr) : sub \in Peers, pr \in PromiseRefs }
    \cup { OpFlushFwd(t, h) :
            t \in 2..ChainLength, h \in 1..ChainLength }
    \cup { OpFlushAck }

Messages == BaseMessages \cup ExtraOps

DeliveredEntry ==
    [sender : Peers, ref : {1}, seq : 1..NumMessages]

----------------------------------------------------------------------------

RouteSend(p, r) ==
    IF RoutingPolicy = "ShorteningUnsafe"
    THEN ShorteningFlushRouteSend(p, r, knownByPeer, host, TerminalPos,
            shortenActive, shortenEntry, headEmbargo, TRUE)
    ELSE IF RoutingPolicy \in {"EJavaFlush", "EJavaFlushGlobal",
                                "OpFlushProtocol"}
         THEN ShorteningFlushRouteSend(p, r, knownByPeer, host, TerminalPos,
                 shortenActive, shortenEntry, headEmbargo, FALSE)
    ELSE IF RoutingPolicy = "NaivePromiseResolution"
         THEN NaivePromiseResolutionRouteSend(p, r, knownByPeer, host,
                 TerminalPos)
         ELSE NoPromiseResolutionRouteSend(p, r, knownByPeer, host,
                 TerminalPos)

OnReceiveResolution(p, pr) ==
    IF RoutingPolicy = "NaivePromiseResolution"
    THEN NaivePromiseResolutionOnReceiveSeq(p, pr)
    ELSE NoPromiseResolutionOnReceiveSeq(p, pr)

vars ==
    << channels, host, resolved, knownByPeer,
       localQueues, pending, sent, delivered, lastAction,
       shortenActive, shortenEntry, headPipelined, headEmbargo, opFlushPhase >>

----------------------------------------------------------------------------

Mark(rec) ==
    IF DebugTrace THEN lastAction' = rec ELSE UNCHANGED lastAction

RECURSIVE ChannelsAfterSends(_, _)
ChannelsAfterSends(ch, sends) ==
    IF sends = << >> THEN ch
    ELSE
        LET h == Head(sends)
        IN ChannelsAfterSends(
               NetworkAppend(ch, h.from, h.to, h.msg), Tail(sends))

----------------------------------------------------------------------------
(* Shortening: choose first wire hop index k (2..ChainLength).              *)
(* Guard: promise 1 resolved and client learned it; all promises strictly *)
(* before k are resolved (chain known through k-1).                        *)

ShortenPre(k) ==
    /\ k \in 2..ChainLength
    /\ resolved[1]
    /\ knownByPeer[HeadPeer][1]
    /\ \A j \in 1..(k - 1) \cap PromiseRefs :
          /\ resolved[j]
          /\ knownByPeer[HeadPeer][j]

OldPathClear ==
    LET S == {pr \in PromiseRefs : pr < shortenEntry}
    IN \A pr \in S : Len(pending[host[pr]][pr]) = 0

NoInFlightOldPath ==
    LET bad(m) ==
          /\ m.op = "op:deliver-only"
          /\ m.sentOnRef = 1
          /\ m.pos < shortenEntry
    IN ~\E p, q \in Peers :
            \E i \in 1..Len(channels[p][q]) : bad(channels[p][q][i])

(* Any op:deliver-only for ref 1 still on a wire queue (all positions).      *)

NoInFlightRef1 ==
    ~\E p, q \in Peers :
        \E i \in 1..Len(channels[p][q]) :
            LET m == channels[p][q][i]
            IN /\ m.op = "op:deliver-only"
               /\ m.sentOnRef = 1

Shorten ==
    /\ RoutingPolicy \in {"ShorteningUnsafe", "EJavaFlush",
                          "EJavaFlushGlobal", "OpFlushProtocol"}
    /\ ~shortenActive
    /\ ~headEmbargo
    /\ opFlushPhase = "idle"
    /\ \E k \in 2..ChainLength :
         /\ ShortenPre(k)
         /\ shortenEntry' = k
         /\ UNCHANGED
                << host, resolved, knownByPeer,
                   localQueues, pending, sent, delivered, headPipelined >>
         /\ IF RoutingPolicy = "ShorteningUnsafe"
            THEN /\ shortenActive' = TRUE
                 /\ UNCHANGED << channels, headEmbargo, opFlushPhase >>
            ELSE IF RoutingPolicy \in {"EJavaFlush", "EJavaFlushGlobal"}
                 THEN IF headPipelined
                      THEN /\ headEmbargo' = TRUE
                           /\ UNCHANGED << shortenActive, channels, opFlushPhase >>
                      ELSE /\ shortenActive' = TRUE
                           /\ UNCHANGED << headEmbargo, channels, opFlushPhase >>
                 ELSE (* OpFlushProtocol *)
                      IF headPipelined
                      THEN /\ headEmbargo' = TRUE
                           /\ opFlushPhase' = "out"
                           /\ channels' =
                                   NetworkAppend(channels, HeadPeer,
                                       host[1], OpFlushFwd(k, 1))
                           /\ UNCHANGED shortenActive
                      ELSE /\ shortenActive' = TRUE
                           /\ UNCHANGED << headEmbargo, channels, opFlushPhase >>
         /\ Mark([name |-> "Shorten",
                  actor |-> HeadPeer,
                  policy |-> RoutingPolicy,
                  entry |-> k,
                  pipelined |-> headPipelined])

EJavaRelease ==
    /\ RoutingPolicy \in {"EJavaFlush", "EJavaFlushGlobal"}
    /\ headEmbargo
    /\ ~shortenActive
    (* CANONICAL "EJavaFlush": realistic DelayedRedirector signal — the
       head only learns from its immediate next hop (host[1]) that the
       latter's ref-1 queue has drained.  Cannot inspect anything past
       host[1].                                                          *)
    /\ IF RoutingPolicy = "EJavaFlush"
       THEN /\ Len(pending[host[1]][1]) = 0
       (* UNREALISTIC "EJavaFlushGlobal": god-view kept as a control —
          drain entire old path AND no ref-1 anywhere on the network.    *)
       ELSE /\ OldPathClear
            /\ NoInFlightOldPath
            /\ NoInFlightRef1
    /\ shortenActive' = TRUE
    /\ headEmbargo' = FALSE
    /\ Mark([name |-> "EJavaRelease",
             actor |-> HeadPeer,
             entry |-> shortenEntry])
    /\ UNCHANGED
           << channels, host, resolved, knownByPeer,
              localQueues, pending, sent, delivered,
              shortenEntry, headPipelined, opFlushPhase >>

----------------------------------------------------------------------------
Init ==
    /\ ReferencesInit
    /\ NetworkInit
    /\ PeerStateInit
    /\ lastAction = [name |-> "init"]
    /\ shortenActive = FALSE
    /\ shortenEntry = 2
    /\ headPipelined = FALSE
    /\ headEmbargo = FALSE
    /\ opFlushPhase = "idle"

----------------------------------------------------------------------------
PeerSend ==
    LET sender == HeadPeer
        res1 == host[1]
        r == 1
    IN
        /\ sent < NumMessages
        (* While a flush is in progress, the head must not enqueue new        *)
        (* ref-1 traffic; that would land behind the flush token on the old  *)
        (* chain and then race the post-ack shortcut at the entry vat.       *)
        /\ ~headEmbargo
        /\ LET n == sent + 1
               m == OpDeliverOnly(sender, r, n, 1)
               tag == RouteSend(sender, r)
           IN
           /\ sent' = n
           /\ headPipelined' =
                  IF RoutingPolicy \in
                         {"ShorteningUnsafe", "EJavaFlush",
                          "EJavaFlushGlobal", "OpFlushProtocol"}
                  THEN headPipelined \/ (tag = "viaResolver")
                  ELSE headPipelined
           /\ (CASE
                     tag = "local"
                       -> /\ localQueues' =
                               [localQueues EXCEPT ![sender] = Append(@,
                                   OpDeliverOnly(sender, r, n, TerminalPos))]
                          /\ UNCHANGED << channels, pending >>
                     [] tag = "viaResolver"
                       (* Always queue at the resolver's pending; never let
                          the head bypass host[1] directly to host[2]
                          (would open a second FIFO into host[2] alongside
                          ProcessPending's channels[host[1]][host[2]]).  *)
                       -> /\ pending' =
                              [pending EXCEPT
                                  ![res1] =
                                      [pending[res1] EXCEPT
                                          ![1] =
                                              Append(pending[res1][1], m)]]
                          /\ UNCHANGED channels
                          /\ UNCHANGED localQueues
                     [] tag = "shortcut"
                       -> LET mS ==
                                OpDeliverOnly(sender, r, n, shortenEntry)
                              tgtHost == host[shortenEntry]
                              hopFromS ==
                                  IF tgtHost = sender THEN res1 ELSE sender
                          IN /\ channels' =
                                  NetworkAppend(channels, hopFromS,
                                      tgtHost, mS)
                             /\ UNCHANGED pending
                             /\ UNCHANGED localQueues
                     [] OTHER -> FALSE)
           /\ UNCHANGED << host, resolved, knownByPeer, delivered,
                  shortenActive, shortenEntry, headEmbargo, opFlushPhase >>
           /\ Mark([name |-> "PeerSend",
                    actor |-> sender,
                    resolver |-> res1,
                    ref |-> r,
                    seq |-> n,
                    tag |-> tag,
                    shortenEntry |-> shortenEntry])

----------------------------------------------------------------------------
LocalDeliver ==
    \E p \in Peers :
        /\ Len(localQueues[p]) > 0
        /\ LET m == Head(localQueues[p])
           IN
           /\ m.op = "op:deliver-only"
           /\ m.pos = TerminalPos
           /\ localQueues' = [localQueues EXCEPT ![p] = Tail(@)]
           /\ delivered' =
                Append(delivered,
                       [sender |-> m.sender,
                        ref |-> m.sentOnRef,
                        seq |-> m.seq])
           /\ UNCHANGED
                  << channels, host, resolved, knownByPeer,
                     pending, sent, shortenActive, shortenEntry,
                     headPipelined, headEmbargo, opFlushPhase >>
           /\ Mark([name |-> "LocalDeliver",
                    actor |-> p,
                    seq |-> m.seq,
                    ref |-> m.sentOnRef])

----------------------------------------------------------------------------
ResolverResolve ==
    \E i \in PromiseRefs :
        /\ ~resolved[i]
        /\ LET res == host[i]
               notifyMsg == OpResolveNotify(i)
               chB ==
                   [channels EXCEPT ![res] =
                       [q \in Peers |->
                           IF q = res
                           THEN channels[res][q]
                           ELSE Append(channels[res][q], notifyMsg)]]
           IN
           /\ resolved' = [resolved EXCEPT ![i] = TRUE]
           /\ knownByPeer' = [knownByPeer EXCEPT ![res][i] = TRUE]
           /\ channels' = ChannelsAfterSends(chB, OnReceiveResolution(res, i))
           /\ UNCHANGED
                  << host, localQueues, pending, sent, delivered,
                     shortenActive, shortenEntry, headPipelined,
                     headEmbargo, opFlushPhase >>
           /\ Mark([name |-> "ResolverResolve",
                    actor |-> res,
                    promise |-> i])

----------------------------------------------------------------------------
ReceiveNetwork ==
    \E from, to \in Peers :
        /\ NetworkNonEmpty(channels, from, to)
        /\ LET msg == NetworkHead(channels, from, to)
               ch0 == NetworkTail(channels, from, to)
           IN
           \/ /\ msg.op = "op:flush-fwd"
              /\ LET t == msg.target
                     h == msg.hop
                     hopPeer == host[h]
                     prevPeer == IF h = 1 THEN HeadPeer ELSE host[h - 1]
                 IN
                    /\ to = hopPeer
                    /\ from = prevPeer
                    /\ RoutingPolicy = "OpFlushProtocol"
                    (* Ridley-style hop-by-hop drain.  Each non-terminal
                       hop drains its ref-1 pending into the downstream
                       FIFO BEFORE forwarding/acking, so the flush token
                       trails all ref-1 messages on the same
                       channels[host[h]][host[h+1]] FIFO.                 *)
                    /\ IF h = TerminalPos
                       THEN TRUE
                       ELSE Len(pending[to][h]) = 0
                    /\ IF h < t
                       (* Continue forwarding to the next hop.            *)
                       THEN /\ channels' =
                                NetworkAppend(ch0, to, host[h + 1],
                                    OpFlushFwd(t, h + 1))
                            /\ UNCHANGED
                                   << host, resolved, knownByPeer,
                                      localQueues, pending, sent,
                                      delivered, shortenActive,
                                      shortenEntry, headPipelined,
                                      headEmbargo, opFlushPhase >>
                       (* h = t: the entry vat itself.  By FIFO of the
                          incoming wire, all pre-shortening ref-1 msgs
                          have already been received at host[t] (and
                          either delivered, pending'd, or bypassed
                          downstream).  Now ack to head so its shortcut
                          on the FRESH wire channels[head][host[t]] cannot
                          race anything on channels[host[t-1]][host[t]]. *)
                       ELSE /\ channels' =
                                NetworkAppend(ch0, to, HeadPeer, OpFlushAck)
                            /\ UNCHANGED
                                   << host, resolved, knownByPeer,
                                      localQueues, pending, sent,
                                      delivered, shortenActive,
                                      shortenEntry, headPipelined,
                                      headEmbargo, opFlushPhase >>
                    /\ Mark([name |-> "ReceiveNetwork",
                             kind |-> IF h < t
                                      THEN "flush-fwd"
                                      ELSE "flush-ack-send",
                             hop |-> h,
                             target |-> t,
                             from |-> from,
                             to |-> to])
           \/ /\ msg.op = "op:flush-ack"
              /\ to = HeadPeer
              /\ RoutingPolicy = "OpFlushProtocol"
              /\ headEmbargo
              (* Local-only: receipt of the ack is itself the signal.    *)
              /\ headEmbargo' = FALSE
              /\ shortenActive' = TRUE
              /\ opFlushPhase' = "idle"
              /\ channels' = ch0
              /\ UNCHANGED
                     << host, resolved, knownByPeer,
                        localQueues, pending, sent, delivered,
                        shortenEntry, headPipelined >>
              /\ Mark([name |-> "ReceiveNetwork",
                       kind |-> "flush-ack-head",
                       from |-> from,
                       to |-> to])
           \/ /\ msg.op = "op:resolve-notify"
              /\ LET pr == msg.promise
                 IN
                 /\ knownByPeer' = [knownByPeer EXCEPT ![to][pr] = TRUE]
                 /\ channels' =
                        ChannelsAfterSends(ch0, OnReceiveResolution(to, pr))
                 /\ UNCHANGED
                        << host, resolved, localQueues,
                           pending, sent, delivered,
                           shortenActive, shortenEntry, headPipelined,
                           headEmbargo, opFlushPhase >>
                 /\ Mark([name |-> "ReceiveNetwork",
                          kind |-> "resolve-notify",
                          from |-> from,
                          to |-> to,
                          promise |-> pr])
           \/ /\ msg.op = "op:deliver-only"
              /\ to = host[msg.pos]
              /\ LET s == msg.sender
                     seq == msg.seq
                     ref == msg.sentOnRef
                     pos == msg.pos
                 IN
                 \/ /\ pos = TerminalPos
                    /\ delivered' =
                            Append(delivered,
                                   [sender |-> s, ref |-> ref, seq |-> seq])
                    /\ channels' = ch0
                    /\ UNCHANGED
                           << host, resolved, knownByPeer,
                              localQueues, pending, sent,
                              shortenActive, shortenEntry, headPipelined,
                              headEmbargo, opFlushPhase >>
                    /\ Mark([name |-> "ReceiveNetwork",
                             kind |-> "deliver-terminal",
                             from |-> from,
                             to |-> to,
                             seq |-> seq,
                             ref |-> ref])
                 \/ /\ pos \in PromiseRefs
                    /\ IF \/ ~resolved[pos]
                          \/ Len(pending[to][pos]) > 0
                       THEN /\ pending' =
                                [pending EXCEPT
                                    ![to] =
                                        [pending[to] EXCEPT
                                            ![pos] =
                                                Append(pending[to][pos],
                                                       msg)]]
                            /\ channels' = ch0
                            /\ UNCHANGED
                                   << host, resolved, knownByPeer,
                                      localQueues, sent, delivered,
                                      shortenActive, shortenEntry,
                                      headPipelined, headEmbargo,
                                      opFlushPhase >>
                            /\ Mark([name |-> "ReceiveNetwork",
                                     kind |-> "enqueue-pending",
                                     from |-> from,
                                     to |-> to,
                                     seq |-> seq,
                                     pos |-> pos])
                       ELSE LET nextPos == pos + 1
                                m2 == [msg EXCEPT !.pos = nextPos]
                            IN
                               IF nextPos = TerminalPos
                               THEN IF host[TerminalPos] = to
                                    THEN /\ delivered' =
                                             Append(delivered,
                                                    [sender |-> s,
                                                     ref |-> ref,
                                                     seq |-> seq])
                                         /\ channels' = ch0
                                         /\ UNCHANGED
                                                << host, resolved,
                                                   knownByPeer,
                                                   localQueues,
                                                   pending, sent,
                                                   shortenActive,
                                                   shortenEntry,
                                                   headPipelined,
                                                   headEmbargo,
                                                   opFlushPhase >>
                                         /\ Mark([name |-> "ReceiveNetwork",
                                                  kind |-> "forward-deliver",
                                                  from |-> from,
                                                  to |-> to,
                                                  seq |-> seq,
                                                  pos |-> pos])
                                    ELSE /\ channels' =
                                             NetworkAppend(ch0, to,
                                                 host[TerminalPos], m2)
                                         /\ UNCHANGED
                                                << host, resolved,
                                                   knownByPeer,
                                                   localQueues,
                                                   pending, sent,
                                                   delivered,
                                                   shortenActive,
                                                   shortenEntry,
                                                   headPipelined,
                                                   headEmbargo,
                                                   opFlushPhase >>
                                         /\ Mark([name |-> "ReceiveNetwork",
                                                  kind |-> "forward-wire",
                                                  from |-> from,
                                                  to |-> to,
                                                  seq |-> seq,
                                                  pos |-> pos,
                                                  nextPos |-> nextPos])
                               ELSE LET hopR ==
                                            IF host[nextPos] = to
                                            THEN HeadPeer
                                            ELSE to
                                    IN /\ channels' =
                                           NetworkAppend(ch0, hopR,
                                               host[nextPos], m2)
                                    /\ UNCHANGED
                                           << host, resolved, knownByPeer,
                                              localQueues, pending, sent,
                                              delivered,
                                              shortenActive, shortenEntry,
                                              headPipelined, headEmbargo,
                                              opFlushPhase >>
                                    /\ Mark([name |-> "ReceiveNetwork",
                                             kind |-> "forward-wire",
                                             from |-> from,
                                             to |-> to,
                                             seq |-> seq,
                                             pos |-> pos,
                                             nextPos |-> nextPos])

----------------------------------------------------------------------------
ProcessPending ==
    \E q \in Peers, pr \in PromiseRefs :
        /\ Len(pending[q][pr]) > 0
        /\ resolved[pr]
        /\ LET m == Head(pending[q][pr])
               nextPos == pr + 1
               m2 == [m EXCEPT !.pos = nextPos]
           IN
           /\ m.op = "op:deliver-only"
           /\ pending' =
                [pending EXCEPT
                    ![q] =
                        [pending[q] EXCEPT ![pr] = Tail(pending[q][pr])]]
           /\ IF nextPos = TerminalPos
              THEN IF host[TerminalPos] = q
                   THEN /\ delivered' =
                             Append(delivered,
                                    [sender |-> m.sender,
                                     ref |-> m.sentOnRef,
                                     seq |-> m.seq])
                        /\ UNCHANGED channels
                   ELSE /\ channels' =
                             NetworkAppend(channels, q,
                                 host[TerminalPos], m2)
                        /\ UNCHANGED delivered
              ELSE LET hopQ ==
                           IF host[nextPos] = q THEN HeadPeer ELSE q
                   IN /\ channels' =
                           NetworkAppend(channels, hopQ, host[nextPos], m2)
                   /\ UNCHANGED delivered
           /\ UNCHANGED << host, resolved, knownByPeer, localQueues, sent,
                  shortenActive, shortenEntry, headPipelined, headEmbargo,
                  opFlushPhase >>
           /\ Mark([name |-> "ProcessPending",
                    actor |-> q,
                    promise |-> pr,
                    seq |-> m.seq,
                    nextPos |-> pr + 1])

ProtocolNextExtra ==
    \/ Shorten
    \/ EJavaRelease

----------------------------------------------------------------------------
BasicNext ==
    \/ PeerSend
    \/ LocalDeliver
    \/ ResolverResolve
    \/ ReceiveNetwork
    \/ ProcessPending

Next == BasicNext \/ ProtocolNextExtra

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
TypeOK ==
    LET NetT == NetworkChannelsType(Messages)
    IN
        /\ ReferencesTypeOK
        /\ channels \in NetT
        /\ PeerStateTypeOK(Messages, DeliveredEntry, NumMessages)
        /\ shortenActive \in BOOLEAN
        /\ shortenEntry \in 2..ChainLength
        /\ headPipelined \in BOOLEAN
        /\ headEmbargo \in BOOLEAN
        /\ opFlushPhase \in {"idle", "out"}
        /\ \A from, to \in Peers :
                \A i \in 1..Len(channels[from][to]) :
                    channels[from][to][i] \in Messages

----------------------------------------------------------------------------
EndToEndRefFIFO ==
    \A sender \in Peers, ref \in {1} :
        LET seqs ==
            SelectSeq(delivered,
                LAMBDA d : d.sender = sender /\ d.ref = ref)
        IN
            \A i \in 1..(Len(seqs) - 1) : seqs[i].seq < seqs[i + 1].seq

============================================================================
