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
    lastAction,
    shortenActive,
    shortenEntry,
    headPipelined,
    headEmbargo,
    opFlushPhase

vars ==
    << channels, host, resolved, knownByPeer,
       localQueues, pending, sent, delivered, lastAction,
       shortenActive, shortenEntry, headPipelined, headEmbargo, opFlushPhase >>

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
        lastAction <- lastAction,
        shortenActive <- shortenActive,
        shortenEntry <- shortenEntry,
        headPipelined <- headPipelined,
        headEmbargo <- headEmbargo,
        opFlushPhase <- opFlushPhase

Init == PS!Init

Next ==
    \/ PS!PeerSend
    \/ PS!LocalDeliver
    \/ PS!ResolverResolve
    \/ PS!ReceiveNetwork
    \/ PS!ProcessPending
    \/ PS!Shorten
    \/ PS!EJavaRelease

Spec == Init /\ [][Next]_vars

TypeOK_MC == PS!TypeOK

EndToEndRefFIFO_MC == PS!EndToEndRefFIFO

============================================================================
