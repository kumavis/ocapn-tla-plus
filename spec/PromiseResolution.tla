------------------------- MODULE PromiseResolution -------------------------
(***************************************************************************)
(* OCapN-flavored model: linear ref-chain (1..ChainLength), per-pair FIFO   *)
(* transport, pipelined op:deliver-only originated only at CONSTANT HeadPeer *)
(* on ref 1.  Promise i resolves implicitly to i+1; host[i] holds the      *)
(* resolver for promise i (HeadPeer may differ from host[1]).              *)
(*                                                                         *)
(* RoutingPolicy CONSTANT: "NaivePromiseResolution" | "NoPromiseResolution" *)
(* DebugTrace CONSTANT: when TRUE, lastAction records the last fired step. *)
(***************************************************************************)

EXTENDS Naturals, Sequences, TLC,
        NaivePromiseResolution,
        NoPromiseResolution,
        PeerState

VARIABLE lastAction

CONSTANT
    NumMessages,
    ExtraOps,
    RoutingPolicy,
    DebugTrace

ASSUME NumMessages \in Nat \ {0}
ASSUME RoutingPolicy \in {"NaivePromiseResolution", "NoPromiseResolution"}
ASSUME DebugTrace \in BOOLEAN

----------------------------------------------------------------------------
(* OCapN-shaped wire messages.  pos = chain position this hop is delivered   *)
(* to (resolver of promise pos, or terminal when pos = ChainLength).         *)

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

BaseMessages ==
    { OpDeliverOnly(HeadPeer, r, n, pos) :
        r \in {1}, n \in 1..NumMessages, pos \in Refs }
    \cup { OpResolveNotify(i) : i \in PromiseRefs }
    \cup { OpListen(sub, pr) : sub \in Peers, pr \in PromiseRefs }

Messages == BaseMessages \cup ExtraOps

DeliveredEntry ==
    [sender : Peers, ref : {1}, seq : 1..NumMessages]

----------------------------------------------------------------------------
(* Protocol hooks: dispatch by RoutingPolicy.                               *)

RouteSend(p, r) ==
    IF RoutingPolicy = "NaivePromiseResolution"
    THEN NaivePromiseResolutionRouteSend(p, r, knownByPeer, host, TerminalPos)
    ELSE NoPromiseResolutionRouteSend(p, r, knownByPeer, host, TerminalPos)

OnReceiveResolution(p, pr) ==
    IF RoutingPolicy = "NaivePromiseResolution"
    THEN NaivePromiseResolutionOnReceiveSeq(p, pr)
    ELSE NoPromiseResolutionOnReceiveSeq(p, pr)

ProtocolNextExtra ==
    FALSE

vars ==
    << channels, host, resolved, knownByPeer,
       localQueues, pending, sent, delivered, lastAction >>

----------------------------------------------------------------------------
(* Debug: structured last step (only lastAction' varies when DebugTrace).  *)

Mark(rec) ==
    IF DebugTrace THEN lastAction' = rec ELSE UNCHANGED lastAction

----------------------------------------------------------------------------
(* Applying a finite sequence of extra sends returned by a protocol hook.   *)

RECURSIVE ChannelsAfterSends(_, _)
ChannelsAfterSends(ch, sends) ==
    IF sends = << >> THEN ch
    ELSE
        LET h == Head(sends)
        IN ChannelsAfterSends(
               NetworkAppend(ch, h.from, h.to, h.msg), Tail(sends))

----------------------------------------------------------------------------
Init ==
    /\ ReferencesInit
    /\ NetworkInit
    /\ PeerStateInit
    /\ lastAction = [name |-> "init"]

----------------------------------------------------------------------------
(* Head peer emits op:deliver-only on ref 1 with monotonic seq.             *)

PeerSend ==
    LET sender == HeadPeer
        res1 == host[1]
        r == 1
    IN
        /\ sent < NumMessages
        /\ LET n == sent + 1
               m == OpDeliverOnly(sender, r, n, 1)
               tag == RouteSend(sender, r)
           IN
           /\ sent' = n
           /\ (CASE
                     tag = "local"
                       -> /\ localQueues' =
                               [localQueues EXCEPT ![sender] = Append(@,
                                   OpDeliverOnly(sender, r, n, TerminalPos))]
                          /\ UNCHANGED << channels, pending >>
                     [] tag = "viaResolver"
                       -> IF \/ ~resolved[1]
                             \/ Len(pending[res1][1]) > 0
                          THEN /\ pending' =
                                   [pending EXCEPT
                                       ![res1] =
                                           [pending[res1] EXCEPT
                                               ![1] =
                                                   Append(pending[res1][1],
                                                          m)]]
                               /\ UNCHANGED channels
                               /\ UNCHANGED localQueues
                          ELSE LET nextPos == 2
                                   m2 ==
                                       OpDeliverOnly(sender, r, n, nextPos)
                                   nxtHost == host[nextPos]
                                   (* If the next hop is the same vat as the sender, do not open a
                                      second FIFO (channels[sender][sender]) alongside e.g.
                                      channels[resolver][sender]; TLC could ReceiveNetwork them
                                      out of order.  Route the forward via the resolver link instead. *)
                                   hopFrom ==
                                       IF nxtHost = sender THEN res1 ELSE sender
                               IN /\ channels' =
                                       NetworkAppend(channels, hopFrom,
                                           nxtHost, m2)
                                  /\ UNCHANGED pending
                                  /\ UNCHANGED localQueues
                     [] OTHER -> FALSE)
           /\ UNCHANGED << host, resolved, knownByPeer, delivered >>
           /\ Mark([name |-> "PeerSend",
                    actor |-> sender,
                    resolver |-> res1,
                    ref |-> r,
                    seq |-> n,
                    tag |-> tag])

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
                     pending, sent >>
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
                  << host, localQueues, pending, sent, delivered >>
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
           \/ /\ msg.op = "op:resolve-notify"
              /\ LET pr == msg.promise
                 IN
                 /\ knownByPeer' = [knownByPeer EXCEPT ![to][pr] = TRUE]
                 /\ channels' =
                        ChannelsAfterSends(ch0, OnReceiveResolution(to, pr))
                 /\ UNCHANGED
                        << host, resolved, localQueues,
                           pending, sent, delivered >>
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
                              localQueues, pending, sent >>
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
                                      localQueues, sent, delivered >>
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
                                                   pending, sent >>
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
                                                   delivered >>
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
                                              delivered >>
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
           /\ UNCHANGED << host, resolved, knownByPeer, localQueues, sent >>
           /\ Mark([name |-> "ProcessPending",
                    actor |-> q,
                    promise |-> pr,
                    seq |-> m.seq,
                    nextPos |-> pr + 1])

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
        /\ \A from, to \in Peers :
                \A i \in 1..Len(channels[from][to]) :
                    channels[from][to][i] \in Messages

----------------------------------------------------------------------------
(* Per-(sender peer, reference): op:deliver-only deliveries appear in       *)
(* strictly increasing send order for that same reference.                    *)

EndToEndRefFIFO ==
    \A sender \in Peers, ref \in {1} :
        LET seqs ==
            SelectSeq(delivered,
                LAMBDA d : d.sender = sender /\ d.ref = ref)
        IN
            \A i \in 1..(Len(seqs) - 1) : seqs[i].seq < seqs[i + 1].seq

============================================================================
