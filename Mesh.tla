-------------------------------- MODULE Mesh --------------------------------
(***************************************************************************)
(* Zigcube's mesh addresses (C4 slice 1): which 127.77.<hi>.<lo> a service *)
(* takes when the API first writes it, and its release when the service is *)
(* deleted.  Written from src/mesh_address.zig, src/apply.zig (apply,      *)
(* delete_service), src/api.zig (apply_attempts_max) and                   *)
(* docs/decisions/2026-11-13-mesh-address-allocation.md at zigcube         *)
(* 18e9838 (branch claude/c4-slice1).  Independent of the tests in         *)
(* src/mesh_address_test.zig.                                              *)
(*                                                                         *)
(* It models the probe order of 18e9838: consecutive numbers from the      *)
(* counter.  The branch's head since review, b9ae3bd, probes 250 in order  *)
(* and 250 spread over the block; that is not modelled (FINDINGS.md 9).    *)
(*                                                                         *)
(* The store is linearizable: a read is one action, a transaction is one   *)
(* action, and a transaction commits only if every key it compares still   *)
(* has the mod_revision that was read (0: the key must not exist).  An     *)
(* API request is a sequence of reads and one transaction, so any number   *)
(* of other requests may commit between its reads and its transaction:     *)
(* that is the race review B of the slice found untested.                  *)
(*                                                                         *)
(* A create (mesh_address.assign, in apply):                               *)
(*   CStart     read /services/<name>                                      *)
(*   CCounter   read /mesh-address-next                                    *)
(*   CProbe     read /mesh-addresses/<candidate>          (up to ProbesMax)*)
(*   CReplicas  list /replicas/<old>/ and /observed/ for a released hold   *)
(*   CCommit    the transaction: service, counter, hold                    *)
(* A delete (delete_service, mesh_address.release):                        *)
(*   DStart     read /services/<name>                                      *)
(*   DHold      read /mesh-addresses/<its address>                         *)
(*   DCommit    the transaction: service deleted, hold released            *)
(*                                                                         *)
(* The block is 1..AddrMax for 1..65,534, ProbesMax for 500, Quarantine    *)
(* ticks for 24 hours, AttemptsMax for 3.  A service name is used again    *)
(* after its delete; "incarnation" below is one life of a name.            *)
(*                                                                         *)
(* Where the lease and fencing model matters: a replica "remains" here     *)
(* while a record of it does (/replicas or /observed), which is what the   *)
(* code reads.  That a container is gone when its records are is I1b of    *)
(* Fencing.tla, a bound of seconds against a quarantine of a day; the two  *)
(* modules are not composed.                                               *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Names,           \* service names
    Reqs,            \* API requests that may be in flight together
    None,
    AddrMax,         \* mesh_address_max: the block is 1..AddrMax
    ProbesMax,       \* mesh_address_probes_max
    Quarantine,      \* mesh_address_quarantine_ms, in ticks
    AttemptsMax,     \* apply_attempts_max
    MaxTime,         \* the model stops the clock here
    MaxOps,          \* requests the model follows
    \* --- what the environment may do ---
    ClockStep,       \* the API server's wall clock may step forward by this
                     \* much, once (0: it never does)
    \* --- the protocol's safeguards (TRUE is Zigcube) ---
    CompareCounter,  \* the transaction compares /mesh-address-next
    CompareHold,     \* the transaction compares the hold
    CompareService,  \* the transaction compares /services/<name>
    UseQuarantine,   \* a released hold waits Quarantine before reuse
    CheckReplicas,   \* a released hold waits for its service's replicas
    ReleaseOnDelete, \* the delete marks the hold released (FALSE: the
                     \* delete forgets it, the hold is deleted)
    \* --- a repair (FALSE is Zigcube) ---
    HoldByIncarnation \* "replicas remain" asks about the incarnation that
                      \* held the address, not about the name

ASSUME /\ AddrMax \in Nat \ {0} /\ ProbesMax \in Nat \ {0}
       /\ Quarantine \in Nat /\ AttemptsMax \in Nat \ {0}
       /\ MaxTime \in Nat /\ MaxOps \in Nat /\ ClockStep \in Nat

VARIABLES
    clock,      \* real time
    step,       \* how far the server's wall clock is ahead of real time
    rev,        \* the store's revision
    svc,        \* /services/<name>: None, or [addr, rev]
    counter,    \* /mesh-address-next: [next, rev], rev 0 when absent
    hold,       \* /mesh-addresses/<n>: [svc, rel, rev], rev 0 when absent
    reps,       \* reps[name]: the addresses of the incarnations of <name>
                \* that still have a replica record
    req,        \* the API requests
    ops,        \* requests started
    \* --- history, for the properties ---
    relAt,      \* relAt[n]: the real time of the last release of n, or None
    early,      \* an address was taken within Quarantine of its release
    falseFull   \* a create was refused ZC-E0207 having passed over an
                \* address only because a namesake of its old service runs

vars == <<clock, step, rev, svc, counter, hold, reps, req, ops,
          relAt, early, falseFull>>

Addrs == 1..AddrMax
Wall == clock + step
Wrapped(x) == IF x > AddrMax THEN 1 ELSE x

NoHold == [svc |-> None, rel |-> None, rev |-> 0]
Idle == [pc |-> "idle", name |-> None, tries |-> 0, srev |-> 0, addr |-> 0,
         cnext |-> 0, crev |-> 0, cand |-> 0, probes |-> 0, hrev |-> 0,
         hname |-> None, release |-> FALSE, passed |-> FALSE, out |-> None]

Init ==
    /\ clock = 0 /\ step = 0 /\ rev = 0
    /\ svc = [n \in Names |-> None]
    /\ counter = [next |-> 1, rev |-> 0]
    /\ hold = [a \in Addrs |-> NoHold]
    /\ reps = [n \in Names |-> {}]
    /\ req = [r \in Reqs |-> Idle]
    /\ ops = 0
    /\ relAt = [a \in Addrs |-> None]
    /\ early = FALSE /\ falseFull = FALSE

Keep(r, fields) == req' = [req EXCEPT ![r] = fields]
Ghosts == UNCHANGED <<relAt, early, falseFull>>
Store == UNCHANGED <<rev, svc, counter, hold>>

(***************************************************************************)
(* Create.                                                                 *)
(***************************************************************************)
\* apply.plan: read the service.  One that has an address keeps it, and the
\* apply is none of this module's business.
CStart(r, n) ==
    /\ req[r].pc = "idle" /\ ops < MaxOps
    /\ ops' = ops + 1
    /\ IF svc[n] # None
          THEN Keep(r, [Idle EXCEPT !.pc = "done", !.name = n, !.out = "kept"])
          ELSE Keep(r, [Idle EXCEPT !.pc = "counter", !.name = n])
    /\ Store /\ Ghosts /\ UNCHANGED <<clock, step, reps>>

\* A conflicting apply is read and planned again.
CAgain(r) ==
    /\ req[r].pc = "again"
    /\ IF svc[req[r].name] # None
          THEN Keep(r, [req[r] EXCEPT !.pc = "done", !.out = "kept"])
          ELSE Keep(r, [req[r] EXCEPT !.pc = "counter", !.passed = FALSE])
    /\ Store /\ Ghosts /\ UNCHANGED <<clock, step, reps, ops>>

\* read_counter: absent means the first number.
CCounter(r) ==
    /\ req[r].pc = "counter"
    /\ Keep(r, [req[r] EXCEPT !.pc = "probe", !.cnext = counter.next,
                              !.crev = counter.rev,
                              !.cand = Wrapped(counter.next), !.probes = 0])
    /\ Store /\ Ghosts /\ UNCHANGED <<clock, step, reps, ops>>

Next1(r) ==
    IF req[r].probes + 1 = ProbesMax
       THEN [req[r] EXCEPT !.pc = "done", !.out = "E0207",
                           !.probes = ProbesMax]
       ELSE [req[r] EXCEPT !.pc = "probe", !.probes = @ + 1,
                           !.cand = Wrapped(@ + 1)]

\* One probe: the hold of the candidate.  No hold: free.  A hold that is
\* not released, or released too recently on this server's clock: the next
\* candidate.  Otherwise the replicas of its service are looked for.
CProbe(r) ==
    /\ req[r].pc = "probe"
    /\ LET h == hold[req[r].cand]
           aged == /\ h.rel # None
                   /\ \/ ~UseQuarantine
                      \/ Wall >= h.rel /\ Wall - h.rel >= Quarantine
       IN  \/ /\ h.rev = 0
              /\ Keep(r, [req[r] EXCEPT !.pc = "commit", !.hrev = 0])
              /\ UNCHANGED falseFull
           \/ /\ h.rev # 0 /\ aged
              /\ Keep(r, [req[r] EXCEPT !.pc = "replicas", !.hrev = h.rev,
                                        !.hname = h.svc])
              /\ UNCHANGED falseFull
           \/ /\ h.rev # 0 /\ ~aged
              /\ Keep(r, Next1(r))
              /\ falseFull' = (falseFull \/
                               (Next1(r).out = "E0207" /\ req[r].passed))
    /\ Store /\ UNCHANGED <<clock, step, reps, ops, relAt, early>>

\* replicas_remain: any record of a replica of the hold's service, by name.
\* (With the repair: of the incarnation that held the address.)
CReplicas(r) ==
    /\ req[r].pc = "replicas"
    /\ LET n == req[r].hname
           c == req[r].cand
           remain == IF HoldByIncarnation THEN c \in reps[n]
                                          ELSE reps[n] # {}
           namesake == remain /\ c \notin reps[n]
       IN  IF CheckReplicas /\ remain
              THEN /\ Keep(r, [Next1(r) EXCEPT !.passed = @ \/ namesake])
                   /\ falseFull' = (falseFull \/
                         (Next1(r).out = "E0207" /\ (req[r].passed \/ namesake)))
              ELSE /\ Keep(r, [req[r] EXCEPT !.pc = "commit"])
                   /\ UNCHANGED falseFull
    /\ Store /\ UNCHANGED <<clock, step, reps, ops, relAt, early>>

\* The apply's transaction: the service (absent), the counter and the hold,
\* each compared at the revision read.
CCommit(r) ==
    /\ req[r].pc = "commit"
    /\ LET n == req[r].name
           c == req[r].cand
           ok == /\ CompareService => svc[n] = None
                 /\ CompareCounter => counter.rev = req[r].crev
                 /\ CompareHold => hold[c].rev = req[r].hrev
       IN  IF ok
              THEN /\ rev' = rev + 1
                   /\ svc' = [svc EXCEPT ![n] = [addr |-> c, rev |-> rev + 1]]
                   /\ counter' = [next |-> c + 1, rev |-> rev + 1]
                   /\ hold' = [hold EXCEPT ![c] =
                                 [svc |-> n, rel |-> None, rev |-> rev + 1]]
                   /\ early' = (early \/ (relAt[c] # None
                                          /\ clock - relAt[c] < Quarantine))
                   /\ Keep(r, [req[r] EXCEPT !.pc = "done", !.out = "created"])
              ELSE /\ Store /\ UNCHANGED early
                   /\ IF req[r].tries + 1 = AttemptsMax
                         THEN Keep(r, [req[r] EXCEPT !.pc = "done",
                                          !.out = "E0105", !.tries = @ + 1])
                         ELSE Keep(r, [req[r] EXCEPT !.pc = "again",
                                          !.tries = @ + 1])
    /\ UNCHANGED <<clock, step, reps, ops, relAt, falseFull>>

(***************************************************************************)
(* Delete.                                                                 *)
(***************************************************************************)
DStart(r, n) ==
    /\ req[r].pc = "idle" /\ ops < MaxOps
    /\ svc[n] # None
    /\ ops' = ops + 1
    /\ Keep(r, [Idle EXCEPT !.pc = "dhold", !.name = n, !.srev = svc[n].rev,
                            !.addr = svc[n].addr])
    /\ Store /\ Ghosts /\ UNCHANGED <<clock, step, reps>>

\* release: a hold that names another service, or none, or is released
\* already, is left alone.
DHold(r) ==
    /\ req[r].pc = "dhold"
    /\ LET h == hold[req[r].addr]
       IN  Keep(r, [req[r] EXCEPT !.pc = "dcommit", !.hrev = h.rev,
                       !.release = (h.rev # 0 /\ h.svc = req[r].name
                                    /\ h.rel = None)])
    /\ Store /\ Ghosts /\ UNCHANGED <<clock, step, reps, ops>>

DCommit(r) ==
    /\ req[r].pc = "dcommit"
    /\ LET n == req[r].name
           a == req[r].addr
           ok == /\ svc[n] # None /\ svc[n].rev = req[r].srev
                 /\ req[r].release => hold[a].rev = req[r].hrev
       IN  IF ok
              THEN /\ rev' = rev + 1
                   /\ svc' = [svc EXCEPT ![n] = None]
                   /\ hold' = IF ~req[r].release THEN hold
                              ELSE IF ReleaseOnDelete
                                 THEN [hold EXCEPT ![a] = [svc |-> n,
                                         rel |-> Wall, rev |-> rev + 1]]
                                 ELSE [hold EXCEPT ![a] = NoHold]
                   /\ relAt' = [relAt EXCEPT ![a] = clock]
                   /\ Keep(r, [req[r] EXCEPT !.pc = "done", !.out = "deleted"])
              ELSE /\ UNCHANGED <<rev, svc, hold, relAt>>
                   /\ Keep(r, [req[r] EXCEPT !.pc = "done", !.out = "conflict"])
    /\ UNCHANGED <<clock, step, counter, reps, ops, early, falseFull>>

Finish(r) ==
    /\ req[r].pc = "done"
    /\ Keep(r, Idle)
    /\ Store /\ Ghosts /\ UNCHANGED <<clock, step, reps, ops>>

(***************************************************************************)
(* The rest of the cluster.                                                *)
(***************************************************************************)
\* The replica controller and the agents: a live service gets replica
\* records; they go when it scales to nothing or after its delete.
RepAppear(n) ==
    /\ svc[n] # None /\ svc[n].addr \notin reps[n]
    /\ reps' = [reps EXCEPT ![n] = @ \cup {svc[n].addr}]
    /\ Store /\ Ghosts /\ UNCHANGED <<clock, step, req, ops>>

RepGone(n) ==
    /\ \E a \in reps[n] : reps' = [reps EXCEPT ![n] = @ \ {a}]
    /\ Store /\ Ghosts /\ UNCHANGED <<clock, step, req, ops>>

Tick ==
    /\ clock < MaxTime
    /\ clock' = clock + 1
    /\ Store /\ Ghosts /\ UNCHANGED <<step, reps, req, ops>>

\* The server's wall clock is set forward (a fault).
ClockJump ==
    /\ ClockStep > 0 /\ step = 0
    /\ step' = ClockStep
    /\ Store /\ Ghosts /\ UNCHANGED <<clock, reps, req, ops>>

\* Nothing in flight: the model may rest.
Rest == (\A r \in Reqs : req[r].pc = "idle") /\ UNCHANGED vars

ReqStep(r) ==
    \/ CAgain(r) \/ CCounter(r) \/ CProbe(r) \/ CReplicas(r) \/ CCommit(r)
    \/ DHold(r) \/ DCommit(r)

Next ==
    \/ \E r \in Reqs : \/ \E n \in Names : CStart(r, n) \/ DStart(r, n)
                       \/ ReqStep(r) \/ Finish(r)
    \/ \E n \in Names : RepAppear(n) \/ RepGone(n)
    \/ Tick \/ ClockJump \/ Rest

Spec == Init /\ [][Next]_vars
LiveSpec == Spec /\ \A r \in Reqs : WF_vars(ReqStep(r))

(***************************************************************************)
(* Properties.                                                             *)
(***************************************************************************)
MTypeOK ==
    /\ clock \in 0..MaxTime /\ step \in {0, ClockStep} /\ rev \in 0..MaxOps
    /\ ops \in 0..MaxOps
    /\ counter.next \in 1..(AddrMax + 1)
    /\ \A n \in Names : svc[n] # None => svc[n].addr \in Addrs
    /\ \A n \in Names : reps[n] \subseteq Addrs
    /\ \A r \in Reqs : /\ req[r].probes <= ProbesMax
                       /\ req[r].tries <= AttemptsMax
                       /\ req[r].cand \in 0..AddrMax

\* M1: no two live services hold one address.
M1_Unique ==
    \A n, m \in Names :
        (n # m /\ svc[n] # None /\ svc[m] # None) => svc[n].addr # svc[m].addr

\* M2: the hold of a live service's address names it and is not released.
M2_HoldNamesHolder ==
    \A n \in Names :
        svc[n] # None => /\ hold[svc[n].addr].svc = n
                         /\ hold[svc[n].addr].rel = None

\* M2b: and a hold that is not released is its live service's address: no
\* address leaks.
M2b_NoLeak ==
    \A a \in Addrs :
        (hold[a].rev # 0 /\ hold[a].rel = None) =>
            (svc[hold[a].svc] # None /\ svc[hold[a].svc].addr = a)

\* M3: an address is not taken within the quarantine of its release, in
\* real time.
M3_Quarantine == ~early

\* M4: no replica record of another service's incarnation that held the
\* address is left while a service holds it.
M4_NoOldReplica ==
    \A n, m \in Names :
        (svc[n] # None /\ n # m) => svc[n].addr \notin reps[m]

\* M5: a hold is never deleted, so a number that was handed out has one.
M5_HoldsStay ==
    \A a \in Addrs : relAt[a] # None => hold[a].rev # 0

\* M6: ZC-E0207 means the block is full: no create is refused having passed
\* over an address whose only fault is that a later service of the same
\* name has replicas.
M6_ExhaustedMeansFull == ~falseFull

\* M7: allocation terminates: every request ends, created, kept, deleted,
\* or refused with ZC-E0105 or ZC-E0207.
M7_RequestsEnd ==
    \A r \in Reqs : (req[r].pc # "idle") ~> (req[r].pc = "done")

=============================================================================
