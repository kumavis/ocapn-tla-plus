------------------ MODULE MC_SubscribeAfterResolve_ThreeParty ------------------
(***************************************************************************)
(* Late 3-party op:listen: vatA dynamically subscribes to p_1 hosted at    *)
(* vatB AFTER vatB has resolved p_1 to a Target on vatC.  This exercises   *)
(* the alreadyResolvedToTarget arm of the op:listen receive (concern 1     *)
(* from the autopilot review).                                             *)
(*                                                                         *)
(*   Peers     = {vatA, vatB, vatC}                                        *)
(*   host      = <<vatB, vatC>>      (p_1 at vatB; Target at vatC)         *)
(*   HeadPeer  = vatA                                                      *)
(*   Empty initial listeners + dynamic Listen so vatA's subscription is    *)
(*   the only way it ever lands in vatB.refs[1].listeners.                 *)
(*                                                                         *)
(* Pre-fix behaviour: ResolveValueFor was called with handoff-give-shaped  *)
(* tag (target host vatC is neither sender vatB nor listener vatA), the   *)
(* CASE's OTHER arm fell through to DescImportTarget, and the wrong-     *)
(* shape descriptor was put on the wire.  WireDescriptorContract did NOT *)
(* catch this directly (desc:import-target is a structurally valid       *)
(* two-party descriptor; only its target binding was wrong).             *)
(*                                                                         *)
(* What locks in the fix: ResolveValueFor's OTHER arm is now             *)
(* Assert(FALSE, ...).  If a future change reverts the                   *)
(* alreadyResolvedToTarget narrowing (i.e. allows needs-handoff late     *)
(* listens to reach ResolveValueFor again), TLC errors on the assertion *)
(* the first time the path is taken in this MC.                           *)
(*                                                                         *)
(* Post-fix behaviour: alreadyResolvedToTarget gate excludes the           *)
(* needs-handoff case, so vatB falls through to the OTHER arm of the      *)
(* op:listen receive -- the listener is recorded silently and no          *)
(* op:resolve is sent (gap noted in spec/Core.tla).           *)
(* WireDescriptorContract holds; EndToEndRefFIFO holds (vatA's pipelined  *)
(* sends still reach the terminal via the chain).                          *)
(*                                                                         *)
(* Expected: all invariants hold and the Assert never fires.             *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC"}
HeadPeer == "vatA"
ChainLength == 2
MaxGifts == 2
MaxRefId == ChainLength + MaxGifts
NumMessages == 1
EmptyInitialListeners == TRUE
EnableDynamicListen == TRUE
\* EnableHandoff = TRUE so the normal 3-party resolve path is not
\* gated out (concern 8) on interleavings where the listener
\* subscribes before resolution.  The concern-1 fix is exercised
\* on the interleavings where Listen lands after vatB has resolved.
EnableHandoff == TRUE
EnableHandoffInitiate == FALSE
EnableRepropagate == FALSE
EnableShorten == FALSE

DebugTrace == FALSE

VARIABLES
    channels,
    host,
    vats,
    sent,
    delivered,
    nextRefId,
    lastAction

vars == << channels, host, vats, sent, delivered, nextRefId, lastAction >>

PS == INSTANCE NaivePromiseResolution

Init ==
    /\ PS!Init
    /\ host = <<"vatB", "vatC">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

TypeOK_MC == PS!TypeOK
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EventualDelivery_MC == PS!EventualDelivery
WireDescriptorContract_MC == PS!WireDescriptorContract
OnlyKnownResolveDescriptors_MC == PS!OnlyKnownResolveDescriptors
============================================================================
