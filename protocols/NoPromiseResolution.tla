------------------------ MODULE NoPromiseResolution ------------------------
(***************************************************************************)
(* No post-resolution path change: every op:deliver-only on a promise is    *)
(* always pipelined via the resolver (no local shortcut after learning       *)
(* resolution).                                                             *)
(*                                                                         *)
(* Operators are stateless; PromiseResolution closes over variables.        *)
(***************************************************************************)

EXTENDS Naturals, Sequences

(* Routing tag consumed by PromiseResolution.PeerSend.                     *)
NoPromiseResolutionRouteSend(p, r, knownByPeer, host, terminalPos) ==
    "viaResolver"

(* Sequence of extra channel sends [from |-> .., to |-> .., msg |-> ..].   *)
NoPromiseResolutionOnReceiveSeq(p, pr) == <<>>

============================================================================
