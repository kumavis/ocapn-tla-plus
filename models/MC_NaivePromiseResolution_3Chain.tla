--------------- MODULE MC_NaivePromiseResolution_3Chain ---------------
(***************************************************************************)
(* Three-party inter-vat promise-to-promise shortening under              *)
(* NaivePromiseResolution.  Models §1.2.b's three-party form (Phase B):   *)
(* the resolver vatB emits desc:handoff-give carrying a Promise cap on   *)
(* vatC to the listener vatA, and vatA later issues op:withdraw-gift     *)
(* whose reply is desc:import-promise (Phase B's withdraw extension).   *)
(*                                                                         *)
(* Topology (ChainLength = 3, three peers):                                *)
(*   HeadPeer = vatA                                                       *)
(*   host[1]  = vatB   (LocalPromise p_1; listener {vatA})                 *)
(*   host[2]  = vatC   (LocalPromise p_2; listener {vatB})                 *)
(*   host[3]  = vatC   (LocalTarget T)                                     *)
(*                                                                         *)
(* The race surface this exercises:                                        *)
(*                                                                         *)
(*   1. vatA pipelines seq=1 via Route(vatA, 1) -> wire(vatB, 1).          *)
(*   2. vatB queues seq=1 on vats[vatB].refs[1].queue.                     *)
(*   3. vatB's ResolverResolve at r=1: firePromiseShorten3Party fires.    *)
(*        - sets refs[1].resolution = ResRef(vatC, 2)                      *)
(*        - sends op:deposit-gift(gid=1, recipient=vatA, tlr=2, pw=4)     *)
(*          to vatC                                                        *)
(*        - sends op:resolve(1, desc:handoff-give(vatB, vatC, 1, 4)) to   *)
(*          vatA                                                            *)
(*   4. vatA receives the handoff-give: mints RemotePromise(vatC, 4),    *)
(*      rebinds refs[1].localResolution = ResRef(vatA, 4), and sends     *)
(*      op:withdraw-gift(1, vatB, 4) to vatC.                            *)
(*   5. vatC processes deposit and withdraw: refs[4] = LocalPromise      *)
(*      pre-minted, then resolution = ResRef(vatC, 2) (Phase B             *)
(*      LocalPromise withdraw path).  Sends op:resolve(4,                *)
(*      desc:import-promise(2)) back to vatA.                            *)
(*   6. vatA installs refs[4].localResolution = ResRef(vatC, 2).         *)
(*   7. vatA pipelines seq=2 via Route(vatA, 1) -> RemotePromise         *)
(*      localResolution -> Route(vatA, 4) -> RemotePromise               *)
(*      localResolution -> Route(vatA, 2) -> RemotePromise(vatC, 2) ->  *)
(*      wire(vatC, 2).  seq=2 hits vatC's LocalPromise(p_2) queue       *)
(*      directly.                                                        *)
(*   8. Concurrently, vatB's ProcessPending drains seq=1 from            *)
(*      refs[1].queue -> Route(vatB, 2) -> RemotePromise(vatC, 2) ->     *)
(*      wire(vatC, 2).                                                   *)
(*                                                                         *)
(* Steps 7 and 8 race at vatC's refs[2].queue: seq=2 (new path) may      *)
(* enter the queue BEFORE seq=1 (old indirect path) -- EndToEndRefFIFO   *)
(* violation.  Expected outcome: VIOLATION, dual to                      *)
(* MC_NaivePromiseResolution_PromiseShorten but with one extra chain hop  *)
(* and three peers.                                                       *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC"}
HeadPeer == "vatA"
ChainLength == 3
MaxGifts == 2
MaxRefId == ChainLength + MaxGifts
NumMessages == 2
EmptyInitialListeners == FALSE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
RoutingPolicy == "NaivePromiseResolution"

CONSTANT DebugTrace  \* set in .cfg

VARIABLES
    channels,
    host,
    vats,
    sent,
    delivered,
    nextRefId,
    lastAction

vars == << channels, host, vats, sent, delivered, nextRefId, lastAction >>

PS == INSTANCE PromiseResolution

Init ==
    /\ PS!Init
    /\ host = <<"vatB", "vatC", "vatC">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

SpecDebug == Init /\ [][Next]_vars

TypeOK_MC == PS!TypeOK
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
EventualDelivery_MC == PS!EventualDelivery
WireDescriptorContract_MC == PS!WireDescriptorContract
OnlyKnownResolveDescriptors_MC == PS!OnlyKnownResolveDescriptors
GiftOneShot_MC == PS!GiftOneShot
GiftHasOneRecipient_MC == PS!GiftHasOneRecipient

============================================================================
