----------------------------- MODULE Network -----------------------------
(***************************************************************************)
(* Per-pair FIFO channels between peers.  No protocol semantics.           *)
(***************************************************************************)

EXTENDS Naturals, Sequences, References

VARIABLE channels
  (* channels[from][to] is a FIFO queue of messages from `from` to `to`. *)

NetworkChannelsType(Messages) ==
    [Peers -> [Peers -> Seq(Messages)]]

NetworkAppend(ch, from, to, msg) ==
    [ch EXCEPT ![from][to] = Append(@, msg)]

NetworkHead(ch, from, to) ==
    Head(ch[from][to])

NetworkTail(ch, from, to) ==
    [ch EXCEPT ![from][to] = Tail(@)]

NetworkNonEmpty(ch, from, to) ==
    Len(ch[from][to]) > 0

NetworkInit ==
    channels = [p \in Peers |-> [q \in Peers |-> << >>]]

============================================================================
