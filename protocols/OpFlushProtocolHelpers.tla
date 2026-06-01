--------------------- MODULE OpFlushProtocolHelpers ---------------------
(***************************************************************************)
(* OpFlushProtocol wire-op declarations.                                    *)
(*                                                                         *)
(* The `OpFlushProtocol` routing policy implements Ridley's `op:flush`     *)
(* proposal (ocapn#11; verbatim text in notes/flush-protocols.md §9).      *)
(* This module owns only the wire-op constructor; the action `InitiateFlush`*)
(* and the full policy semantics live in protocols/OpFlushProtocol.tla     *)
(* (the policy module).  Core EXTENDS this module so the wire-op           *)
(* constructor is visible from the receive-branch dispatch in              *)
(* spec/Core.tla's ReceiveNetwork.                                          *)
(*                                                                         *)
(* Surprising FIFO finding: Ridley's protocol as specified does NOT       *)
(* preserve EndToEndRefFIFO on the chain topologies this spec exercises. *)
(* See notes/path-changes.md §4.7.                                         *)
(***************************************************************************)

EXTENDS Common

----------------------------------------------------------------------------
(* Wire op (Ridley shape, ocapn#11; see notes/flush-protocols.md §9).
   Sent by the would-be shortener to the peer holding the resolver of
   the promise being shortened.  Carries:
     - toDescRefId   : refId of the desc:export referencing the
                       resolver `r` on the receiver.
     - answerPos     : positive refId at which the sender expects the
                       flush response promise to land.
     - resolveMeRefId: refId of the desc:import-object the sender
                       exports to receive the response (the new
                       resolver `r'`). *)
OpFlush(toDescRefId, answerPos, resolveMeRefId) ==
    [op |-> "op:flush",
     toDescRefId |-> toDescRefId,
     answerPos |-> answerPos,
     resolveMeRefId |-> resolveMeRefId]

----------------------------------------------------------------------------
(* Resolver-side flush handshake (notes/flush-protocols.md §9.1).

   When a peer X resolves a LocalPromise r to a target on a remote
   host, X fires op:flush-resolver to each listener and defers the
   actual op:resolve until acks return.  The handshake serves as a
   sequencing barrier on the per-session FIFO channel: anything X sent
   before op:flush-resolver is processed at the listener before the
   eventual op:resolve, so the cascade-shortcut at the listener only
   opens after old-path traffic has been forwarded onward.

   These ops carry only the target refId.  No fresh-resolver minting
   (unlike Ridley's shortener-initiated op:flush); the existing
   resolver `r` keeps its identity through the handshake. *)
OpFlushResolver(targetRefId) ==
    [op |-> "op:flush-resolver",
     targetRefId |-> targetRefId]

OpFlushResolverAck(targetRefId) ==
    [op |-> "op:flush-resolver-ack",
     targetRefId |-> targetRefId]

============================================================================
