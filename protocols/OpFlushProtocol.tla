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
(* Policy hook implementations: OpFlushProtocol (faithful Ridley).
   Resolver eagerly emits op:resolve(target) (this is the source of
   the FIFO race documented in §4.7); promise shortening is NOT done
   via ResolverResolve here -- instead the shortener fires
   InitiateFlush.  No embargo, no witness gate, no chain-binder
   enforcement.  ChainBinderClearOnInstall is a legacy TRUE
   unreachable under faithful Ridley. *)

PolicyInstallNowOnResolve(isHandoffPwTarget, isHandoffPwPromiseCap, fastPath) ==
    TRUE

PolicyEmbargoInsteadOnResolve(isHandoffPwTarget, fastPath) ==
    FALSE

PolicyEnforcesChainBinderEmbargo == FALSE
PolicyClearsChainBinderOnInstall == TRUE
PolicyHasListeners == TRUE
PolicyRouteHoldsOnEmbargo == FALSE
PolicyEmitsPromiseShortenNotify == FALSE
PolicyEmitsPromiseShorten3PartyNotify == FALSE
PolicyEmitsOpResolveOnTarget == TRUE
PolicyRequiresWitnessForShorten3Party == FALSE
PolicyShortens3PartyAnywhere == FALSE
PolicyChainEmbargoOnHandoffGive == FALSE
PolicyResolverInitiatedFlush == TRUE

PR == INSTANCE Core

----------------------------------------------------------------------------
(* OpFlushProtocol-specific action: InitiateFlush.
   The shortener-initiated op:flush per Ridley's draft (ocapn#11; verbatim
   in notes/flush-protocols.md §9).  Fires when peer `self` has learned
   that its local promise (a RemotePromise it holds) has resolved to
   something on a third-party peer.  Defined here so the OpFlushProtocol
   policy module exclusively owns it; Core's Next no longer includes it.

   Locality: all reads via LocalRef(self, _); writes scoped to
   vats[self].refs[_] and channels[self][_].

   Note on concurrent flushes: each flush mints fresh nextRefId slots,
   so concurrent flushes from multiple peers against the same r
   cooperate at the receiver -- but the receiver's r can only be
   fulfilled once (a v0 limitation of our intra-vat cascade).  The
   receive branch silently drops a second flush if r is already
   resolved. *)
InitiateFlush ==
    /\ EnableShorten
    /\ \E self \in Peers : \E r \in DOMrefs(self) :
        /\ LocalRef(self, r).kind = "RemotePromise"
        /\ LocalRef(self, r).localResolution # ResNone
        /\ LocalRef(self, r).localResolution.peer # self
        /\ LocalRef(self, r).localResolution.peer #
              LocalRef(self, r).resolverPeer
        /\ ~LocalRef(self, r).flushSent
        /\ LET entry == LocalRef(self, r)
               answerPos == nextRefId
               resolveMe == nextRefId + 1
           IN
              /\ answerPos \in RefIds
              /\ resolveMe \in RefIds
              /\ vats' =
                   [vats EXCEPT
                       ![self].refs[r].flushSent = TRUE,
                       ![self].refs[resolveMe] =
                           MkRemotePromise(entry.resolverPeer, resolveMe,
                               ResNone, {}, << >>, FALSE, TRUE, FALSE)]
              /\ nextRefId' = resolveMe + 1
              /\ channels' =
                   AppendToOutbox(channels, self, entry.resolverPeer,
                       PR!OpFlush(entry.resolverRefId, answerPos, resolveMe))
              /\ UNCHANGED << host, sent, delivered >>
              /\ PR!Mark([name |-> "InitiateFlush",
                          actor |-> self,
                          refId |-> r,
                          resolver |-> entry.resolverPeer,
                          answerPos |-> answerPos,
                          resolveMe |-> resolveMe])

----------------------------------------------------------------------------
(* OpFlushProtocol-specific receive: op:flush (resolver-holder side).
   Extracted from Core's big ReceiveNetwork dispatch.

   On receipt at the resolver-holder, the receive mints a fresh LocalPromise
   p' via nextRefId, sets the old resolver `r`'s resolution to
   ResRef(self, p') (the standard intra-vat queue cascade now buffers
   future sends locally at p'), and replies with op:resolve(resolveMeRefId,
   desc:import-promise(p')) on channels[self][from].

   Refused (silent drop, channel consumed) if the old `r` does not exist
   at self as an unresolved LocalPromise -- a second concurrent flush
   against the same r cannot fulfill r twice (Ridley §9 v0 limitation). *)
ReceiveOpFlush ==
    \E self, from \in Peers :
        /\ InboxNonEmpty(self, from)
        /\ LET msg == InboxHead(self, from)
               ch0 == InboxTail(channels, self, from)
           IN
              /\ msg.op = "op:flush"
              /\ LET r == msg.toDescRefId
                     rm == msg.resolveMeRefId
                     entry == LocalRef(self, r)
                     freshP == nextRefId
                     validFlush ==
                         /\ entry # EntryNone
                         /\ entry.kind = "LocalPromise"
                         /\ entry.resolution = ResNone
                         /\ freshP \in RefIds
                 IN
                    /\ (CASE validFlush
                             -> /\ vats' =
                                     [vats EXCEPT
                                         ![self].refs[r].resolution =
                                             ResRef(self, freshP),
                                         ![self].refs[r].notified = TRUE,
                                         ![self].refs[freshP] =
                                             MkLocalPromise(<< >>, {},
                                                 ResNone, {}, FALSE,
                                                 FALSE, {})]
                                /\ nextRefId' = freshP + 1
                                /\ channels' =
                                     AppendToOutbox(ch0, self, from,
                                         PR!OpResolve(rm,
                                             PR!DescImportPromise(freshP)))
                         [] OTHER
                             -> /\ channels' = ch0
                                /\ UNCHANGED << vats, nextRefId >>)
                    /\ UNCHANGED << host, sent, delivered >>
                    /\ PR!Mark([name |-> "ReceiveNetwork",
                                kind |-> "flush",
                                from |-> from,
                                to |-> self,
                                refId |-> msg.toDescRefId])

----------------------------------------------------------------------------
(* Resolver-initiated flush handshake (notes/flush-protocols.md §9.1).

   ReceiveOpFlushResolver: listener side.  When a peer L receives
   op:flush-resolver(targetRefId=r) from the resolver R, L acks
   immediately.  No state change at L -- per-session FIFO from R→L
   does the sequencing work: any messages R sent before the
   op:flush-resolver have already been processed at L by the time the
   ack reaches R, and the eventual op:resolve R sends after receiving
   the ack arrives at L behind all R's intervening pipelined sends. *)
ReceiveOpFlushResolver ==
    \E self, from \in Peers :
        /\ InboxNonEmpty(self, from)
        /\ LET msg == InboxHead(self, from)
               ch0 == InboxTail(channels, self, from)
           IN
              /\ msg.op = "op:flush-resolver"
              /\ channels' =
                   AppendToOutbox(ch0, self, from,
                       PR!OpFlushResolverAck(msg.targetRefId))
              /\ UNCHANGED << host, vats, sent, delivered, nextRefId >>
              /\ PR!Mark([name |-> "ReceiveNetwork",
                          kind |-> "flush-resolver",
                          from |-> from,
                          to |-> self,
                          targetRefId |-> msg.targetRefId])

(* ReceiveOpFlushResolverAck: resolver side.  Each ack removes one
   listener from flushPending.  When flushPending empties, the
   resolver fires the deferred op:resolve to every listener via the
   shared AppendResolveNotifications helper and flips notified=TRUE.
   Refused (silent drop, channel consumed) if the ack is unexpected
   (e.g. flushPending is already empty, or the entry isn't a
   LocalPromise). *)
ReceiveOpFlushResolverAck ==
    \E self, from \in Peers :
        /\ InboxNonEmpty(self, from)
        /\ LET msg == InboxHead(self, from)
               ch0 == InboxTail(channels, self, from)
           IN
              /\ msg.op = "op:flush-resolver-ack"
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
                                kind |-> "flush-resolver-ack",
                                from |-> from,
                                to |-> self,
                                targetRefId |-> msg.targetRefId,
                                wakeup |-> wakeup])

vars == << channels, host, vats, sent, delivered, nextRefId, lastAction >>

----------------------------------------------------------------------------
(* Re-exports.  Init unchanged; Next adds OpFlushProtocol-only
   InitiateFlush and ReceiveOpFlush; Fairness adds matching WF;
   Spec rebuilds. *)

Init == PR!Init
Next ==
    \/ PR!Next
    \/ InitiateFlush
    \/ ReceiveOpFlush
    \/ ReceiveOpFlushResolver
    \/ ReceiveOpFlushResolverAck
Fairness ==
    /\ PR!Fairness
    /\ WF_vars(InitiateFlush)
    /\ WF_vars(ReceiveOpFlush)
    /\ WF_vars(ReceiveOpFlushResolver)
    /\ WF_vars(ReceiveOpFlushResolverAck)
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
