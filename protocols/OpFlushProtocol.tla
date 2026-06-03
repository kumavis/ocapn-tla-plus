------------------------- MODULE OpFlushProtocol -------------------------
(***************************************************************************)
(* Policy module for `OpFlushProtocol`.                                   *)
(*                                                                         *)
(* MCs instantiate this module (instead of spec/Core.tla) to pin the      *)
(* routing policy.  The choice of policy is encoded in which              *)
(* protocols/<Policy>.tla the MC INSTANCEs.                               *)
(*                                                                         *)
(* The big actions and dispatch live in spec/Core.tla, which this module  *)
(* wraps via INSTANCE with policy-hook operators substituted for Core's   *)
(* CONSTANT hooks.                                                        *)
(*                                                                         *)
(* Trigger (broader Ridley reading; see notes/flush-protocols.md §9.1):   *)
(* whenever this peer resolves a LocalPromise to a value whose host is    *)
(* a different machine, it fires op:flush to each listener and defers     *)
(* op:resolve until acks return.  A listener receiving op:flush redirects *)
(* its RemotePromise mirror to a fresh *binder LocalPromise* (see         *)
(* ReceiveOpFlush): cascade-shortcut sends through the resolving ref then *)
(* queue on the binder by the ordinary unresolved-promise rule, and the   *)
(* post-flush op:resolve install resolves the binder + drains its queue   *)
(* along the new route.  No bespoke embargo (no embargo set, Route "hold" *)
(* tag, or ProcessHold).  No 3-field shortener-pull op:flush (Ridley's    *)
(* narrow draft) is needed: the broader trigger fires at the resolver.    *)
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
(* Policy hook implementations: OpFlushProtocol (broader-trigger op:flush).
   - InstallNow: every op:resolve installs immediately.
   - EmbargoInstead: never.
   - Route hold OFF (PolicyRouteHoldsOnEmbargo = FALSE): the listener
     hold is modelled as a binder LocalPromise (see ReceiveOpFlush), so
     held sends queue on the binder by the ordinary unresolved-promise
     rule -- no `embargo` set, no Route "hold" tag, no ProcessHold.
   - Promise-shorten 2-party + 3-party emission is ON: under the
     broader trigger, the resolver fires op:flush for any resolution
     whose target host is a different peer, target-shaped or
     promise-shaped.  The shorten emission rides the same op:resolve
     wire op after the flush handshake completes. *)

PolicyInstallNowOnResolve(isHandoffPwTarget, isHandoffPwPromiseCap, fastPath) ==
    TRUE

PolicyEmbargoInsteadOnResolve(isHandoffPwTarget, fastPath) ==
    FALSE

PolicyEnforcesChainBinderEmbargo == FALSE
PolicyClearsChainBinderOnInstall == TRUE
PolicyHasListeners == TRUE
PolicyRouteHoldsOnEmbargo == FALSE
PolicyEmitsPromiseShortenNotify == TRUE
PolicyEmitsPromiseShorten3PartyNotify == TRUE
PolicyEmitsOpResolveOnTarget == TRUE
PolicyRequiresWitnessForShorten3Party == FALSE
PolicyShortens3PartyAnywhere == TRUE
PolicyChainEmbargoOnHandoffGive == FALSE
PolicyResolverInitiatedFlush == TRUE

PR == INSTANCE Core

----------------------------------------------------------------------------
(* Resolver-initiated flush handshake (notes/flush-protocols.md §9.1).

   ReceiveOpFlush: listener side.  When peer L receives op:flush(r) from
   resolver R, L:
     1. Mints a fresh unresolved local LocalPromise (the binder) and
        points refs[r].localResolution at it.  Route on L then queues
        any send through r onto the binder's queue by the ordinary
        unresolved-LocalPromise rule (no embargo, no "hold" tag).
     2. Acks back to R.

   Core's op:resolve receive branch resolves the binder to the real
   target (and drains its queue along the new route) when R's op:resolve
   later arrives -- the install branch for direct targets/promises, the
   handoff-give branch for the 3-party case. *)
ReceiveOpFlush ==
    \E self, from \in Peers :
        /\ InboxNonEmpty(self, from)
        /\ LET msg == InboxHead(self, from)
               ch0 == InboxTail(channels, self, from)
           IN
              /\ msg.op = "op:flush"
              /\ LET r == msg.targetRefId
                     entry == LocalRef(self, r)
                     \* Embargo-via-binder (notes/locality-contract.md §2.1):
                     \* instead of setting a bespoke `embargo` flag, redirect
                     \* the RemotePromise mirror to a fresh *unresolved local
                     \* LocalPromise* (the binder).  Route then queues sends
                     \* through r into the binder's queue by the ordinary
                     \* unresolved-LocalPromise rule -- no embargo set, no
                     \* Route "hold" tag, no ProcessHold.  The op:resolve
                     \* install (Core) drains the binder's queue and points
                     \* localResolution at the real target.
                     binderRefId == nextRefId
                     validFlush ==
                         /\ entry # EntryNone
                         /\ entry.kind = "RemotePromise"
                         /\ entry.localResolution = ResNone
                 IN
                    /\ (CASE validFlush
                             -> /\ vats' =
                                    [vats EXCEPT
                                        ![self].refs[r].localResolution =
                                            ResRef(self, binderRefId),
                                        ![self].refs[binderRefId] =
                                            MkLocalPromise(<< >>, {}, ResNone,
                                                {}, FALSE, FALSE, {})]
                                /\ nextRefId' = nextRefId + 1
                         [] OTHER -> /\ UNCHANGED vats
                                     /\ UNCHANGED nextRefId)
                    /\ channels' =
                        AppendToOutbox(ch0, self, from,
                            PR!OpFlushAck(r))
                    /\ UNCHANGED << host, sent, delivered >>
                    /\ PR!Mark([name |-> "ReceiveNetwork",
                                kind |-> "flush",
                                from |-> from,
                                to |-> self,
                                refId |-> r])

(* ReceiveOpFlushAck: resolver side.  Each ack removes one listener
   from flushPending.  When flushPending empties, the resolver fires
   the deferred op:resolve to every listener via the shared
   AppendResolveNotifications helper and flips notified=TRUE.  Refused
   (silent drop, channel consumed) if the ack is unexpected. *)
ReceiveOpFlushAck ==
    \E self, from \in Peers :
        /\ InboxNonEmpty(self, from)
        /\ LET msg == InboxHead(self, from)
               ch0 == InboxTail(channels, self, from)
           IN
              /\ msg.op = "op:flush-ack"
              /\ LET r == msg.targetRefId
                     entry == LocalRef(self, r)
                     listeners == entry.listeners \ {self}
                     newPending == entry.flushPending \ {from}
                     wakeup == newPending = {}
                     notify ==
                         PR!AppendResolveNotifications(ch0, self, r,
                             entry.resolution, listeners,
                             LocalNextGiftId(self), nextRefId)
                     needsHandoff ==
                         \E l \in listeners :
                             PR!NeedsHandoffIntro(self, l,
                                 PR!TargetHostPeer(self, entry.resolution))
                     validAck ==
                         /\ entry # EntryNone
                         /\ entry.kind = "LocalPromise"
                         /\ from \in entry.flushPending
                 IN
                    /\ (CASE validAck /\ wakeup
                             -> /\ vats' =
                                     [vats EXCEPT
                                         ![self].refs[r].flushPending = {},
                                         ![self].refs[r].notified = TRUE,
                                         ![self].nextGiftId = notify.gidNext]
                                /\ channels' = notify.channels
                                /\ IF needsHandoff
                                   THEN nextRefId' = notify.pwNext
                                   ELSE UNCHANGED nextRefId
                         [] validAck /\ ~wakeup
                             -> /\ vats' =
                                     [vats EXCEPT
                                         ![self].refs[r].flushPending =
                                             newPending]
                                /\ channels' = ch0
                                /\ UNCHANGED nextRefId
                         [] OTHER
                             -> /\ channels' = ch0
                                /\ UNCHANGED << vats, nextRefId >>)
                    /\ UNCHANGED << host, sent, delivered >>
                    /\ PR!Mark([name |-> "ReceiveNetwork",
                                kind |-> "flush-ack",
                                from |-> from,
                                to |-> self,
                                refId |-> r,
                                wakeup |-> wakeup])

vars == << channels, host, vats, sent, delivered, nextRefId, lastAction >>

----------------------------------------------------------------------------
(* Re-exports.  Next adds OpFlushProtocol-only actions; Fairness adds
   matching WF; Spec rebuilds. *)

Init == PR!Init
Next ==
    \/ PR!Next
    \/ ReceiveOpFlush
    \/ ReceiveOpFlushAck
Fairness ==
    /\ PR!Fairness
    /\ WF_vars(ReceiveOpFlush)
    /\ WF_vars(ReceiveOpFlushAck)
Spec == Init /\ [][Next]_vars /\ Fairness
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
