---------------------- MODULE NaivePromiseResolution ----------------------
(***************************************************************************)
(* Policy module for `NaivePromiseResolution`.                            *)
(*                                                                         *)
(* MCs instantiate this module (instead of spec/Core.tla) to pin the      *)
(* routing policy.  The choice of policy is encoded in which              *)
(* protocols/<Policy>.tla the MC INSTANCEs.                               *)
(*                                                                         *)
(* The big actions and dispatch live in spec/Core.tla, which this module  *)
(* wraps via INSTANCE with policy-hook operators substituted for Core's   *)
(* CONSTANT hooks.                                                        *)
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

VARIABLES channels, host, vats, sent, delivered, nextRefId, lastAction

----------------------------------------------------------------------------
(* Policy hook implementations: NaivePromiseResolution.
   Install eagerly; emit op:resolve on every resolution (target +
   promise-shorten 2-party + 3-party); no embargo, no witness gate;
   shorten anywhere on the chain. *)

PolicyInstallNowOnResolve(isHandoffPwTarget, isHandoffPwPromiseCap, fastPath) ==
    TRUE

PolicyEmbargoInsteadOnResolve(isHandoffPwTarget, fastPath) ==
    FALSE

PolicyEnforcesChainBinderEmbargo == FALSE
PolicyClearsChainBinderOnInstall == FALSE
PolicyHasListeners == TRUE
PolicyRouteHoldsOnEmbargo == FALSE
PolicyEmitsPromiseShortenNotify == TRUE
PolicyEmitsPromiseShorten3PartyNotify == TRUE
PolicyEmitsOpResolveOnTarget == TRUE
PolicyRequiresWitnessForShorten3Party == FALSE
PolicyShortens3PartyAnywhere == TRUE
PolicyChainEmbargoOnHandoffGive == FALSE
PolicyResolverInitiatedFlush == FALSE

PR == INSTANCE Core

----------------------------------------------------------------------------
(* Re-exports for operators defined in Core.tla (NOT inherited via the
   lib/ EXTENDS chain).  Operators that come through EXTENDS are visible
   directly through `PS!OpName` without re-export. *)

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
