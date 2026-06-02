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
(* op:resolve until acks return.  Listeners receiving op:flush embargo    *)
(* their RemotePromise mirror (PolicyRouteHoldsOnEmbargo = TRUE) so that  *)
(* cascade-shortcut routing through the resolving ref is held in          *)
(* pending until the post-flush op:resolve installs the new resolution    *)
(* AND lifts the embargo, at which point ProcessHold drains pending in    *)
(* arrival order.  No 3-field shortener-pull op:flush (Ridley's narrow    *)
(* draft) is needed: the broader trigger fires at the resolver.           *)
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
   - InstallNow: every op:resolve installs immediately (the embargo set
     by an earlier op:flush is cleared by Core's existing install branch
     via `entry.embargo \ {from}`).
   - EmbargoInstead: never (we don't gate install on op:resolve; the
     embargo is set on op:flush receipt instead).
   - Route hold check fires on non-empty embargo (the post-flush hold
     window at the listener).
   - Promise-shorten 2-party + 3-party emission stays OFF; the resolver-
     side flush handles the path-change race directly. *)

PolicyInstallNowOnResolve(isHandoffPwTarget, isHandoffPwPromiseCap, fastPath) ==
    TRUE

PolicyEmbargoInsteadOnResolve(isHandoffPwTarget, fastPath) ==
    FALSE

PolicyEnforcesChainBinderEmbargo == FALSE
PolicyClearsChainBinderOnInstall == TRUE
PolicyHasListeners == TRUE
PolicyRouteHoldsOnEmbargo == TRUE
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
     1. Adds R to L's RemotePromise mirror embargo set (refs[r].embargo).
        While embargo is non-empty, Route on L returns "hold" for any
        send routed through this ref -- the message is queued in
        refs[r].pending instead of being forwarded on the wire.
     2. Acks back to R.

   The embargo is cleared by Core's op:resolve receive branch on
   install (`entry.embargo \ {from}` removes R from the set when R's
   op:resolve later arrives).  ProcessHold then drains pending. *)
ReceiveOpFlush ==
    \E self, from \in Peers :
        /\ InboxNonEmpty(self, from)
        /\ LET msg == InboxHead(self, from)
               ch0 == InboxTail(channels, self, from)
           IN
              /\ msg.op = "op:flush"
              /\ LET r == msg.targetRefId
                     entry == LocalRef(self, r)
                     validFlush ==
                         /\ entry # EntryNone
                         /\ entry.kind = "RemotePromise"
                 IN
                    /\ (CASE validFlush
                             -> vats' =
                                    [vats EXCEPT
                                        ![self].refs[r].embargo =
                                            entry.embargo \cup {from}]
                         [] OTHER -> UNCHANGED vats)
                    /\ channels' =
                        AppendToOutbox(ch0, self, from,
                            PR!OpFlushAck(r))
                    /\ UNCHANGED << host, sent, delivered, nextRefId >>
                    /\ PR!Mark([name |-> "ReceiveNetwork",
                                kind |-> "flush",
                                from |-> from,
                                to |-> self,
                                targetRefId |-> r])

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
                                targetRefId |-> r,
                                wakeup |-> wakeup])

----------------------------------------------------------------------------
(* ProcessHold: drain one message from refs[r].pending whose embargo
   has been lifted.  Identical in shape to the EJavaFlush ProcessHold
   (only the trigger for setting embargo differs); duplicated here so
   OpFlushProtocol's Next composes the action directly without
   reaching into a sibling policy module. *)
ProcessHold ==
    \E self \in Peers : \E r \in DOMrefs(self) :
        /\ LocalRef(self, r).kind = "RemotePromise"
        /\ LocalRef(self, r).embargo = {}
        /\ Len(LocalRef(self, r).pending) > 0
        /\ LET entry == LocalRef(self, r)
               msg == Head(entry.pending)
               restPending == Tail(entry.pending)
               route ==
                   IF entry.localResolution # ResNone
                   THEN PR!Route(self, entry.localResolution.refId)
                   ELSE [tag |-> "wire",
                         peer |-> entry.resolverPeer,
                         refId |-> entry.resolverRefId]
               vatsSrc == [vats EXCEPT ![self].refs[r].pending = restPending]
               after == PR!ApplyRoute(self, route, msg, channels, vatsSrc, delivered)
           IN
              /\ route.tag \in {"deliver", "wire", "queue"}
              /\ channels' = after.channels
              /\ vats' = after.vats
              /\ delivered' = after.delivered
              /\ UNCHANGED << host, sent >>
              /\ PR!HandoffVarsUnchanged
              /\ PR!Mark([name |-> "ProcessHold",
                          actor |-> self,
                          refId |-> r,
                          tag |-> route.tag,
                          op |-> msg.op,
                          seq |-> IF "seq" \in DOMAIN msg
                                  THEN msg.seq
                                  ELSE 0])

vars == << channels, host, vats, sent, delivered, nextRefId, lastAction >>

----------------------------------------------------------------------------
(* Re-exports.  Next adds OpFlushProtocol-only actions; Fairness adds
   matching WF; Spec rebuilds. *)

Init == PR!Init
Next ==
    \/ PR!Next
    \/ ReceiveOpFlush
    \/ ReceiveOpFlushAck
    \/ ProcessHold
Fairness ==
    /\ PR!Fairness
    /\ WF_vars(ReceiveOpFlush)
    /\ WF_vars(ReceiveOpFlushAck)
    /\ WF_vars(ProcessHold)
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
