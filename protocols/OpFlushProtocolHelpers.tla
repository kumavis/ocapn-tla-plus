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

============================================================================
