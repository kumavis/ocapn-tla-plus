------------------------ MODULE NaivePromiseResolution ------------------------
(***************************************************************************)
(* Naive routing after promise *resolution* (not full shortening): once a   *)
(* peer learns a promise's resolution, op:deliver-only on that promise may  *)
(* go locally if the terminal object is on that peer; otherwise traffic     *)
(* still goes via the resolver.                                             *)
(*                                                                         *)
(* Broader "shortening" (e.g. promise-resolves-to-promise / chain shorten)  *)
(* is out of scope here and can be a separate protocol module later.       *)
(*                                                                         *)
(* Operators are stateless; PromiseResolution closes over variables.        *)
(***************************************************************************)

EXTENDS Naturals, Sequences

IsObj(r, Objects) == r \in Objects
IsPr(r, Promises) == r \in Promises

RECURSIVE Tr(_, _, _, _, _)
Tr(resMap, r, Objects, Promises, UNRESOLVED) ==
    IF IsObj(r, Objects) THEN r
    ELSE
        IF resMap[r] = UNRESOLVED THEN r
        ELSE Tr(resMap, resMap[r], Objects, Promises, UNRESOLVED)

HostTerm(resMap, objH, promR, r, Objects, Promises, UNRESOLVED) ==
    LET t == Tr(resMap, r, Objects, Promises, UNRESOLVED) IN
        IF IsObj(t, Objects) THEN objH[t] ELSE promR[t]

(* Routing tag consumed by PromiseResolution.PeerSend.                     *)
NaivePromiseResolutionRouteSend(p, r, n, knownByPeer, resMap, objH, promR,
                                Objects, Promises, UNRESOLVED) ==
    IF IsPr(r, Promises)
    THEN
        IF /\ knownByPeer[p][r]
           /\ HostTerm(resMap, objH, promR, r, Objects, Promises, UNRESOLVED) = p
        THEN "local"
        ELSE "viaResolver"
    ELSE
        IF /\ IsObj(r, Objects) /\ objH[r] = p
        THEN "local"
        ELSE "viaTerminal"

(* Sequence of extra channel sends [from |-> .., to |-> .., msg |-> ..].   *)
NaivePromiseResolutionOnReceiveSeq(p, pr, tgt) == <<>>

============================================================================
