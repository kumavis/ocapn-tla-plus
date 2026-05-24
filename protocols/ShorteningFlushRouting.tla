-------------------- MODULE ShorteningFlushRouting --------------------
(***************************************************************************)
(* Routing tags for PromiseResolution when RoutingPolicy enables            *)
(* promise-chain shortening + optional flush discipline.                    *)
(*                                                                         *)
(* "viaResolver" — queue / forward through host[1] on ref 1 (safe path).   *)
(* "local"       — same as naive: terminal on sender, fully known.         *)
(* "shortcut"    — wire directly to host[shortenEntry] with pos=shortenEntry *)
(*                 (unsafe unless flush / embargo cleared first).         *)
(*                                                                         *)
(* headEmbargo=TRUE forces viaResolver so the client does not take a        *)
(* shortened path while old pipelined bytes may still be in flight          *)
(* (E-on-Java-style sender delay, op:flush-style barrier).                *)
(***************************************************************************)

EXTENDS Naturals, Sequences, NaivePromiseResolution, NoPromiseResolution

(* DeepestKnownRec comes from NaivePromiseResolution (same chain walk).     *)

ShorteningFlushRouteSend(p, r, kbp, host, terminalPos,
                         shortenActive, shortenEntry, headEmbargo,
                         naiveBeforeShorten) ==
    IF headEmbargo
    THEN "viaResolver"
    ELSE IF shortenActive /\ shortenEntry \in 2..terminalPos
    (* Always use wire shortcut after shortening — never "local" here, or    *)
    (* localQueues delivery races in-flight op:deliver-only on channels.     *)
    THEN "shortcut"
    ELSE IF naiveBeforeShorten
    THEN NaivePromiseResolutionRouteSend(p, r, kbp, host, terminalPos)
    ELSE NoPromiseResolutionRouteSend(p, r, kbp, host, terminalPos)

============================================================================
