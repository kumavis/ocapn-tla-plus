----------------------------- MODULE PeerState -----------------------------
(***************************************************************************)
(* Per-peer local delivery queues, per-promise pending queues at resolvers, *)
(* a single global send counter (only the chain head emits op:deliver-only), *)
(* and the observable delivery log.                                         *)
(***************************************************************************)

EXTENDS Naturals, Sequences, Network

VARIABLES
    localQueues,   \* [Peers -> Seq(Messages)]
    pending,       \* [Peers -> [PromiseRefs -> Seq(Messages)]]
    sent,          \* 0..NumMessages (head peer only; see PromiseResolution)
    delivered      \* Seq of delivery records (see PromiseResolution)

PeerStateInit ==
    /\ localQueues = [p \in Peers |-> << >>]
    /\ pending = [p \in Peers |-> [pr \in PromiseRefs |-> << >>]]
    /\ sent = 0
    /\ delivered = << >>

PeerStateTypeOK(Messages, DeliveredEntry, NumMessagesArg) ==
    /\ localQueues \in [Peers -> Seq(Messages)]
    /\ pending \in [Peers -> [PromiseRefs -> Seq(Messages)]]
    /\ sent \in 0..NumMessagesArg
    /\ delivered \in Seq(DeliveredEntry)

============================================================================
