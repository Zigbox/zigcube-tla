------------------------------- MODULE Rollout -------------------------------
(***************************************************************************)
(* Zigcube's rolling updates (C3): the budget a rollout gives the replica  *)
(* controller, and the rollout's phases.  Written from docs/briefs/c3.md   *)
(* ("Controller design", checks R1, R2, R4, R7, R8), src/rollout_plan.zig  *)
(* (budget, done, begin, pause, resume, the failure ranking), docs/keys.md *)
(* (/rollouts) and docs/decisions/2026-11-13-c3-slice6-rollout-plan.md at  *)
(* zigcube 2954195 (branch claude/c3-slice6-rollout-plan).                 *)
(*                                                                         *)
(* What exists at that commit is the pure plan (slice 6) and the keys      *)
(* (slice 5).  The two controllers that use them (slice 7) are not built,  *)
(* so this module models the design the brief gives them, and the switch   *)
(* Spend says how the replica controller reads "obeys the budget":         *)
(*   "stored"   it acts whenever the count in /rollouts is above zero      *)
(*   "once"     it spends each written budget at most once                 *)
(*   "recheck"  it evaluates the budget function itself, on what it reads  *)
(*              in the transaction that acts                               *)
(* The brief and keys.md fit "stored" and "once"; "recheck" is the reading *)
(* under which the checks hold (FINDINGS.md 7).                            *)
(*                                                                         *)
(* One service.  Replicas are counted by generation and state:             *)
(*   S starting or not yet ready     R ready                               *)
(*   K running and unready for good  P stopping, live until seen stopped   *)
(* A replica of a bad generation never turns ready.  Time is abstract: the *)
(* progress deadline and the ready timeout are actions that may fire while *)
(* the rollout is not done.                                                *)
(*                                                                         *)
(* /rollouts has one writer, the rollout controller, so a user's pause or  *)
(* resume is an intent it applies on its next pass (the brief does not say *)
(* how it arrives).  Its pass is one transaction here, as good as it can   *)
(* be; the budget it writes is still read later by the replica controller. *)
(*                                                                         *)
(* Where the lease and fencing model matters: Lose is a replica whose node *)
(* was lost and that the node controller has marked so (Fencing.tla,       *)
(* MarkLost).  Between the node's death and that mark the records count a  *)
(* dead replica ready; R1 is about the controller's view, as the brief     *)
(* words it, so that window is outside it.  The modules are not composed.  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxSurge, MaxUnavail,   \* the rollout policy
    OnFailure,              \* "rollback" or "pause"
    Wants,                  \* the replica counts a user may scale to
    Want0,                  \* the count at the start
    FirstGen,               \* TRUE: the service is new, generation 1 rolls out
    MaxApplies,             \* user applies the model follows
    MaxUser,                \* user pauses, resumes and scales
    MaxFaults,              \* replicas lost or gone unready for good
    Sick,                   \* which replicas may go unready for good:
                            \* "any", "old" (not the service's generation)
                            \* or "none"
    BadReleases,            \* a user may apply a generation that never is ready
    UseDeadline,            \* the progress deadline may pass
    \* --- the design's rules (TRUE is Zigcube) ---
    RetireUnready,          \* budget.retire_unready: an old replica that is
                            \* not ready is retired without budget
    CheckPhase,             \* the replica controller spends budget only while
                            \* the rollout is progressing or rolling back
    RollbackCas,            \* the automatic rollback compares the service's
                            \* revision
    ReplaceCountsStopping,  \* failure replacement counts a stopping
                            \* replica as live, as the budget does
    Spend,                  \* see above
    CheckTarget             \* the replica controller spends a budget only if
                            \* /rollouts.to is the service's generation

MaxGen == 2 * MaxApplies + 2
Gens == 1..MaxGen

VARIABLES
    gen, want, kind,   \* /services: generation, replicas, what wrote it
    isBad,             \* the generations that never turn ready
    S, R, K, P,        \* replicas by generation and state
    ro,                \* /rollouts
    hold,              \* a user's pause or resume, not yet applied
    spent,             \* what the replica controller spent of ro.b ("once")
    applies, users, faults,
    \* --- history, for the properties ---
    r1bad, r2bad, r4bad, r8bad

vars == <<gen, want, kind, isBad, S, R, K, P, ro, hold, spent,
          applies, users, faults, r1bad, r2bad, r4bad, r8bad>>

Monus(a, b) == IF a > b THEN a - b ELSE 0
Min(a, b) == IF a < b THEN a ELSE b
RECURSIVE Sum(_, _)
Sum(f, D) == IF D = {} THEN 0
             ELSE LET x == CHOOSE x \in D : TRUE IN f[x] + Sum(f, D \ {x})

Zero == [s |-> 0, r |-> 0, u |-> 0]
Old == Gens \ {gen}

\* The mix, as rollout_plan.zig counts it, with the service's generation new.
NewLive == S[gen] + R[gen] + K[gen] + P[gen]
OldLive == Sum(S, Old) + Sum(R, Old) + Sum(K, Old) + Sum(P, Old)
OldReady == Sum(R, Old)
OldStopping == Sum(P, Old)
Live == NewLive + OldLive
ReadyNow == R[gen] + OldReady
ReadyMin == Monus(want, MaxUnavail)
LiveMax == want + MaxSurge

\* rollout_plan.budget, rolling.
Budget ==
    [s |-> Min(Monus(LiveMax, Live), Monus(want, NewLive)),
     r |-> Min(OldReady, Monus(ReadyNow, ReadyMin)),
     u |-> IF RetireUnready THEN OldLive - OldStopping - OldReady ELSE 0]

Done == OldLive = 0 /\ R[gen] >= want

Init ==
    /\ gen = 1 /\ want = Want0 /\ kind = "apply"
    /\ S = [g \in Gens |-> 0] /\ K = [g \in Gens |-> 0] /\ P = [g \in Gens |-> 0]
    /\ hold = "none" /\ spent = Zero
    /\ applies = 0 /\ users = 0 /\ faults = 0
    /\ r1bad = FALSE /\ r2bad = FALSE /\ r4bad = FALSE /\ r8bad = FALSE
    /\ IF FirstGen
          THEN /\ isBad \in (IF BadReleases THEN {{}, {1}} ELSE {{}})
               /\ R = [g \in Gens |-> 0]
               /\ ro = [to |-> 1, from |-> 0, phase |-> "active",
                        reason |-> "apply", by |-> "none", owed |-> FALSE,
                        b |-> Zero]
          ELSE /\ isBad = {}
               /\ R = [g \in Gens |-> IF g = 1 THEN Want0 ELSE 0]
               /\ ro = [to |-> 1, from |-> 0, phase |-> "complete",
                        reason |-> "apply", by |-> "none", owed |-> FALSE,
                        b |-> Zero]

Reps == UNCHANGED <<S, R, K, P>>
Svc == UNCHANGED <<gen, want, kind, isBad>>
Ghosts == UNCHANGED <<r1bad, r2bad, r4bad, r8bad>>
Counts == UNCHANGED <<applies, users, faults>>

(***************************************************************************)
(* The user.                                                               *)
(***************************************************************************)
Apply(bad) ==
    /\ applies < MaxApplies
    /\ applies' = applies + 1
    /\ gen' = gen + 1 /\ kind' = "apply"
    /\ isBad' = IF bad THEN isBad \cup {gen + 1} ELSE isBad
    /\ Reps /\ Ghosts /\ UNCHANGED <<want, ro, hold, spent, users, faults>>

\* A scale does not make a generation.
Scale(w) ==
    /\ users < MaxUser /\ w # want
    /\ users' = users + 1 /\ want' = w
    /\ Reps /\ Ghosts
    /\ UNCHANGED <<gen, kind, isBad, ro, hold, spent, applies, faults>>

Ask(what) ==
    /\ users < MaxUser /\ hold = "none"
    /\ users' = users + 1 /\ hold' = what
    /\ Reps /\ Svc /\ Ghosts /\ UNCHANGED <<ro, spent, applies, faults>>

(***************************************************************************)
(* The rollout controller.                                                 *)
(***************************************************************************)
NextRo ==
    IF ro.to # gen
       THEN \* begin: a newer generation replaces the target, from any phase
            [to |-> gen, from |-> ro.to, phase |-> "active", reason |-> kind,
             by |-> "none", owed |-> FALSE, b |-> Budget]
       ELSE CASE ro.phase = "active" ->
                   IF Done THEN [ro EXCEPT !.phase = "complete", !.b = Zero]
                   ELSE IF hold = "pause"
                      THEN [ro EXCEPT !.phase = "paused", !.by = "user",
                                      !.b = Zero]
                      ELSE [ro EXCEPT !.b = Budget]
              [] ro.phase = "paused" ->
                   IF hold = "resume"
                      THEN [ro EXCEPT !.phase = "active", !.by = "none",
                                      !.b = Budget]
                      ELSE ro
              [] ro.phase = "failed" ->
                   IF hold = "pause"
                      THEN [ro EXCEPT !.phase = "paused", !.by = "failure",
                                      !.owed = FALSE]
                      ELSE ro
              [] OTHER -> ro

RoPass ==
    /\ NextRo # ro \/ hold # "none" \/ spent # Zero
    /\ ro' = NextRo /\ hold' = "none" /\ spent' = Zero
    /\ Reps /\ Svc /\ Ghosts /\ Counts

\* A failure: a new replica is not ready in time or is held, or the
\* progress deadline passes.  Done wins over failure.
Failing ==
    \/ K[gen] > 0
    \/ gen \in isBad /\ S[gen] > 0
    \/ UseDeadline

RoFail ==
    /\ ro.to = gen /\ ro.phase = "active" /\ ~Done /\ Failing
    /\ ro' = IF OnFailure = "rollback"
                THEN [ro EXCEPT !.phase = "failed", !.b = Zero,
                                !.owed = (ro.reason = "apply")]
                ELSE [ro EXCEPT !.phase = "paused", !.b = Zero,
                                !.by = "failure"]
    /\ spent' = Zero
    /\ Reps /\ Svc /\ Ghosts /\ Counts /\ UNCHANGED hold

\* The automatic rollback: the API's rollback handler, called with the
\* service revision the controller failed.  It makes a new generation with
\* the spec of the one before; a first generation has none and is refused.
Rollback ==
    /\ ro.phase = "failed" /\ ro.owed /\ ro.from # 0
    /\ RollbackCas => gen = ro.to
    /\ gen' = gen + 1 /\ kind' = "rollback"
    /\ isBad' = IF ro.from \in isBad THEN isBad \cup {gen + 1} ELSE isBad
    /\ r8bad' = (r8bad \/ gen # ro.to)
    /\ Reps /\ Counts /\ UNCHANGED <<want, ro, hold, spent, r1bad, r2bad, r4bad>>

(***************************************************************************)
(* The replica controller.                                                 *)
(***************************************************************************)
Allowed ==
    /\ CheckPhase => ro.phase = "active"
    /\ CheckTarget => ro.to = gen

Avail ==
    CASE Spend = "recheck" -> Budget
      [] Spend = "once" -> [s |-> Monus(ro.b.s, spent.s),
                            r |-> Monus(ro.b.r, spent.r),
                            u |-> Monus(ro.b.u, spent.u)]
      [] OTHER -> ro.b

Spent(f) == spent' = IF Spend = "once" THEN [spent EXCEPT ![f] = @ + 1]
                                       ELSE spent

RcStart ==
    /\ Allowed /\ Avail.s > 0
    /\ S' = [S EXCEPT ![gen] = @ + 1] /\ Spent("s")
    /\ r2bad' = (r2bad \/ Live + 1 > LiveMax)
    /\ r4bad' = (r4bad \/ ro.phase = "paused")
    /\ Svc /\ Counts /\ UNCHANGED <<R, K, P, ro, hold, r1bad, r8bad>>

RcRetire(g) ==
    /\ Allowed /\ Avail.r > 0 /\ g # gen /\ R[g] > 0
    /\ R' = [R EXCEPT ![g] = @ - 1] /\ P' = [P EXCEPT ![g] = @ + 1]
    /\ Spent("r")
    /\ r1bad' = (r1bad \/ ReadyNow - 1 < ReadyMin)
    /\ r4bad' = (r4bad \/ ro.phase = "paused")
    /\ Svc /\ Counts /\ UNCHANGED <<S, K, ro, hold, r2bad, r8bad>>

\* retire_unready: only a replica that is not ready when the controller
\* acts.
RcUnready(g) ==
    /\ Allowed /\ Avail.u > 0 /\ g # gen
    /\ \/ S[g] > 0 /\ S' = [S EXCEPT ![g] = @ - 1] /\ UNCHANGED K
       \/ K[g] > 0 /\ K' = [K EXCEPT ![g] = @ - 1] /\ UNCHANGED S
    /\ P' = [P EXCEPT ![g] = @ + 1] /\ Spent("u")
    /\ r4bad' = (r4bad \/ ro.phase = "paused")
    /\ Svc /\ Counts /\ UNCHANGED <<R, ro, hold, r1bad, r2bad, r8bad>>

\* Failure replacement never waits for the budget: fewer live replicas
\* than wanted and one is started, in any phase.  A stopping replica is
\* live until it is seen stopped.
RcReplace ==
    /\ (IF ReplaceCountsStopping THEN Live ELSE Live - Sum(P, Gens)) < want
    /\ S' = [S EXCEPT ![gen] = @ + 1]
    /\ r2bad' = (r2bad \/ Live + 1 > LiveMax)
    /\ Svc /\ Counts /\ UNCHANGED <<R, K, P, ro, hold, spent, r1bad, r4bad, r8bad>>

\* Outside a rollout a scale down stops the extra replicas, unready first.
RcTrim ==
    /\ ro.to = gen /\ ro.phase = "complete"
    /\ Live - P[gen] > want
    /\ \/ S[gen] > 0 /\ S' = [S EXCEPT ![gen] = @ - 1] /\ UNCHANGED <<R, K>>
       \/ S[gen] = 0 /\ K[gen] > 0 /\ K' = [K EXCEPT ![gen] = @ - 1]
          /\ UNCHANGED <<S, R>>
       \/ S[gen] = 0 /\ K[gen] = 0 /\ R[gen] > 0
          /\ R' = [R EXCEPT ![gen] = @ - 1] /\ UNCHANGED <<S, K>>
    /\ P' = [P EXCEPT ![gen] = @ + 1]
    /\ Svc /\ Counts /\ Ghosts /\ UNCHANGED <<ro, hold, spent>>

(***************************************************************************)
(* The agents and the faults.                                              *)
(***************************************************************************)
Ready(g) ==
    /\ S[g] > 0 /\ g \notin isBad
    /\ S' = [S EXCEPT ![g] = @ - 1] /\ R' = [R EXCEPT ![g] = @ + 1]
    /\ Svc /\ Counts /\ Ghosts /\ UNCHANGED <<K, P, ro, hold, spent>>

Stopped(g) ==
    /\ P[g] > 0
    /\ P' = [P EXCEPT ![g] = @ - 1]
    /\ Svc /\ Counts /\ Ghosts /\ UNCHANGED <<S, R, K, ro, hold, spent>>

\* A node is lost and its replica is marked lost (or it crashed for good).
Lose(g) ==
    /\ faults < MaxFaults /\ faults' = faults + 1
    /\ \/ S[g] > 0 /\ S' = [S EXCEPT ![g] = @ - 1] /\ UNCHANGED <<R, K, P>>
       \/ R[g] > 0 /\ R' = [R EXCEPT ![g] = @ - 1] /\ UNCHANGED <<S, K, P>>
       \/ K[g] > 0 /\ K' = [K EXCEPT ![g] = @ - 1] /\ UNCHANGED <<S, R, P>>
       \/ P[g] > 0 /\ P' = [P EXCEPT ![g] = @ - 1] /\ UNCHANGED <<S, R, K>>
    /\ Svc /\ Ghosts /\ UNCHANGED <<ro, hold, spent, applies, users>>

\* A ready replica turns unhealthy and stays so.
Sicken(g) ==
    /\ faults < MaxFaults /\ faults' = faults + 1
    /\ Sick = "any" \/ (Sick = "old" /\ g # gen)
    /\ R[g] > 0
    /\ R' = [R EXCEPT ![g] = @ - 1] /\ K' = [K EXCEPT ![g] = @ + 1]
    /\ Svc /\ Ghosts /\ UNCHANGED <<S, P, ro, hold, spent, applies, users>>

Rest == UNCHANGED vars

Next ==
    \/ \E b \in (IF BadReleases THEN BOOLEAN ELSE {FALSE}) : Apply(b)
    \/ \E w \in Wants : Scale(w)
    \/ Ask("pause") \/ Ask("resume")
    \/ RoPass \/ RoFail \/ Rollback
    \/ RcStart \/ RcReplace \/ RcTrim
    \/ \E g \in Gens : \/ RcRetire(g) \/ RcUnready(g)
                       \/ Ready(g) \/ Stopped(g) \/ Lose(g) \/ Sicken(g)
    \/ Rest

Spec == Init /\ [][Next]_vars

\* Liveness: the controllers and the agents keep running; the user and the
\* faults owe nothing.
Fairness ==
    /\ WF_vars(RoPass) /\ WF_vars(RoFail) /\ WF_vars(Rollback)
    /\ WF_vars(RcStart) /\ WF_vars(RcReplace) /\ WF_vars(RcTrim)
    /\ \A g \in Gens : /\ WF_vars(RcRetire(g)) /\ WF_vars(RcUnready(g))
                       /\ WF_vars(Ready(g)) /\ WF_vars(Stopped(g))
LiveSpec == Spec /\ Fairness

(***************************************************************************)
(* Properties.                                                             *)
(***************************************************************************)
RTypeOK ==
    /\ gen \in Gens /\ want \in Wants \cup {Want0}
    /\ ro.to \in Gens /\ ro.from \in 0..MaxGen
    /\ ro.phase \in {"active", "paused", "failed", "complete"}
    /\ hold \in {"none", "pause", "resume"}

\* R1 (min available): no retirement by a rollout leaves fewer ready
\* replicas than desired - max_unavailable, on the replica controller's
\* view when it acts.
R1_MinAvailable == ~r1bad

\* R1 as a state: with no fault and no scale, ready replicas never fall
\* below desired - max_unavailable once they have reached it.  (Checked
\* where MaxFaults = 0, Wants = {Want0} and FirstGen = FALSE.)
R1_ReadyFloor == ReadyNow >= ReadyMin

\* R2 (surge bound): no start leaves more live replicas than desired +
\* max_surge.
R2_SurgeBound == ~r2bad

\* R2 as a state.  (Checked where Wants = {Want0}.)
R2_LiveCeiling == Live <= LiveMax

\* R4 (pause holds): while /rollouts.phase is paused the rollout starts
\* and retires nothing.
R4_PauseHolds == ~r4bad

\* R4 as a state: a paused, failed or complete record carries no budget.
R4_NoBudgetAtRest == ro.phase # "active" => ro.b = Zero

\* R8 (user wins): an automatic rollback never replaces a newer apply.
R8_UserWins == ~r8bad

\* R7a: a rollout always ends: done, paused, or failed with its rollback
\* made (the rollback is then the rollout, and ends in its turn).
Ended ==
    /\ ro.to = gen
    /\ \/ ro.phase \in {"complete", "paused"}
       \/ ro.phase = "failed" /\ ~ro.owed
R7_RolloutEnds == <>[]Ended

\* R7b: a rollout that nothing stops completes.  (Checked where no release
\* is bad, nobody pauses, and the deadline does not pass.)
R7_Completes == <>[](ro.to = gen /\ ro.phase = "complete")

=============================================================================
