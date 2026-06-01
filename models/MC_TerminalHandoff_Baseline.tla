------------------------- MODULE MC_TerminalHandoff_Baseline -------------------------
(***************************************************************************)
(* 3PHO baseline: a single opaque 3PHO firing in isolation, no race      *)
(* surface from a forwarder.  Validates that the deposit/withdraw         *)
(* round-trip materializes a properly-paired RemotePromise/LocalPromise   *)
(* for pw and that messages routed through the new ref reach the target. *)
(*                                                                         *)
(*   Peers     = {vatA, vatB, vatC}                                        *)
(*   host      = <<vatA, vatC>>  (LocalPromise[1] @ vatA, terminal @ vatC)*)
(*   HeadPeer  = vatB                                                     *)
(*   Chain refs are inert here: vatA never resolves p_1.  The interesting *)
(*   behavior is the side handoff vatA -> vatB about vatC's target.       *)
(*                                                                         *)
(* The handoff:                                                            *)
(*   1. HandoffInitiate(vatA, vatB, vats[vatA].refs[2]) ->                *)
(*      op:deposit-gift to vatC, op:resolve(pw, desc:handoff-give) to     *)
(*      vatB.                                                              *)
(*   2. vatC processes op:deposit-gift -> sets                            *)
(*      vats[vatC].gifts[vatA][1].                                        *)
(*   3. vatB processes op:resolve(handoff-give) -> mints RemotePromise pw *)
(*      and sends op:withdraw-gift(1, vatA, pw) to vatC.                  *)
(*   4. vatC processes op:withdraw-gift -> mints LocalPromise pw, resolves*)
(*      it to LocalTarget r_T_local, sends op:resolve(pw, desc:import-    *)
(*      target(2)) to vatB, clears gift.  (DescImportTarget takes only   *)
(*      a refId; the host is implicit as the sender vatC.)                *)
(*   5. vatB processes op:resolve(import-target) -> installs              *)
(*      localResolution = ResRef(vatC, 2) on the pw entry.                *)
(*                                                                         *)
(* Invariants checked:                                                     *)
(*   EndToEndRefFIFO, NoMessageLost, PairingInvariant, GiftOneShot,       *)
(*   GiftHasOneRecipient.                                                 *)
(***************************************************************************)

EXTENDS TLC, Naturals, Sequences

Peers == {"vatA", "vatB", "vatC"}
HeadPeer == "vatB"
ChainLength == 2
MaxGifts == 1
MaxRefId == ChainLength + MaxGifts
NumMessages == 1
EmptyInitialListeners == TRUE
EnableDynamicListen == FALSE
EnableHandoff == TRUE
EnableHandoffInitiate == TRUE
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

PS == INSTANCE NoPromiseResolution

Init ==
    /\ PS!Init
    /\ host = <<"vatA", "vatC">>

Next == PS!Next

Spec == Init /\ [][Next]_vars /\ PS!Fairness

TypeOK_MC == PS!TypeOK
EndToEndRefFIFO_MC == PS!EndToEndRefFIFO
PairingInvariant_MC == PS!PairingInvariant
NoMessageLost_MC == PS!NoMessageLost
EventualDelivery_MC == PS!EventualDelivery
GiftOneShot_MC == PS!GiftOneShot
GiftHasOneRecipient_MC == PS!GiftHasOneRecipient
WireDescriptorContract_MC == PS!WireDescriptorContract
OnlyKnownResolveDescriptors_MC == PS!OnlyKnownResolveDescriptors
============================================================================
