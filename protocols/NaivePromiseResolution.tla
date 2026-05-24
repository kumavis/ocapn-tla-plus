------------------------ MODULE NaivePromiseResolution ------------------------
(***************************************************************************)
(* Naive routing after promise *resolution* (not full shortening): once a   *)
(* peer learns resolutions along the chain from some promise r onward,     *)
(* op:deliver-only on r may go locally if the terminal object is on that     *)
(* peer.  Used here with r = 1 and p = host[1] (sole op:deliver-only sender).*)
(*                                                                         *)
(* Operators are stateless; PromiseResolution closes over variables.        *)
(***************************************************************************)

EXTENDS Naturals, Sequences

RECURSIVE DeepestKnownRec(_, _, _, _)
DeepestKnownRec(p, r, kbp, terminalPos) ==
    IF r = terminalPos
    THEN terminalPos
    ELSE IF ~kbp[p][r]
    THEN r
    ELSE DeepestKnownRec(p, r + 1, kbp, terminalPos)

(* Routing tag consumed by PromiseResolution.PeerSend.                     *)
NaivePromiseResolutionRouteSend(p, r, knownByPeer, host, terminalPos) ==
    LET deepest == DeepestKnownRec(p, r, knownByPeer, terminalPos)
    IN IF /\ deepest = terminalPos
          /\ host[terminalPos] = p
       THEN "local"
       ELSE "viaResolver"

(* Sequence of extra channel sends [from |-> .., to |-> .., msg |-> ..].   *)
NaivePromiseResolutionOnReceiveSeq(p, pr) == <<>>

============================================================================
