--------------------- MODULE MC_NaivePromiseResolution ---------------------
(***************************************************************************)
(* Model-check PromiseResolution under NaivePromiseResolution routing.     *)
(* Topology (hosts / resolvers) and interleavings are left to TLC; only    *)
(* sizes are fixed here.                                                    *)
(*                                                                         *)
(* Expected: EndToEndRefFIFO_MC is *violated* (two-party post-resolution    *)
(* local shortcut races in-flight pipelined messages).                     *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"p1", "p2"}
Objects == {"o1"}
Promises == {"pr1"}
NumMessages == 3
ExtraOps == {}
UNRESOLVED == "UNR"
RoutingPolicy == "NaivePromiseResolution"

VARIABLES
    channels,
    objHost,
    promResolver,
    resolution,
    knownByPeer,
    localQueues,
    pending,
    sent,
    delivered

vars ==
    << channels, objHost, promResolver, resolution, knownByPeer,
       localQueues, pending, sent, delivered >>

PS ==
    INSTANCE PromiseResolution WITH
        Peers <- Peers,
        Objects <- Objects,
        Promises <- Promises,
        UNRESOLVED <- UNRESOLVED,
        NumMessages <- NumMessages,
        ExtraOps <- ExtraOps,
        RoutingPolicy <- RoutingPolicy,
        channels <- channels,
        objHost <- objHost,
        promResolver <- promResolver,
        resolution <- resolution,
        knownByPeer <- knownByPeer,
        localQueues <- localQueues,
        pending <- pending,
        sent <- sent,
        delivered <- delivered

Init == PS!Init

Next == PS!Next

Spec == Init /\ [][Next]_vars

TypeOK_MC == PS!TypeOK

EndToEndRefFIFO_MC == PS!EndToEndRefFIFO

============================================================================
