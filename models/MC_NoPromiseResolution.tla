---------------------- MODULE MC_NoPromiseResolution ----------------------
(***************************************************************************)
(* Model-check PromiseResolution under NoPromiseResolution routing: every   *)
(* op:deliver-only on a promise always goes via the resolver (no local      *)
(* shortcut after learning resolution).                                     *)
(*                                                                         *)
(* Sized to match the two-party failure-case witness for                    *)
(* MC_NaivePromiseResolution (NumMessages = 3).  Expected: TypeOK_MC and    *)
(* EndToEndRefFIFO_MC both hold; full state-space exploration runs to       *)
(* completion (large; takes minutes).                                       *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"p1", "p2"}
Objects == {"o1"}
Promises == {"pr1"}
NumMessages == 3
ExtraOps == {}
UNRESOLVED == "UNR"
RoutingPolicy == "NoPromiseResolution"

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
