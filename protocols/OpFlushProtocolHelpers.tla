--------------------- MODULE OpFlushProtocolHelpers ---------------------
(***************************************************************************)
(* OpFlushProtocol wire-op declarations.                                   *)
(*                                                                         *)
(* The `OpFlushProtocol` routing policy implements the broader-trigger    *)
(* `op:flush` discussed in notes/flush-protocols.md §9.1: the resolver-   *)
(* holder fires `op:flush` whenever it resolves a `LocalPromise` to a     *)
(* value whose host is a different machine, and listeners embargo their   *)
(* RemotePromise mirror until the post-flush `op:resolve` lands.          *)
(*                                                                         *)
(* This module owns only the wire-op constructors; the actions and the    *)
(* full policy semantics live in protocols/OpFlushProtocol.tla.  Core     *)
(* EXTENDS this module so the constructors are visible from Core's        *)
(* op:resolve receive (which clears the embargo on install) and from      *)
(* Core's Messages typed set.                                              *)
(***************************************************************************)

EXTENDS Common

----------------------------------------------------------------------------
(* Wire ops carry just the target refId -- the resolver's `LocalPromise`
   refId that is being resolved.  Listener identity is implicit in the
   per-session channel.  No fresh-resolver minting (the original `r`
   keeps its identity through the handshake); the embargo + post-flush
   `op:resolve` install does the sequencing work. *)
OpFlush(targetRefId) ==
    [op |-> "op:flush",
     targetRefId |-> targetRefId]

OpFlushAck(targetRefId) ==
    [op |-> "op:flush-ack",
     targetRefId |-> targetRefId]

============================================================================
