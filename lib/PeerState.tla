----------------------------- MODULE PeerState -----------------------------
(***************************************************************************)
(* Per-peer local delivery queues, per-promise pending queues at resolvers, *)
(* send counters, and the observable delivery log.                          *)
(***************************************************************************)

EXTENDS Naturals, Sequences, Network

VARIABLES
    localQueues,   \* [Peers -> Seq(Messages)]
    pending,       \* [Peers -> [Promises -> Seq(Messages)]]
    sent,          \* [Peers -> [RefSpace -> 0..NumMessages]]
    delivered      \* Seq of delivery records (see PromiseResolution)

PeerStateInit ==
    /\ localQueues = [p \in Peers |-> << >>]
    /\ pending = [p \in Peers |-> [pr \in Promises |-> << >>]]
    /\ sent = [p \in Peers |-> [r \in RefSpace |-> 0]]
    /\ delivered = << >>

PeerStateTypeOK(Messages, DeliveredEntry, NumMessagesArg) ==
    /\ localQueues \in [Peers -> Seq(Messages)]
    /\ pending \in [Peers -> [Promises -> Seq(Messages)]]
    /\ sent \in [Peers -> [RefSpace -> 0..NumMessagesArg]]
    /\ delivered \in Seq(DeliveredEntry)

============================================================================
