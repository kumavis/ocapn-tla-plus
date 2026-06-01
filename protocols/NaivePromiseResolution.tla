---------------------- MODULE NaivePromiseResolution ----------------------
(***************************************************************************)
(* Policy module for `NaivePromiseResolution`.                                   *)
(*                                                                         *)
(* MCs instantiate this module (instead of spec/PromiseResolution.tla)    *)
(* to pin RoutingPolicy.  The choice of policy is encoded in which        *)
(* protocols/<Policy>.tla the MC INSTANCEs; the RoutingPolicy constant    *)
(* no longer needs to live in the MC's CONSTANT block.                    *)
(*                                                                         *)
(* The big actions and dispatch live in spec/PromiseResolution.tla,       *)
(* which this module wraps via INSTANCE with the RoutingPolicy operator   *)
(* substituted for Core's RoutingPolicy CONSTANT.  See                    *)
(* notes/refactor-plan-inversion.md for the rationale.                    *)
(***************************************************************************)

EXTENDS Naturals, Sequences, TLC, References, Network, PeerState

CONSTANT
    NumMessages,
    DebugTrace,
    EmptyInitialListeners,
    EnableDynamicListen,
    EnableHandoff,
    EnableHandoffInitiate,
    EnableRepropagate,
    EnableShorten

RoutingPolicy == "NaivePromiseResolution"

VARIABLES channels, host, vats, sent, delivered, nextRefId, lastAction

PR == INSTANCE PromiseResolution

----------------------------------------------------------------------------
(* Re-exports for operators defined in PromiseResolution.tla (NOT
   inherited via the lib/ EXTENDS chain).  Operators that come through
   EXTENDS are visible directly through `PS!OpName` without re-export. *)

Init == PR!Init
Next == PR!Next
Spec == PR!Spec
Fairness == PR!Fairness
TypeOK == PR!TypeOK
EndToEndRefFIFO == PR!EndToEndRefFIFO
EventualDelivery == PR!EventualDelivery
NoMessageLost == PR!NoMessageLost
WireDescriptorContract == PR!WireDescriptorContract
OnlyKnownResolveDescriptors == PR!OnlyKnownResolveDescriptors
GiftOneShot == PR!GiftOneShot
GiftHasOneRecipient == PR!GiftHasOneRecipient
DescImportTarget(refId) == PR!DescImportTarget(refId)
DescExportTarget(refId) == PR!DescExportTarget(refId)
DescImportPromise(refId) == PR!DescImportPromise(refId)
DescExportPromise(refId) == PR!DescExportPromise(refId)
DescHandoffGive(gifter, targetHost, giftId, pw) == PR!DescHandoffGive(gifter, targetHost, giftId, pw)
OpWithdrawGift(giftId, gifter, pw) == PR!OpWithdrawGift(giftId, gifter, pw)
WireDescTag(sender, receiver, capHost, capKind) == PR!WireDescTag(sender, receiver, capHost, capKind)
WireDescMatches(sender, receiver, capHost, capKind, desc) == PR!WireDescMatches(sender, receiver, capHost, capKind, desc)

============================================================================
