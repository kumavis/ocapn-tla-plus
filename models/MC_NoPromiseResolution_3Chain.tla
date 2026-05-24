------------------ MODULE MC_NoPromiseResolution_3Chain ------------------
(***************************************************************************)
(* Three-position chain (two promises + terminal) on two peers.            *)
(* NumMessages = 2 to keep exploration tractable.                         *)
(* Expected: TypeOK_MC and EndToEndRefFIFO_MC hold.                         *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB"}
HeadPeer == "vatA"
ChainLength == 3
NumMessages == 2
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
