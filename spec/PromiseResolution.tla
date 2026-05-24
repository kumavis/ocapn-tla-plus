------------------------- MODULE PromiseResolution -------------------------
(***************************************************************************)
(* OCapN-flavored model of pipelined op:deliver-only on a promise,         *)
(* promise *resolution* to a remotable object, and per-pair FIFO transport. *)
(*                                                                         *)
(* Routing policy is selected by CONSTANT RoutingPolicy (see MC modules):  *)
(*   "NaivePromiseResolution" - NaivePromiseResolution.tla                  *)
(*   "NoPromiseResolution"    - NoPromiseResolution.tla                     *)
(*                                                                         *)
(* op:resolve-notify is modeled as a wire message that the resolver        *)
(* enqueues to every other peer at the moment of resolution (broadcast).   *)
(* See README "Variant ideas" for a planned op:listen-based variant.       *)
(***************************************************************************)

EXTENDS Naturals, Sequences, TLC,
        NaivePromiseResolution,
        NoPromiseResolution,
        PeerState

CONSTANT
    NumMessages,
    ExtraOps,
    RoutingPolicy

ASSUME NumMessages \in Nat \ {0}
ASSUME RoutingPolicy \in {"NaivePromiseResolution", "NoPromiseResolution"}

----------------------------------------------------------------------------
(* OCapN-shaped wire messages.                                              *)

OpDeliverOnly(sender, sentOnRef, seq) ==
    [op |-> "op:deliver-only",
     sender |-> sender,
     sentOnRef |-> sentOnRef,
     seq |-> seq]

OpResolveNotify(promise, resolvedTo) ==
    [op |-> "op:resolve-notify",
     promise |-> promise,
     resolvedTo |-> resolvedTo]

OpListen(subscriber, promise) ==
    [op |-> "op:listen",
     subscriber |-> subscriber,
     promise |-> promise]

BaseMessages ==
    { OpDeliverOnly(p, r, n) :
        p \in Peers, r \in RefSpace, n \in 1..NumMessages }
    \cup { OpResolveNotify(pr, tgt) :
        pr \in Promises, tgt \in Objects }
    \cup { OpListen(sub, pr) :
        sub \in Peers, pr \in Promises }

Messages == BaseMessages \cup ExtraOps

DeliveredEntry ==
    [sender : Peers, ref : RefSpace, seq : 1..NumMessages]

----------------------------------------------------------------------------
(* Protocol hooks: dispatch by RoutingPolicy.                               *)

RouteSend(p, r, n) ==
    IF RoutingPolicy = "NaivePromiseResolution"
    THEN NaivePromiseResolutionRouteSend(p, r, n, knownByPeer, resolution,
            objHost, promResolver, Objects, Promises, UNRESOLVED)
    ELSE NoPromiseResolutionRouteSend(p, r, n, knownByPeer, resolution,
            objHost, promResolver, Objects, Promises, UNRESOLVED)

OnReceiveResolution(p, pr, tgt) ==
    IF RoutingPolicy = "NaivePromiseResolution"
    THEN NaivePromiseResolutionOnReceiveSeq(p, pr, tgt)
    ELSE NoPromiseResolutionOnReceiveSeq(p, pr, tgt)

ProtocolNextExtra ==
    FALSE

vars ==
    << channels, objHost, promResolver, resolution, knownByPeer,
       localQueues, pending, sent, delivered >>

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

----------------------------------------------------------------------------
(* Peer emits the next op:deliver-only on some reference, tagged with the   *)
(* monotonic per-(peer, ref) sequence number used to check ordering.        *)
(* PeerSend does not gate on knownByPeer — promise sends may be pipelined   *)
(* before resolution.                                                       *)

PeerSend ==
    \E p \in Peers, r \in RefSpace :
        /\ sent[p][r] < NumMessages
        /\ LET n == sent[p][r] + 1
               m == OpDeliverOnly(p, r, n)
               tag == RouteSend(p, r, n)
           IN
           /\ sent' = [sent EXCEPT ![p][r] = n]
           /\ (CASE
                     tag = "local"
                       -> /\ localQueues' =
                               [localQueues EXCEPT ![p] = Append(@, m)]
                          /\ UNCHANGED << channels, pending >>
                     [] (tag = "viaResolver") /\ IsPromise(r)
                       -> LET prx == r
                              rp == promResolver[prx] IN
                              /\ IF rp = p
                                 THEN /\ pending' =
                                             [pending EXCEPT
                                                 ![p] =
                                                     [pending[p] EXCEPT
                                                         ![prx] =
                                                             Append(pending[p][prx],
                                                                    m)]]
                                      /\ UNCHANGED channels
                                 ELSE /\ channels' =
                                             NetworkAppend(channels, p, rp, m)
                                      /\ UNCHANGED pending
                              /\ UNCHANGED localQueues
                     [] (tag = "viaTerminal") /\ IsObject(r)
                       -> LET h == objHost[r] IN
                              /\ IF h = p
                                 THEN /\ localQueues' =
                                             [localQueues EXCEPT ![p] = Append(@, m)]
                                      /\ UNCHANGED channels
                                 ELSE /\ channels' =
                                             NetworkAppend(channels, p, h, m)
                                      /\ UNCHANGED localQueues
                              /\ UNCHANGED pending
                     [] OTHER -> FALSE)
           /\ UNCHANGED
                  << objHost, promResolver, resolution, knownByPeer,
                     delivered >>

----------------------------------------------------------------------------
LocalDeliver ==
    \E p \in Peers :
        /\ Len(localQueues[p]) > 0
        /\ LET m == Head(localQueues[p])
           IN
           /\ m.op = "op:deliver-only"
           /\ localQueues' = [localQueues EXCEPT ![p] = Tail(@)]
           /\ delivered' =
                Append(delivered,
                       [sender |-> m.sender,
                        ref    |-> m.sentOnRef,
                        seq    |-> m.seq])
           /\ UNCHANGED
                  << channels, objHost, promResolver, resolution,
                     knownByPeer, pending, sent >>

----------------------------------------------------------------------------
ResolverResolve ==
    \E res \in Peers, pr \in Promises :
        /\ promResolver[pr] = res
        /\ resolution[pr] = UNRESOLVED
        /\ \E tgt \in Objects :
            LET notifyMsg == OpResolveNotify(pr, tgt)
                chB ==
                    [channels EXCEPT ![res] =
                        [q \in Peers |->
                            IF q = res
                            THEN channels[res][q]
                            ELSE Append(channels[res][q], notifyMsg)]]
            IN
            /\ resolution' = [resolution EXCEPT ![pr] = tgt]
            /\ knownByPeer' = [knownByPeer EXCEPT ![res][pr] = TRUE]
            /\ channels' = ChannelsAfterSends(chB, OnReceiveResolution(res, pr, tgt))
            /\ UNCHANGED
                   << objHost, promResolver, localQueues, pending, sent,
                      delivered >>

----------------------------------------------------------------------------
(* Network receive: promise delivers at the resolver are queued whenever     *)
(* the promise is still unresolved OR there is already backlog in pending,  *)
(* so a resolved promise cannot "jump" ahead of an older op still in        *)
(* pending.                                                                 *)
ReceiveNetwork ==
    \E from, to \in Peers :
        /\ NetworkNonEmpty(channels, from, to)
        /\ LET msg == NetworkHead(channels, from, to)
               ch0 == NetworkTail(channels, from, to)
           IN
           \/ /\ msg.op = "op:resolve-notify"
              /\ LET pr == msg.promise
                     tgt == msg.resolvedTo
                 IN
                 /\ knownByPeer' = [knownByPeer EXCEPT ![to][pr] = TRUE]
                 /\ channels' =
                        ChannelsAfterSends(ch0,
                            OnReceiveResolution(to, pr, tgt))
                 /\ UNCHANGED
                        << objHost, promResolver, resolution, localQueues,
                           pending, sent, delivered >>
           \/ /\ msg.op = "op:deliver-only"
              /\ LET s == msg.sender
                     r == msg.sentOnRef
                     seq == msg.seq
                 IN
                 \/ /\ IsObject(r)
                    /\ objHost[r] = to
                    /\ delivered' =
                            Append(delivered,
                                   [sender |-> s, ref |-> r, seq |-> seq])
                    /\ channels' = ch0
                    /\ UNCHANGED
                           << objHost, promResolver, resolution, knownByPeer,
                              localQueues, pending, sent >>
                 \/ /\ IsPromise(r)
                    /\ LET pr == r IN
                       IF to = promResolver[pr]
                       THEN
                           IF \/ resolution[pr] = UNRESOLVED
                              \/ Len(pending[to][pr]) > 0
                           THEN
                               /\ pending' =
                                    [pending EXCEPT
                                        ![to] =
                                            [pending[to] EXCEPT
                                                ![pr] =
                                                    Append(pending[to][pr],
                                                           msg)]]
                               /\ channels' = ch0
                               /\ UNCHANGED
                                      << objHost, promResolver, resolution,
                                         knownByPeer, localQueues, sent,
                                         delivered >>
                           ELSE
                               LET term == TerminalRef(pr) IN
                                   /\ resolution[pr] # UNRESOLVED
                                   /\ IsObject(term)
                                   /\ IF objHost[term] = to
                                      THEN /\ delivered' =
                                               Append(delivered,
                                                      [sender |-> s,
                                                       ref    |-> pr,
                                                       seq    |-> seq])
                                           /\ channels' = ch0
                                           /\ UNCHANGED
                                                  << objHost, promResolver,
                                                     resolution, knownByPeer,
                                                     localQueues, pending,
                                                     sent >>
                                      ELSE /\ channels' =
                                               NetworkAppend(ch0, to,
                                                   objHost[term], msg)
                                           /\ UNCHANGED
                                                  << objHost, promResolver,
                                                     resolution, knownByPeer,
                                                     localQueues, pending,
                                                     sent, delivered >>
                       ELSE IF resolution[pr] # UNRESOLVED
                            THEN
                                LET term == TerminalRef(pr) IN
                                    /\ IsObject(term)
                                    /\ IF objHost[term] = to
                                       THEN /\ delivered' =
                                                Append(delivered,
                                                       [sender |-> s,
                                                        ref    |-> pr,
                                                        seq    |-> seq])
                                            /\ channels' = ch0
                                            /\ UNCHANGED
                                                   << objHost, promResolver,
                                                      resolution, knownByPeer,
                                                      localQueues, pending,
                                                      sent >>
                                       ELSE /\ channels' =
                                                NetworkAppend(ch0, to,
                                                    objHost[term], msg)
                                            /\ UNCHANGED
                                                   << objHost, promResolver,
                                                      resolution, knownByPeer,
                                                      localQueues, pending,
                                                      sent, delivered >>
                            ELSE FALSE

----------------------------------------------------------------------------
ProcessPending ==
    \E q \in Peers, pr \in Promises :
        /\ Len(pending[q][pr]) > 0
        /\ resolution[pr] # UNRESOLVED
        /\ LET m == Head(pending[q][pr])
               term == TerminalRef(pr)
           IN
           /\ m.op = "op:deliver-only"
           /\ pending' =
                [pending EXCEPT
                    ![q] =
                        [pending[q] EXCEPT ![pr] = Tail(pending[q][pr])]]
           /\ IsObject(term)
           /\ IF objHost[term] = q
              THEN /\ delivered' =
                        Append(delivered,
                               [sender |-> m.sender,
                                ref    |-> m.sentOnRef,
                                seq    |-> m.seq])
                   /\ UNCHANGED channels
              ELSE /\ channels' =
                        NetworkAppend(channels, q, objHost[term], m)
                   /\ UNCHANGED delivered
           /\ UNCHANGED
                  << objHost, promResolver, resolution, knownByPeer,
                     localQueues, sent >>

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
(* strictly increasing send order for that same reference.  No claim        *)
(* across different senders or different references.                        *)

EndToEndRefFIFO ==
    \A sender \in Peers, ref \in RefSpace :
        LET seqs ==
            SelectSeq(delivered,
                LAMBDA d : d.sender = sender /\ d.ref = ref)
        IN
            \A i \in 1..(Len(seqs) - 1) : seqs[i].seq < seqs[i + 1].seq

============================================================================
