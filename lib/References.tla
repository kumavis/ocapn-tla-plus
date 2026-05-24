--------------------------- MODULE References ---------------------------
(***************************************************************************)
(* Linear ref-chain: positions 1 .. ChainLength-1 are promises;            *)
(* position ChainLength is the terminal object.  Promise i resolves to     *)
(* i+1 (implicit).  host[i] is the peer that holds the resolver for i      *)
(* (promises) or hosts the terminal object (terminal position).            *)
(*                                                                         *)
(* CONSTANT HeadPeer: vat that originates op:deliver-only on ref 1          *)
(* (chain client).  host[1] is resolver-holder for promise 1; HeadPeer    *)
(* may differ from host[1] (two-vat promise pipelining).                    *)
(***************************************************************************)

EXTENDS Naturals, Sequences

CONSTANT Peers, ChainLength, HeadPeer

ASSUME Peers # {}
ASSUME HeadPeer \in Peers
ASSUME /\ ChainLength \in Nat
       /\ ChainLength >= 2

Refs == 1..ChainLength
TerminalPos == ChainLength
PromiseRefs == 1..(ChainLength - 1)

IsObject(r) == r = TerminalPos
IsPromise(r) == r \in PromiseRefs

VARIABLES
    host,          \* [Refs -> Peers]
    resolved,      \* [PromiseRefs -> BOOLEAN]
    knownByPeer    \* [Peers -> [PromiseRefs -> BOOLEAN]]

ReferencesInit ==
    /\ host \in [Refs -> Peers]
    /\ resolved = [pr \in PromiseRefs |-> FALSE]
    /\ knownByPeer = [p \in Peers |-> [pr \in PromiseRefs |-> FALSE]]

RECURSIVE TerminalOf(_)
TerminalOf(r) ==
    IF IsObject(r) THEN r
    ELSE
        IF ~resolved[r] THEN r
        ELSE TerminalOf(r + 1)

HostOfTerminalOf(r) == host[TerminalOf(r)]

ReferencesTypeOK ==
    /\ HeadPeer \in Peers
    /\ host \in [Refs -> Peers]
    /\ resolved \in [PromiseRefs -> BOOLEAN]
    /\ knownByPeer \in [Peers -> [PromiseRefs -> BOOLEAN]]

============================================================================
