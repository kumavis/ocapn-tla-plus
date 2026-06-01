---------------------------- MODULE EJavaFlush ----------------------------
(***************************************************************************)
(* Policy module for `EJavaFlush`.                                   *)
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

RoutingPolicy == "EJavaFlush"

VARIABLES channels, host, vats, sent, delivered, nextRefId, lastAction

PR == INSTANCE PromiseResolution

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

vars == << channels, host, vats, sent, delivered, nextRefId, lastAction >>

----------------------------------------------------------------------------
(* Re-exports for operators defined in PromiseResolution.tla.

   Init is unchanged; Next adds the EJavaFlush-only ProcessHold action;
   Fairness adds the weak-fairness conjunct for it; Spec rebuilds from
   Init/Next/Fairness so the policy-specific behaviour is reachable. *)

Init == PR!Init
Next == PR!Next \/ ProcessHold
Fairness == PR!Fairness /\ WF_vars(ProcessHold)
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
