------------------------- MODULE Unit_Listen_Subscribe_AfterResolve -------------------------
(***************************************************************************)
(* Phase 2 unit test: a focused single-mechanism counterpart of            *)
(* MC_SubscribeAfterResolve.                                               *)
(*                                                                         *)
(* Same topology as the scenario MC but isolated to exercise just the     *)
(* late-subscribe handler: HeadPeer=vatA, vatB is a pure subscriber.       *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB"}
HeadPeer == "vatA"
ChainLength == 2
MaxRefId == ChainLength
NumMessages == 1
EmptyInitialListeners == TRUE
EnableDynamicListen == TRUE
EnableHandoff == FALSE
MaxGifts == 0
RoutingPolicy == "NaivePromiseResolution"
DebugTrace == FALSE

VARIABLES
    channels,
    host,
    refs,
    sent,
    delivered,
    gifts,
    nextGiftId,
    nextRefId,
    lastAction

vars == << channels, host, refs, sent, delivered, gifts, nextGiftId, nextRefId, lastAction >>

PS ==
    INSTANCE PromiseResolution WITH
        Peers <- Peers,
        HeadPeer <- HeadPeer,
        ChainLength <- ChainLength,
        MaxRefId <- MaxRefId,
        NumMessages <- NumMessages,
        RoutingPolicy <- RoutingPolicy,
        EmptyInitialListeners <- EmptyInitialListeners,
        EnableDynamicListen <- EnableDynamicListen,
        EnableHandoff <- EnableHandoff,
        MaxGifts <- MaxGifts,
        DebugTrace <- DebugTrace,
        channels <- channels,
        host <- host,
        refs <- refs,
        sent <- sent,
        delivered <- delivered,
        gifts <- gifts,
        nextGiftId <- nextGiftId,
        nextRefId <- nextRefId,
        lastAction <- lastAction

(* Force the sequence: vatA's LocalPromise[1] must be resolved BEFORE any
   op:listen is delivered.  We can't directly enforce this in the state
   space, so this unit test relies on PS!Init's nondeterminism + the fact
   that ProcessPending will drain vatA's queue at vatA before any wire
   activity from vatB.  The interesting case is the late-subscribe
   handler; the unit checks all invariants over the full state space. *)

Init ==
    /\ PS!Init
    /\ host = <<"vatA", "vatA">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

TypeOK_MC == PS!TypeOK
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EventualDelivery_MC == PS!EventualDelivery
============================================================================
