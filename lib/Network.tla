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

----------------------------------------------------------------------------
(* Per-actor locality accessors.  Every protocol action in
   spec/Core.tla is required to read/write only its own
   inbox (channels[from][self], where self is the receiver) and its own
   outbox (channels[self][to], where self is the sender).  These
   accessors give a name to the locality-respecting access pattern.

   IMPORTANT (channel-as-signal rule): a peer is allowed to APPEND to
   its own outbox but NOT to inspect its own outbox as a guard.  "Is my
   outbox empty?" is not an implementable signal -- bytes leaving a TCP
   socket buffer do not mean the recipient has applied them.  These
   accessors therefore expose only inbox reads and outbox writes; there
   is no OutboxLen / OutboxEmpty accessor by design.  See
   ../notes/locality-contract.md section 4. *)

Inbox(self, from)              == channels[from][self]
InboxHead(self, from)          == Head(channels[from][self])
InboxNonEmpty(self, from)      == Len(channels[from][self]) > 0
InboxTail(ch, self, from)      == [ch EXCEPT ![from][self] = Tail(@)]

AppendToOutbox(ch, self, to, msg) ==
    [ch EXCEPT ![self][to] = Append(@, msg)]

============================================================================
