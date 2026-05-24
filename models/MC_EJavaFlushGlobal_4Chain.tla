-------------------- MODULE MC_EJavaFlushGlobal_4Chain --------------------
(***************************************************************************)
(* Same topology as MC_EJavaFlush_4Chain, but RoutingPolicy is the UN-      *)
(* REALISTIC strong control variant: EJavaRelease waits on the god-view    *)
(* preconditions OldPathClear + NoInFlightOldPath + NoInFlightRef1.  Kept  *)
(* only as a minimal contrast to the canonical (local) EJavaFlush — shows *)
(* exactly which extra assumption the local DelayedRedirector is missing.  *)
(* Expected: EndToEndRefFIFO_MC holds.                                     *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC", "vatD", "vatE"}
HeadPeer == "vatA"
ChainLength == 4
NumMessages == 3
ExtraOps == {}
RoutingPolicy == "EJavaFlushGlobal"
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
