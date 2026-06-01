--------------------- MODULE OpFlushProtocolHelpers ---------------------
(***************************************************************************)
(* OpFlushProtocol-specific code (faithful Ridley op:flush; ocapn#11).      *)
(*                                                                         *)
(* The `OpFlushProtocol` routing policy implements the proposal Ridley     *)
(* posted to ocapn#11 (comments 4344960376 + 4442041860, verbatim in       *)
(* notes/flush-protocols.md §9).  This module owns:                        *)
(*                                                                         *)
(*   - the `op:flush` wire op (Ridley's three-field shape: toDescRefId,    *)
(*     answerPos, resolveMeRefId).                                         *)
(*   - the `InitiateFlush` action that the would-be shortener fires when   *)
(*     it has learned its RemotePromise resolves to a third-party peer.   *)
(*                                                                         *)
(* The receive branch for op:flush (the resolver-holder side: mint fresh   *)
(* p' / r', fulfill old r with p', send back op:resolve carrying           *)
(* desc:import-promise(p')) lives inline in spec/PromiseResolution.tla    *)
(* because it is part of the big ReceiveNetwork action body that         *)
(* dispatches across all policies.                                         *)
(*                                                                         *)
(* No other policy reads or writes the OpFlushProtocol-specific state     *)
(* fields (`flushSent`, `flushPending`); under those policies these       *)
(* fields stay at their constructor defaults.                              *)
(*                                                                         *)
(* Surprising FIFO finding: Ridley's protocol as specified does NOT       *)
(* preserve EndToEndRefFIFO on the chain topologies this spec exercises. *)
(* See notes/path-changes.md §4.7 for the counterexample trace.           *)
(***************************************************************************)

EXTENDS Common

----------------------------------------------------------------------------
(* Wire op (Ridley shape, ocapn#11; see notes/flush-protocols.md §9).
   Sent by the would-be shortener to the peer holding the resolver of
   the promise being shortened.  Carries:
     - toDescRefId   : refId of the desc:export referencing the
                       resolver `r` on the receiver.
     - answerPos     : positive refId at which the sender expects the
                       flush response promise to land.
     - resolveMeRefId: refId of the desc:import-object the sender
                       exports to receive the response (the new
                       resolver `r'`). *)
OpFlush(toDescRefId, answerPos, resolveMeRefId) ==
    [op |-> "op:flush",
     toDescRefId |-> toDescRefId,
     answerPos |-> answerPos,
     resolveMeRefId |-> resolveMeRefId]

----------------------------------------------------------------------------
(* InitiateFlush: shortener-initiated op:flush per Ridley.  Fires when
   peer `self` has learned that its local promise (a RemotePromise it
   holds) has resolved to something on a third-party peer -- "neither
   self nor the resolver-holder."  Send op:flush to the resolver-holder
   asking for a fresh r' to retarget the eventual handoff at.

   Locality: all reads via LocalRef(self, _); writes scoped to
   vats[self].refs[_] and channels[self][_].

   Note on concurrent flushes: each flush mints fresh nextRefId slots,
   so concurrent flushes from multiple peers against the same r
   cooperate at the receiver -- but the receiver's r can only be
   fulfilled once (a v0 limitation of our intra-vat cascade).  The
   receive branch silently drops a second flush if r is already
   resolved.  Needs MkRemotePromise from References (in scope via the
   EXTENDS chain). *)
InitiateFlush ==
    /\ EnableShorten
    /\ RoutingPolicy = "OpFlushProtocol"
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
              \* Pre-mint a RemotePromise placeholder at resolveMe so the
              \* flush response (an op:resolve(resolveMe, ...) from the
              \* resolver-holder) lands cleanly.  resolverPeer is the
              \* receiver (entry.resolverPeer); resolverRefId is set
              \* equal to resolveMe under the v0 shared-refId convention.
              \* flushSent stays FALSE on the new entry so secondary
              \* InitiateFlush cycles can run if desired.
              /\ vats' =
                   [vats EXCEPT
                       ![self].refs[r].flushSent = TRUE,
                       ![self].refs[resolveMe] =
                           MkRemotePromise(entry.resolverPeer, resolveMe,
                               ResNone, {}, << >>, FALSE, TRUE, FALSE)]
              /\ nextRefId' = resolveMe + 1
              /\ channels' =
                   AppendToOutbox(channels, self, entry.resolverPeer,
                       OpFlush(entry.resolverRefId, answerPos, resolveMe))
              /\ UNCHANGED << host, sent, delivered >>
              /\ Mark([name |-> "InitiateFlush",
                       actor |-> self,
                       refId |-> r,
                       resolver |-> entry.resolverPeer,
                       answerPos |-> answerPos,
                       resolveMe |-> resolveMe])

============================================================================
