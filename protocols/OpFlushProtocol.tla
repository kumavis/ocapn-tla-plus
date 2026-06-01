------------------------- MODULE OpFlushProtocol -------------------------
(***************************************************************************)
(* Policy module for `OpFlushProtocol`.                                   *)
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

RoutingPolicy == "OpFlushProtocol"

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

PR == INSTANCE PromiseResolution

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
Fairness ==
    /\ PR!Fairness
    /\ WF_vars(InitiateFlush)
    /\ WF_vars(ReceiveOpFlush)
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
