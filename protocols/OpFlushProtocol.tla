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

vars == << channels, host, vats, sent, delivered, nextRefId, lastAction >>

----------------------------------------------------------------------------
(* Re-exports.  Init unchanged; Next adds OpFlushProtocol-only
   InitiateFlush; Fairness adds the matching WF; Spec rebuilds. *)

Init == PR!Init
Next == PR!Next \/ InitiateFlush
Fairness == PR!Fairness /\ WF_vars(InitiateFlush)
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
