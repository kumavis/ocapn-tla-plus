--------------------------- MODULE References ---------------------------
(***************************************************************************)
(* Objects, promises, static topology (who hosts what, who resolves what),  *)
(* and global resolution state.  Resolution targets are objects only in    *)
(* this iteration; promise-to-promise targets are reserved for extending    *)
(* chain shortening later without restructuring pending/delivery.           *)
(***************************************************************************)

EXTENDS Naturals, Sequences

CONSTANT Peers, Objects, Promises, UNRESOLVED

RefSpace == Objects \cup Promises

ASSUME Peers # {}
ASSUME Objects # {}
ASSUME Promises # {}
ASSUME Objects \cap Promises = {}
ASSUME UNRESOLVED \notin RefSpace

VARIABLES
    objHost,       \* [Objects -> Peers]
    promResolver,  \* [Promises -> Peers]
    resolution,    \* [Promises -> RefSpace \cup {UNRESOLVED}]; object targets only for now
    knownByPeer    \* [Peers -> [Promises -> BOOLEAN]] has this peer learned the resolution?

IsObject(r) == r \in Objects
IsPromise(r) == r \in Promises

ReferencesInit ==
    /\ objHost \in [Objects -> Peers]
    /\ promResolver \in [Promises -> Peers]
    /\ resolution = [pr \in Promises |-> UNRESOLVED]
    /\ knownByPeer = [p \in Peers |-> [pr \in Promises |-> FALSE]]

RECURSIVE TerminalRef(_)
TerminalRef(r) ==
    IF IsObject(r) THEN r
    ELSE
        IF resolution[r] = UNRESOLVED THEN r
        ELSE TerminalRef(resolution[r])

HostOfTerminal(r) ==
    LET t == TerminalRef(r) IN
        IF IsObject(t) THEN objHost[t]
        ELSE promResolver[t]

ReferencesTypeOK ==
    /\ objHost \in [Objects -> Peers]
    /\ promResolver \in [Promises -> Peers]
    /\ resolution \in [Promises -> RefSpace \cup {UNRESOLVED}]
    /\ knownByPeer \in [Peers -> [Promises -> BOOLEAN]]

============================================================================
