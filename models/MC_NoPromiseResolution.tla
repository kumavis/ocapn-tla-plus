---------------------- MODULE MC_NoPromiseResolution ----------------------
(***************************************************************************)
(* Model-check PromiseResolution under NoPromiseResolution routing.         *)
(* Same sizes as MC_NaivePromiseResolution (NumMessages = 3).              *)
(* Expected: both invariants hold; full state space is large.              *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB"}
HeadPeer == "vatA"
ChainLength == 2
NumMessages == 3
ExtraOps == {}
RoutingPolicy == "NoPromiseResolution"
DebugTrace == FALSE

VARIABLES
    channels,
    host,
    resolved,
    knownByPeer,
    localQueues,
    pending,
    sent,
    delivered,
    lastAction

vars ==
    << channels, host, resolved, knownByPeer,
       localQueues, pending, sent, delivered, lastAction >>

PS ==
    INSTANCE PromiseResolution WITH
        Peers <- Peers,
        HeadPeer <- HeadPeer,
        ChainLength <- ChainLength,
        NumMessages <- NumMessages,
        ExtraOps <- ExtraOps,
        RoutingPolicy <- RoutingPolicy,
        DebugTrace <- DebugTrace,
        channels <- channels,
        host <- host,
        resolved <- resolved,
        knownByPeer <- knownByPeer,
        localQueues <- localQueues,
        pending <- pending,
        sent <- sent,
        delivered <- delivered,
        lastAction <- lastAction

Init == PS!Init

Next ==
    \/ PS!PeerSend
    \/ PS!LocalDeliver
    \/ PS!ResolverResolve
    \/ PS!ReceiveNetwork
    \/ PS!ProcessPending

Spec == Init /\ [][Next]_vars

TypeOK_MC == PS!TypeOK

EndToEndRefFIFO_MC == PS!EndToEndRefFIFO

============================================================================
