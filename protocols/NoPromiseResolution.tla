------------------------ MODULE NoPromiseResolution ------------------------
(***************************************************************************)
(* No post-resolution path change: every op:deliver-only on a promise is    *)
(* always pipelined via the resolver (same wire path before and after       *)
(* resolution).  There is no "learn resolution then shortcut locally"      *)
(* optimization.                                                            *)
(*                                                                         *)
(* Operators are stateless; PromiseResolution closes over variables.        *)
(* No local helpers — avoid name clashes when PromiseResolution EXTENDS     *)
(* NaivePromiseResolution as well.                                         *)
(***************************************************************************)

EXTENDS Naturals, Sequences

(* Routing tag consumed by PromiseResolution.PeerSend.                     *)
NoPromiseResolutionRouteSend(p, r, n, knownByPeer, resMap, objH, promR,
                             Objects, Promises, UNRESOLVED) ==
    IF r \in Promises
    THEN "viaResolver"
    ELSE
        IF /\ r \in Objects /\ objH[r] = p
        THEN "local"
        ELSE "viaTerminal"

(* Sequence of extra channel sends [from |-> .., to |-> .., msg |-> ..].   *)
NoPromiseResolutionOnReceiveSeq(p, pr, tgt) == <<>>

============================================================================
