---------------------------- MODULE EJavaFlush ----------------------------
(***************************************************************************)
(* Policy module for `EJavaFlush`.                                        *)
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
(* Policy hook implementations: EJavaFlush.
   - InstallNow: only when handoff-pw target descriptor OR fastPath.
   - EmbargoInstead: any non-handoff-pw-target op:resolve that isn't
     on the fast path.
   - Route hold check fires on non-empty embargo / pending.
   - Promise-shorten 2-party + 3-party emission fires.
   - 3-party requires the listener-pipelined witness gate.
   - 3-party is head-only on co-terminal topologies.
   - Chain-form handoff-give triggers embargo on the chain ref.
   - Enforces chain-binder embargo on handoff-pw promise-cap receives. *)

PolicyInstallNowOnResolve(isHandoffPwTarget, isHandoffPwPromiseCap, fastPath) ==
    isHandoffPwTarget \/ (~isHandoffPwPromiseCap /\ fastPath)

PolicyEmbargoInsteadOnResolve(isHandoffPwTarget, fastPath) ==
    ~isHandoffPwTarget /\ ~fastPath

PolicyEnforcesChainBinderEmbargo == TRUE
PolicyClearsChainBinderOnInstall == FALSE
PolicyHasListeners == TRUE
PolicyRouteHoldsOnEmbargo == TRUE
PolicyEmitsPromiseShortenNotify == TRUE
PolicyEmitsPromiseShorten3PartyNotify == TRUE
PolicyEmitsOpResolveOnTarget == TRUE
PolicyRequiresWitnessForShorten3Party == TRUE
PolicyShortens3PartyAnywhere == FALSE
PolicyChainEmbargoOnHandoffGive == TRUE

PR == INSTANCE Core

----------------------------------------------------------------------------
(* EJavaFlush-specific action: ProcessHold.
   Drains one message from a RemotePromise.pending whose embargo has been
   lifted (probe-ack receipt cleared the source from the refid-scoped
   embargo set).  Only fires under EJavaFlush -- other policies never
   populate `pending`.  Defined here so the EJavaFlush policy module
   exclusively owns this action; Core's Next no longer includes it. *)

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
              \* Disallow "hold" here: if localResolution chains into another
              \* embargoed RemotePromise we keep the action disabled (the
              \* outer embargo will lift first).
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

----------------------------------------------------------------------------
(* EJavaFlush-specific receive branches.  Extracted from Core's big
   ReceiveNetwork dispatch; each is now its own top-level action with
   its own `\E self, from \in Peers` wrapper.  TLC semantics are
   unchanged: each disjunct of Next is mutually-exclusive by msg.op
   anyway, so splitting into separate actions doesn't change the
   reachable state space.

   ReceiveEFlushProbe: the EJavaFlush slow-path sentinel.  Rides the
   pipelined path exactly like an op:deliver-only -- dispatch by Route
   over LocalRef(self, r), then ApplyRoute.  Terminal "deliver" tag at
   a LocalTarget is intercepted by ApplyRoute (polymorphic on msg.op)
   to emit OpEFlushProbeAck back to msg.originPeer on `self`'s own
   outbox, rather than appending to `delivered`. *)
ReceiveEFlushProbe ==
    \E self, from \in Peers :
        /\ InboxNonEmpty(self, from)
        /\ LET msg == InboxHead(self, from)
               ch0 == InboxTail(channels, self, from)
           IN
              /\ msg.op = "op:e-flush-probe"
              /\ LET r == msg.refId
                     entry == LocalRef(self, r)
                     route == PR!Route(self, r)
                     after ==
                         PR!ApplyRoute(self, route, msg, ch0, vats, delivered)
                 IN
                    /\ entry # EntryNone
                    /\ route.tag \in {"deliver", "wire", "queue", "hold"}
                    /\ channels' = after.channels
                    /\ vats' = after.vats
                    /\ delivered' = after.delivered
                    /\ UNCHANGED << host, sent >>
                    /\ PR!HandoffVarsUnchanged
                    /\ PR!Mark([name |-> "ReceiveNetwork",
                                kind |-> "e-flush-probe",
                                from |-> from,
                                to |-> self,
                                refId |-> r,
                                tag |-> route.tag,
                                originPeer |-> msg.originPeer,
                                originRefId |-> msg.originRefId])

(* ReceiveEFlushProbeAck: lifts the refid-scoped embargo on the
   originator's RemotePromise.  Removes entry.resolverPeer from the
   embargo set (the source whose op:resolve originally staged this
   probe).  If the local state has moved on (embargo cleared via
   another path), the ack is consumed but vats is left unchanged. *)
ReceiveEFlushProbeAck ==
    \E self, from \in Peers :
        /\ InboxNonEmpty(self, from)
        /\ LET msg == InboxHead(self, from)
               ch0 == InboxTail(channels, self, from)
           IN
              /\ msg.op = "op:e-flush-probe-ack"
              /\ LET r == msg.originRefId
                     entry == LocalRef(self, r)
                     liftEmbargo ==
                         /\ entry # EntryNone
                         /\ entry.kind = "RemotePromise"
                         /\ entry.embargo # {}
                 IN
                    /\ (CASE liftEmbargo
                             -> vats' =
                                    [vats EXCEPT
                                        ![self].refs[r].embargo =
                                            entry.embargo
                                                \ {entry.resolverPeer}]
                         [] OTHER -> UNCHANGED vats)
                    /\ channels' = ch0
                    /\ UNCHANGED << host, sent, delivered >>
                    /\ PR!HandoffVarsUnchanged
                    /\ PR!Mark([name |-> "ReceiveNetwork",
                                kind |-> "e-flush-probe-ack",
                                from |-> from,
                                to |-> self,
                                refId |-> msg.originRefId])

vars == << channels, host, vats, sent, delivered, nextRefId, lastAction >>

----------------------------------------------------------------------------
(* Re-exports for operators defined in Core.tla.

   Init unchanged; Next adds the EJavaFlush-only actions; Fairness adds
   the matching WF conjuncts; Spec rebuilds. *)

Init == PR!Init
Next ==
    \/ PR!Next
    \/ ProcessHold
    \/ ReceiveEFlushProbe
    \/ ReceiveEFlushProbeAck
Fairness ==
    /\ PR!Fairness
    /\ WF_vars(ProcessHold)
    /\ WF_vars(ReceiveEFlushProbe)
    /\ WF_vars(ReceiveEFlushProbeAck)
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
