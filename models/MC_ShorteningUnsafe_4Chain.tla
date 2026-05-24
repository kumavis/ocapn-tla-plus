------------------- MODULE MC_ShorteningUnsafe_4Chain -------------------
(***************************************************************************)
(* ChainLength = 4 (three promises + terminal), four distinct peers.       *)
(* Unsafe promise shortening: Shorten may fire after resolved[1]..[k-1];   *)
(* then shortcut sends skip intermediaries — breaks EndToEndRefFIFO when   *)
(* pipelined op:deliver-only still in flight (cf. ocapn/ocapn#11).          *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC", "vatD", "vatE"}
HeadPeer == "vatA"
ChainLength == 4
NumMessages == 5
ExtraOps == {}
RoutingPolicy == "ShorteningUnsafe"
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

Init ==
    /\ PS!Init
    /\ host = <<"vatB", "vatC", "vatD", "vatE">>

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
