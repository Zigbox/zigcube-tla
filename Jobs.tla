-------------------------------- MODULE Jobs --------------------------------
(***************************************************************************)
(* Zigcube's jobs (docs/core.md, the checks J1 to J11; authority.md        *)
(* section 7), composed with the lease and fencing model of Fencing.tla.   *)
(* Written from the Zig sources at zigcube f7736a7: job_controller.zig,    *)
(* scheduler.zig (place_run, release_run), job_retention.zig and           *)
(* agent_jobs.zig.  Independent of the sim-c1 simulator.                   *)
(*                                                                         *)
(* One job name, through up to MaxInc incarnations: submitted, placed,     *)
(* claimed, started, ended, deleted by retention, and the name used        *)
(* again.  The run id is "<name>-job" in every incarnation, which is what  *)
(* makes reuse interesting.                                                *)
(*                                                                         *)
(* Every step of Fencing.tla is a step here, and the job state follows     *)
(* it: a write of /nodes/<node> ends the tenure that observations and the  *)
(* job's status were written under, a fence stops job containers, a        *)
(* reboot loses them.  An agent's job step is a step of its pass (InPass), *)
(* its reports are observed writes that compare the tenure, and a refused  *)
(* one begins the fence.                                                   *)
(*                                                                         *)
(* An assignment's epoch is its mod_revision.  The agent compares epochs   *)
(* for equality, and against the create_revision of the run ("older than   *)
(* the run being served", agent_jobs.zig is_stale_epoch).  Here an epoch   *)
(* is the number of the incarnation the assignment was written in: within  *)
(* one incarnation a node is assigned the run at most once, so equality is *)
(* exact, and "older than the run" is "of an earlier incarnation".         *)
(***************************************************************************)
EXTENDS Fencing

CONSTANTS
    MaxInc,          \* incarnations of the job name the model follows
    StartBy,         \* start_by_ms: ticks from creation to the latest start
    Deadline,        \* deadline_ms: ticks a container may run
    JobGrace,        \* the run's grace_ms: TERM to KILL
    \* --- what the environment may do ---
    AllowCancel,     \* a client may cancel the job
    JobExits,        \* the container may end by itself
    FetchSlow,       \* the input fetch may take time: a claim and its start
                     \* may be passes apart
    Placeable,       \* some node has room for the run
    AllowWipe,       \* a reboot may lose the state directory (start records)
    AllowDirLoss,    \* the state directory may be lost and the agent process
                     \* restarted with the machine and its containers still up
    ReleasePrompt,   \* the scheduler has released an ended run's assignment
                     \* by the time retention deletes the job
    \* --- the safeguards; FALSE takes one away (the "teeth" configs) ---
    ClaimFirst,         \* a start follows the committed claim
    NoRestart,          \* a run whose container ended is not started again
    WipeIsLost,         \* a claim with no start record is reported lost
    PlaceComparesRun,   \* a placement compares the run's revision
    EndingOnce,         \* a terminal status is never rewritten
    HonourStop,         \* the agent stops a container whose run has a stop
    EnforceDeadline,    \* the agent enforces the deadline
    DeadlineOffline,    \* ... also when it cannot reach the server
    ReportCurrentEpoch, \* a report names the run's current assignment
    EndLocally,         \* a run with no assignment here is not reported
    StopUnclaimed,      \* the controller stops a run not claimed by start_by
    CheckStaleEpoch     \* leftovers of an earlier job of the name are not
                        \* taken for the new run's

Terminal == {"exited", "failed", "cancelled"}
Stops == {"cancel", "unreach", "nostart"}

RanCap == Deadline + JobGrace + KillLatency + StopTime + 3
JtCap == JobGrace + KillLatency + 1
\* J1: overlap_ms_max less the simulator's granularity (sim_cluster.zig).
J1Bound == LostGrace + KillLatency + StopTime
\* J6: stop_bound_ms (sim_jobs.zig): the agent sees the stop at once and
\* stops within the grace, or it cannot reach the server and fences.
J6Bound == Max(JobGrace + KillLatency, FenceAt + StopTime + KillLatency)
\* J8: deadline_bound_ms with no clock error and no wedge.
J8Bound == Deadline + JobGrace + KillLatency

ASSUME /\ MaxInc \in Nat /\ MaxInc >= 1
       /\ StartBy \in Nat /\ Deadline \in Nat /\ JobGrace \in Nat

VARIABLES
    \* --- store ---
    jinc,       \* incarnations of the name so far; the current one's number
    job,        \* /jobs/<name>: "none", "live", "cancel" (cancel requested)
    run,        \* /job-runs/<id>: "none", "live", or its stop's cause
    jst,        \* /job-status/<name>: [st, n, ep, ten]: the state; for
                \* "running", the node, epoch and tenure of the claim (ten:
                \* that tenure is still the current revision of /nodes/<n>)
    jasg,       \* [Agents -> 0..MaxInc]: /assigned/<node>/<id>, 0: absent,
                \* else its epoch
    jo,         \* [Agents -> None or [st, ep, ten, mine, exit, cause]]:
                \* /job-observed/<node>/<name>.  ten: its tenure is the
                \* current revision of /nodes/<node>; mine: it is the tenure
                \* the agent holds in memory
    jplan,      \* the scheduler's placement between read and commit
    \* --- agent ---
    jrec,       \* [Agents -> None or [ep, ph, cause]]: the start record
    jc,         \* [Agents -> [st, ep]]: the run's container: "none", "run",
                \* "stopping" (TERM sent), "done" (ended, still listed), and
                \* the epoch on its label
    jt,         \* agent-clock ticks since TERM
    ran,        \* agent-clock ticks since the container started
    \* --- history ---
    sub,        \* ticks since the job was created, while nothing started
    starts,     \* starts of the run in this incarnation (the J2 ledger)
    firstEnd,   \* the first terminal state this incarnation's status had
    after,      \* ticks a container has run since its job ended
    stopAge,    \* ticks a container has run since its run's stop committed
    jbad        \* the things that must never happen, if any did

jStore == <<jinc, job, run, jst, jasg, jo, jplan>>
jAgent == <<jrec, jc, jt, ran>>
jHist == <<sub, starts, firstEnd, after, stopAge, jbad>>
jvars == <<jStore, jAgent, jHist>>
allvars == <<vars, jvars>>

NoStatus == [st |-> "none", n |-> None, ep |-> 0, ten |-> FALSE]
NoCont == [st |-> "none", ep |-> 0]
Live(a) == jc[a].st \in {"run", "stopping"}
Unassigned == \A n \in Agents : jasg[n] = 0

JInit ==
    /\ Init
    /\ jinc = 0 /\ job = "none" /\ run = "none" /\ jst = NoStatus
    /\ jasg = [n \in Agents |-> 0]
    /\ jo = [n \in Agents |-> None]
    /\ jplan = None
    /\ jrec = [a \in Agents |-> None]
    /\ jc = [a \in Agents |-> NoCont]
    /\ jt = [a \in Agents |-> 0]
    /\ ran = [a \in Agents |-> 0]
    /\ sub = 0 /\ starts = 0 /\ firstEnd = "none"
    /\ after = [a \in Agents |-> 0]
    /\ stopAge = [a \in Agents |-> 0]
    /\ jbad = {}

(***************************************************************************)
(* What a step of Fencing.tla does to the job state.                       *)
(***************************************************************************)
\* /nodes/<n> is written exactly when keyL changes; an agent's tenure in
\* memory changes exactly when myLease does.
FollowStore ==
    /\ jo' = [n \in Agents |->
                IF jo[n] = None THEN None
                ELSE [jo[n] EXCEPT !.ten = @ /\ keyL'[n] = keyL[n],
                                   !.mine = @ /\ myLease'[n] = myLease[n]]]
    /\ jst' = IF jst.n = None THEN jst
              ELSE [jst EXCEPT !.ten = @ /\ keyL'[jst.n] = keyL[jst.n]]
    /\ jplan' = IF jplan = None THEN None
                ELSE [jplan EXCEPT !.ok = /\ @
                                          /\ keyL'[jplan.n] = keyL[jplan.n]
                                          /\ status'[jplan.n] = status[jplan.n]
                                          /\ statusCur'[jplan.n] = statusCur[jplan.n]]
Follow == FollowStore /\ UNCHANGED <<jinc, job, run, jasg, jAgent, jHist>>

(***************************************************************************)
(* The agent's pass over the run (agent_jobs.zig, Work.one).               *)
(***************************************************************************)
\* is_stale_epoch: older than the run being served.
StaleE(e) == CheckStaleEpoch /\ run # "none" /\ e < jinc
StaleRec(a) == jrec[a] # None /\ StaleE(jrec[a].ep)
StaleCont(a) == jc[a].st # "none" /\ StaleE(jc[a].ep)
Clean(a) == ~StaleRec(a) /\ ~StaleCont(a)
\* seen_of: the node's observation, unless it is an earlier job's.
Seen(a) == jo[a] # None /\ ~StaleE(jo[a].ep)
SeenStopped(a) == Seen(a) /\ jo[a].st = "stopped"

\* Every job step of an agent leaves the lease and fencing state alone.
AgentOnly == UNCHANGED <<vars, jinc, job, run, jst, jasg, jplan, sub, firstEnd,
                         after, stopAge>>
SetCont(a, c) == /\ jc' = [jc EXCEPT ![a] = c]
                 /\ jt' = [jt EXCEPT ![a] = 0]
                 /\ ran' = [ran EXCEPT ![a] = 0]
\* An observed write: compared against the tenure (job_report, job_claim).
CanWrite(a) == tenureOk[a] \/ ~CompareTenure
Observe(a, st, ep, exit, cause) ==
    /\ jo' = [jo EXCEPT ![a] = [st |-> st, ep |-> ep, ten |-> tenureOk[a],
                                mine |-> TRUE, exit |-> exit, cause |-> cause]]
    /\ jbad' = jbad \cup (IF ep = jasg[a] THEN {} ELSE {"stale_report"})

\* A record, a container or both of an earlier job of this name: the
\* record counts as absent, the container is not this run's, and one still
\* running is stopped with no grace (stop_stale).
DropStaleG(a) == StaleRec(a) \/ StaleCont(a)
JDropStale(a) ==
    /\ InPass(a) /\ DropStaleG(a)
    /\ jrec' = [jrec EXCEPT ![a] = IF StaleRec(a) THEN None ELSE @]
    /\ IF StaleCont(a) THEN SetCont(a, NoCont) ELSE UNCHANGED <<jc, jt, ran>>
    /\ UNCHANGED <<jo, starts, jbad>> /\ AgentOnly

\* claim: the `claiming` record, the claim, the `claimed` record, the
\* start.  The claim compares the tenure, the run and the assignment at the
\* subject's epoch.  mode "rec": the agent stopped after the record (a
\* crash); "commit": after the claim (the input is not there yet, or the
\* reply was lost); "start": all of it in one pass; "early": the tooth.
ClaimG(a) ==
    /\ Clean(a) /\ jc[a].st = "none" /\ ~Seen(a)
    /\ jasg[a] # 0 /\ run = "live"
    /\ IF jrec[a] = None THEN TRUE ELSE jrec[a].ph = "claiming"
StartCount == starts' = Min(starts + 1, 2)
JClaim(a, mode) ==
    /\ InPass(a) /\ ClaimG(a)
    /\ LET e == jasg[a] IN
       \/ /\ mode = "rec" /\ jrec[a] = None /\ AllowReboot
          /\ jrec' = [jrec EXCEPT ![a] = [ep |-> e, ph |-> "claiming", cause |-> "none"]]
          /\ UNCHANGED <<jo, jc, jt, ran, starts, jbad>>
       \/ /\ mode = "commit" /\ CanWrite(a)
          /\ jrec' = [jrec EXCEPT ![a] = [ep |-> e, ph |-> "claiming", cause |-> "none"]]
          /\ Observe(a, "claimed", e, "none", "none")
          /\ UNCHANGED <<jc, jt, ran, starts>>
       \/ /\ mode = "start" /\ CanWrite(a) /\ sub <= StartBy
          /\ jrec' = [jrec EXCEPT ![a] = [ep |-> e, ph |-> "claimed", cause |-> "none"]]
          /\ Observe(a, "claimed", e, "none", "none")
          /\ SetCont(a, [st |-> "run", ep |-> e])
          /\ StartCount
       \/ /\ mode = "early" /\ ~ClaimFirst
          /\ jrec' = [jrec EXCEPT ![a] = [ep |-> e, ph |-> "claimed", cause |-> "none"]]
          /\ SetCont(a, [st |-> "run", ep |-> e])
          /\ StartCount
          /\ jbad' = jbad \cup {"start_unclaimed"}
          /\ UNCHANGED jo
    /\ AgentOnly

\* unclaimed: a `claiming` record, no observation and no assignment: a
\* leaked record, removed.
UnclaimedDropG(a) ==
    /\ Clean(a) /\ jrec[a] # None /\ jrec[a].ph = "claiming"
    /\ jc[a].st = "none" /\ ~Seen(a) /\ jasg[a] = 0
\* claimed_unstarted: a `claiming` record, a `claimed` observation and no
\* container.  Started now if the claim is this tenure's and this epoch's
\* and the run has no stop; reported as not started otherwise, or past the
\* bound of the input fetch.
HeldG(a) ==
    /\ Clean(a) /\ jrec[a] # None /\ jrec[a].ph = "claiming"
    /\ jc[a].st = "none" /\ Seen(a) /\ jo[a].st = "claimed"
MineG(a) ==
    /\ HeldG(a) /\ jasg[a] # 0 /\ jo[a].mine
    /\ jo[a].ep = jrec[a].ep /\ jrec[a].ep = jasg[a] /\ run = "live"
    /\ sub <= StartBy
JBegin(a) ==
    /\ InPass(a) /\ MineG(a)
    /\ jrec' = [jrec EXCEPT ![a].ph = "claimed"]
    /\ SetCont(a, [st |-> "run", ep |-> jrec[a].ep])
    /\ StartCount
    /\ UNCHANGED <<jo, jbad>> /\ AgentOnly
NotStartedG(a) == HeldG(a) /\ ~MineG(a)

\* gone: a start record and no container, and it is not one of the cases
\* above: the run is reported lost under its current assignment.
GoneG(a) ==
    /\ Clean(a) /\ jrec[a] # None /\ jc[a].st = "none"
    /\ jrec[a].ph = "claimed" \/ SeenStopped(a)
\* unknown: a container or a claim and no start record.  A running
\* container is stopped; the run is reported lost, or with the exit of a
\* container that has ended.
UnknownG(a) == Clean(a) /\ jrec[a] = None /\ (jc[a].st # "none" \/ Seen(a))
\* stopped: a start record and a container that has ended.
StoppedG(a) == Clean(a) /\ jrec[a] # None /\ jc[a].st = "done"

\* The cases that end in a report of `stopped`, and what it says.
ReportG(a) ==
    /\ NotStartedG(a) \/ GoneG(a) \/ UnknownG(a) \/ StoppedG(a)
    /\ ~SeenStopped(a)
ReportExit(a) == IF jc[a].st = "done" THEN "exit" ELSE "lost"
ReportCause(a) == IF NotStartedG(a) THEN "nostart"
                  ELSE IF jrec[a] # None THEN jrec[a].cause ELSE "none"
\* report_epoch: the run's current assignment on this node, and none for a
\* run that has no assignment here: it ends on this node.
JReport(a) ==
    /\ InPass(a) /\ ReportG(a) /\ jasg[a] # 0 /\ CanWrite(a)
    /\ Observe(a, "stopped", jasg[a], ReportExit(a), ReportCause(a))
    /\ UNCHANGED <<jrec, jc, jt, ran, starts>> /\ AgentOnly
\* No assignment here: nothing is reported; the record goes once the
\* container has ended (not_started, gone, stopped).
LocalG(a) ==
    /\ jasg[a] = 0
    /\ UnclaimedDropG(a) \/ NotStartedG(a) \/ GoneG(a) \/ StoppedG(a)
JEndLocally(a) ==
    /\ InPass(a) /\ LocalG(a)
    /\ \/ /\ EndLocally \/ ~StoppedG(a)
          /\ ReportCurrentEpoch \/ ~StoppedG(a)
          /\ jrec' = [jrec EXCEPT ![a] = None]
          /\ SetCont(a, NoCont)
          /\ UNCHANGED <<jo, jbad>>
       \/ \* tooth: reported under the epoch it was started under, with no
          \* compare of the assignment
          /\ ~ReportCurrentEpoch /\ StoppedG(a) /\ CanWrite(a) /\ ~SeenStopped(a)
          /\ Observe(a, "stopped", jrec[a].ep, "exit", jrec[a].cause)
          /\ UNCHANGED <<jrec, jc, jt, ran>>
       \/ \* tooth: the same report, compared, refused, and made again
          /\ ~EndLocally /\ StoppedG(a) /\ "refused_report" \notin jbad
          /\ jbad' = jbad \cup {"refused_report"}
          /\ UNCHANGED <<jo, jrec, jc, jt, ran>>
    /\ UNCHANGED starts /\ AgentOnly

\* The teeth that start a run again: a container that ended with no stop
\* cause (job_restart); a claim with no start record (job_wipe).
JRestart(a) ==
    /\ InPass(a) /\ run # "none"
    /\ \/ ~NoRestart /\ StoppedG(a) /\ jrec[a].cause = "none"
       \/ /\ ~WipeIsLost /\ Clean(a) /\ jrec[a] = None /\ jc[a].st = "none"
          /\ Seen(a) /\ jasg[a] # 0 /\ run = "live"
    /\ jrec' = [jrec EXCEPT ![a] = [ep |-> IF jasg[a] # 0 THEN jasg[a] ELSE jc[a].ep,
                                    ph |-> "claimed", cause |-> "none"]]
    /\ SetCont(a, [st |-> "run", ep |-> IF jasg[a] # 0 THEN jasg[a] ELSE jc[a].ep])
    /\ StartCount
    /\ UNCHANGED <<jo, jbad>> /\ AgentOnly

\* running: why a running container is stopped now (cause_to_stop): the
\* server's stop, the deadline, or a run the server no longer serves.
StopCause(a) ==
    IF run \in Stops /\ HonourStop THEN run
    ELSE IF EnforceDeadline /\ ran[a] >= Deadline THEN "deadline"
    ELSE IF run = "none" THEN "unreach" ELSE "none"
StopG(a) ==
    /\ Clean(a) /\ jc[a].st = "run"
    /\ jrec[a] = None \/ StopCause(a) # "none"
Term(a, cause) ==
    /\ jc' = [jc EXCEPT ![a].st = "stopping"]
    /\ jt' = [jt EXCEPT ![a] = 0]
    /\ jrec' = [jrec EXCEPT ![a] =
                  IF @ # None /\ @.cause = "none"
                  THEN [@ EXCEPT !.cause = cause, !.ph = "claimed"] ELSE @]
    /\ UNCHANGED <<jo, ran, starts, jbad>> /\ AgentOnly
JStop(a) == InPass(a) /\ StopG(a) /\ Term(a, IF jrec[a] = None THEN "none" ELSE StopCause(a))
\* The deadline needs no server: it is enforced from the start record
\* before every store call (Agent.before_call).
DeadlineG(a) ==
    /\ EnforceDeadline /\ jrec[a] # None /\ jc[a].st = "run" /\ ran[a] >= Deadline
JDeadline(a) ==
    /\ CanAct(a) /\ DeadlineOffline /\ ~InPass(a) /\ DeadlineG(a)
    /\ Term(a, "deadline")

\* The container ends: by itself, on the TERM or on the KILL.
JExit(a) ==
    /\ ~wedged[a]
    /\ (JobExits /\ jc[a].st = "run") \/ jc[a].st = "stopping"
    /\ SetCont(a, [jc[a] EXCEPT !.st = "done"])
    /\ UNCHANGED <<jo, jrec, starts, jbad>> /\ AgentOnly
\* The fence stops job containers with the others; note_fence records the
\* cause first.
JFenceKill(a) ==
    /\ ~wedged[a] /\ phase[a] = "fencing" /\ Live(a)
    /\ SetCont(a, [jc[a] EXCEPT !.st = "done"])
    /\ jrec' = [jrec EXCEPT ![a] =
                  IF @ # None /\ @.cause = "none" THEN [@ EXCEPT !.cause = "fence"] ELSE @]
    /\ UNCHANGED <<jo, starts, jbad>> /\ AgentOnly

\* A write that the store refuses for the tenure begins the fence.
WriteDue(a) == ClaimG(a) \/ (ReportG(a) /\ jasg[a] # 0)
JConflict(a) ==
    /\ InPass(a) /\ ~CanWrite(a) /\ WriteDue(a)
    /\ Told(a) /\ FenceFrom(a, age[a])
    /\ UNCHANGED <<wedged, age, lost, callLost, myLease, tenureOk, callKind, callSt,
                   callL, callAge, pendOk, stale, cont, stop, storeVars, healed,
                   jumped, ovl, bad, jvars>>

JobPassDue(a) ==
    \/ DropStaleG(a) \/ ClaimG(a) \/ LocalG(a) \/ StopG(a)
    \/ (ReportG(a) /\ jasg[a] # 0)
    \/ (MineG(a) /\ ~FetchSlow)
JobUrgent(a) ==
    /\ ~wedged[a]
    /\ \/ (InPass(a) /\ JobPassDue(a))
       \/ (jc[a].st = "stopping" /\ jt[a] >= JobGrace + KillLatency)
       \/ (phase[a] = "fencing" /\ Live(a)
           /\ age[a] >= killAge[a] + KillLatency + StepMax)
       \/ (DeadlineOffline /\ ~InPass(a) /\ DeadlineG(a))

JobAgentStep(a) ==
    \/ JDropStale(a) \/ JBegin(a) \/ JReport(a) \/ JEndLocally(a) \/ JRestart(a)
    \/ JStop(a) \/ JDeadline(a) \/ JExit(a) \/ JFenceKill(a) \/ JConflict(a)
    \/ \E mode \in {"rec", "commit", "start", "early"} : JClaim(a, mode)

(***************************************************************************)
(* Agent faults.                                                           *)
(***************************************************************************)
\* The machine restarts: the containers are gone; the start records stay,
\* or go with the state directory.
JReboot(a, wipe) ==
    /\ Reboot(a) /\ (wipe => AllowWipe)
    /\ FollowStore
    /\ SetCont(a, NoCont)
    /\ jrec' = [jrec EXCEPT ![a] = IF wipe THEN None ELSE @]
    /\ UNCHANGED <<jinc, job, run, jasg, jHist>>

\* The state directory is lost and the agent process starts again on the
\* same boot: no lease file, so nothing is fenced ("first start or a
\* finished fence", agent.zig restore), no start records, and every
\* container still runs.
JDirLoss(a) ==
    /\ AllowDirLoss /\ ~healed /\ ~wedged[a] /\ a \in Faulty /\ phase[a] = "held"
    /\ phase' = [phase EXCEPT ![a] = "idle"]
    /\ myLease' = [myLease EXCEPT ![a] = 0]
    /\ tenureOk' = [tenureOk EXCEPT ![a] = FALSE]
    /\ age' = [age EXCEPT ![a] = 0]
    /\ lost' = [lost EXCEPT ![a] = 0]
    /\ killAge' = [killAge EXCEPT ![a] = 0]
    /\ IF callKind[a] # "none" THEN Abandon(a)
       ELSE UNCHANGED <<callKind, callSt, callL, callAge, callLost, pendOk, stale>>
    /\ UNCHANGED <<wedged, cont, stop, storeVars, histVars>>
    /\ FollowStore
    /\ jrec' = [jrec EXCEPT ![a] = None]
    /\ UNCHANGED <<jinc, job, run, jasg, jc, jt, ran, jHist>>

(***************************************************************************)
(* The server: the API, the job controller (job_controller.zig), the       *)
(* scheduler's part (scheduler.zig) and retention (job_retention.zig).     *)
(* Each controller transaction compares all it read, so each is one step.  *)
(***************************************************************************)
ServerOnly == UNCHANGED <<vars, jAgent, after, stopAge>>
Open == jst.st \in {"pending", "running"}

\* POST /v1/jobs, and the controller's create: the run and the status.
Submit ==
    /\ job = "none" /\ jst.st = "none" /\ jinc < MaxInc
    /\ jinc' = jinc + 1
    /\ job' = "live" /\ run' = "live"
    /\ jst' = [NoStatus EXCEPT !.st = "pending"]
    /\ sub' = 0 /\ starts' = 0 /\ firstEnd' = "none"
    /\ UNCHANGED <<jasg, jo, jplan, jbad>> /\ ServerOnly
Cancel ==
    /\ AllowCancel /\ job = "live" /\ Open
    /\ job' = "cancel"
    /\ UNCHANGED <<jinc, run, jst, jasg, jo, jplan, jHist>> /\ UNCHANGED <<vars, jAgent>>

\* admissible (authority.md section 3): tenure current, assignment
\* current and on that node, node ready.
JAdm(n) == /\ jo[n] # None /\ jo[n].ten
           /\ jasg[n] # 0 /\ jo[n].ep = jasg[n]
           /\ NodeReady(n)
\* map_ending: the stop cause first, then the exit.
MapEnd(o) == IF o.cause = "cancel" THEN "cancelled"
             ELSE IF o.cause # "none" THEN "failed"
             ELSE IF o.exit = "exit" THEN "exited" ELSE "failed"
End(s) == /\ jst' = [jst EXCEPT !.st = s]
          /\ firstEnd' = IF firstEnd = "none" THEN s ELSE firstEnd
          /\ UNCHANGED <<jinc, job, run, jasg, jo, jplan, sub, starts, jbad>>
          /\ ServerOnly
\* The tenure a claim or a running status names has ended: the node is
\* lost for lost_grace_ms, or its key was written again.  (The code waits
\* lost_grace_ms from when it first saw the key change; here it does not.)
TenureEnded(n, tenOk) ==
    /\ ~tenOk
    /\ keyL[n] = 0 => (status[n] = "lost" /\ lostAge[n] >= LostGrace)

\* end: an admissible report of `stopped`.
CEndReport(n) ==
    /\ Open /\ JAdm(n) /\ jo[n].st = "stopped"
    /\ End(MapEnd(jo[n]))
\* late_report: a report that arrives after the ending is dropped.  The
\* tooth rewrites the status from it.
CLateReport(n) ==
    /\ ~EndingOnce /\ jst.st \in Terminal /\ JAdm(n) /\ jo[n].st = "stopped"
    /\ MapEnd(jo[n]) # jst.st
    /\ jst' = [jst EXCEPT !.st = MapEnd(jo[n])]
    /\ UNCHANGED <<jinc, job, run, jasg, jo, jplan, jHist>> /\ UNCHANGED <<vars, jAgent>>
\* mark_running: an admissible claim.
CMarkRunning(n) ==
    /\ jst.st = "pending" /\ JAdm(n) /\ jo[n].st = "claimed"
    /\ jst' = [st |-> "running", n |-> n, ep |-> jo[n].ep, ten |-> TRUE]
    /\ UNCHANGED <<jinc, job, run, jasg, jo, jplan, jHist>> /\ UNCHANGED <<vars, jAgent>>
\* A report that the fence stopped the run, from the node the status
\* names, is taken though it is not admissible.
CEndFenced(n) ==
    /\ jst.st = "running" /\ jst.n = n /\ jo[n] # None /\ ~JAdm(n)
    /\ jo[n].st = "stopped" /\ jo[n].cause = "fence" /\ jo[n].ep = jst.ep
    /\ End("failed")
\* write_stop, cancel: whatever the run's state, while it has no stop.
CStopCancel ==
    /\ Open /\ job = "cancel" /\ run = "live"
    /\ run' = "cancel"
    /\ UNCHANGED <<jinc, job, jst, jasg, jo, jplan, jHist>> /\ UNCHANGED <<vars, jAgent>>
\* judge_running, judge_claimed: the claim's tenure has ended.
CEndUnreachable ==
    /\ \/ jst.st = "running" /\ TenureEnded(jst.n, jst.ten)
       \/ /\ jst.st = "pending"
          /\ \E n \in Agents : /\ jasg[n] # 0 /\ jo[n] # None /\ ~JAdm(n)
                               /\ TenureEnded(n, jo[n].ten)
    /\ End("failed")
\* judge_unclaimed: no claim is seen on the node the run is assigned to.
NoClaim == \A n \in Agents : jasg[n] # 0 => jo[n] = None
CEndUnstarted ==
    /\ jst.st = "pending" /\ NoClaim /\ run \in Stops
    /\ End(IF run = "cancel" THEN "cancelled" ELSE "failed")
CStopUnclaimed ==
    /\ jst.st = "pending" /\ NoClaim /\ run = "live"
    /\ \/ StopUnclaimed /\ sub > StartBy /\ run' = "nostart"
       \/ /\ \E n \in Agents : /\ jasg[n] # 0 /\ status[n] = "lost"
                               /\ lostAge[n] >= LostGrace
          /\ run' = "unreach"
    /\ UNCHANGED <<jinc, job, jst, jasg, jo, jplan, jHist>> /\ UNCHANGED <<vars, jAgent>>

\* place_run: a pending job whose run has no stop and no assignment.  The
\* commit compares the node, its status, the job's status, the run and the
\* absence of an assignment.
SPlan(n) ==
    /\ Placeable /\ jplan = None
    /\ jst.st = "pending" /\ run = "live" /\ Unassigned /\ NodeReady(n)
    /\ jplan' = [n |-> n, inc |-> jinc, ok |-> TRUE]
    /\ UNCHANGED <<jinc, job, run, jst, jasg, jo, jHist>> /\ UNCHANGED <<vars, jAgent>>
SCommit ==
    /\ jplan # None
    /\ LET p == jplan
           pass == /\ CompareReady => p.ok
                   /\ p.inc = jinc /\ jst.st = "pending" /\ Unassigned
                   /\ PlaceComparesRun => run = "live"
       IN IF pass
          THEN /\ jasg' = [jasg EXCEPT ![p.n] = jinc]
               /\ jbad' = jbad \cup (IF run = "live" THEN {} ELSE {"placed_after_stop"})
          ELSE UNCHANGED <<jasg, jbad>>
    /\ jplan' = None
    /\ UNCHANGED <<jinc, job, run, jst, jo, sub, starts, firstEnd>> /\ ServerOnly
\* release_run: the job is over, or gone with its status.
SRelease(n) ==
    /\ jasg[n] # 0
    /\ jst.st \in Terminal \/ (job = "none" /\ jst.st = "none")
    /\ jasg' = [jasg EXCEPT ![n] = 0]
    /\ UNCHANGED <<jinc, job, run, jst, jo, jplan, jHist>> /\ UNCHANGED <<vars, jAgent>>

\* drop_job: the job, its run, its status and its observations, in one
\* transaction that compares the status only.  It runs an hour or more
\* after the ending (job_finished_age_ms_min), which no model of ticks
\* spans: here it may run once every call has been answered or given up
\* and every fence and stop has finished.  The assignment is not among
\* the keys it reads or deletes.
Quiet == \A a \in Agents : /\ callKind[a] = "none" /\ phase[a] # "fencing"
                           /\ ~Live(a) /\ ~Urgent(a) /\ ~JobUrgent(a)
Retention ==
    /\ jst.st \in Terminal /\ Quiet
    /\ ReleasePrompt => Unassigned
    /\ job' = "none" /\ run' = "none" /\ jst' = NoStatus
    /\ jo' = [n \in Agents |-> None]
    /\ UNCHANGED <<jinc, jasg, jplan, jHist>> /\ UNCHANGED <<vars, jAgent>>

JobServerStep ==
    \/ Submit \/ Cancel \/ CStopCancel \/ CEndUnreachable \/ CEndUnstarted
    \/ CStopUnclaimed \/ SCommit \/ Retention
    \/ \E n \in Agents : \/ CEndReport(n) \/ CLateReport(n) \/ CMarkRunning(n)
                         \/ CEndFenced(n) \/ SPlan(n) \/ SRelease(n)

(***************************************************************************)
(* Time, and the whole system.                                             *)
(***************************************************************************)
\* A container that runs though its job is over.
Over(a) == jc[a].ep < jinc \/ jst.st \notin {"pending", "running"}
JTick(skip) ==
    /\ \A a \in Agents : ~JobUrgent(a)
    /\ Tick(skip)
    /\ ran' = [a \in Agents |->
                 IF Live(a) /\ a # skip /\ ~wedged[a] THEN Min(ran[a] + 1, RanCap)
                 ELSE ran[a]]
    /\ jt' = [a \in Agents |->
                IF jc[a].st = "stopping" /\ a # skip /\ ~wedged[a]
                THEN Min(jt[a] + 1, JtCap) ELSE jt[a]]
    /\ sub' = IF Open /\ starts = 0 THEN Min(sub + 1, StartBy + 1) ELSE sub
    /\ after' = [a \in Agents |->
                   IF Live(a) /\ ~wedged[a] /\ Over(a)
                   THEN Min(after[a] + 1, J1Bound + 1) ELSE 0]
    /\ stopAge' = [a \in Agents |->
                     IF Live(a) /\ ~wedged[a] /\ run \in Stops /\ jc[a].ep = jinc
                     THEN Min(stopAge[a] + 1, J6Bound + 1) ELSE 0]
    /\ UNCHANGED <<jStore, jrec, jc, starts, firstEnd, jbad>>

\* Every step of Fencing.tla but the three that job containers change.
FencingStep ==
    \/ \E a \in Agents :
          \/ Register(a) \/ Renew(a) \/ Ack(a) \/ Nack(a) \/ TimerFence(a)
          \/ CallTimeout(a) \/ NetStep(a) \/ CallLost(a) \/ Wedge(a)
          \/ (Fenced(a) /\ ~Live(a))
          \/ \E s \in Slots : \/ Start(a, s) \/ Report(a, s) \/ Forget(a, s)
                              \/ StopTerm(a, s) \/ StrayExit(a, s) \/ ContExit(a, s)
    \/ ServerStep
    \/ \E n \in Agents, s \in Slots : Decide(n, s)
    \/ StoreSetback
    \/ Heal

JNext ==
    \/ FencingStep /\ Follow
    \/ \E a \in Agents : JobAgentStep(a)
    \/ JobServerStep
    \/ \E a \in Agents : JReboot(a, FALSE) \/ JReboot(a, TRUE) \/ JDirLoss(a)
    \/ \E skip \in Agents \cup {None} : JTick(skip)

JSpec == JInit /\ [][JNext]_allvars

JFairness ==
    /\ WF_allvars(\E skip \in Agents \cup {None} : JTick(skip))
    /\ \A a \in Agents :
          /\ WF_allvars(AgentStep(a) /\ Follow)
          /\ WF_allvars(NetStep(a) /\ Follow)
          /\ WF_allvars(CallTimeout(a) /\ Follow)
          /\ WF_allvars(JobAgentStep(a))
          /\ WF_allvars((Expire(a) \/ MarkReady(a) \/ MarkLost(a)) /\ Follow)
          /\ WF_allvars(CEndReport(a) \/ CMarkRunning(a) \/ CEndFenced(a))
          /\ WF_allvars(SPlan(a))
    /\ WF_allvars(CStopCancel \/ CEndUnreachable \/ CEndUnstarted \/ CStopUnclaimed)
    /\ WF_allvars(SCommit)
JLiveSpec == JSpec /\ JFairness

(***************************************************************************)
(* Properties.  The J-numbers are those of docs/core.md.                   *)
(***************************************************************************)
JTypeOK ==
    /\ jinc \in 0..MaxInc
    /\ job \in {"none", "live", "cancel"}
    /\ run \in {"none", "live"} \cup Stops
    /\ jst.st \in {"none", "pending", "running"} \cup Terminal
    /\ jasg \in [Agents -> 0..MaxInc]
    /\ \A a \in Agents :
          /\ jc[a].st \in {"none", "run", "stopping", "done"}
          /\ jt[a] \in 0..JtCap /\ ran[a] \in 0..RanCap
          /\ jrec[a] # None => jrec[a].ph \in {"claiming", "claimed"}
          /\ jo[a] # None => jo[a].st \in {"claimed", "stopped"}
    /\ starts \in 0..2 /\ sub \in 0..(StartBy + 1)
    /\ (job = "none") = (run = "none") /\ (job = "none") = (jst.st = "none")

\* J1. A job container is not alive more than overlap_ms_max after its job
\* reached a terminal status (not judged on a wedged node).
J1_NotAliveAfterEnding == \A a \in Agents : after[a] <= J1Bound
\* J2. No run id is started twice, in any node and any agent life (per
\* incarnation, as in the simulator's reuse world).
J2_StartedOnce == starts <= 1
\* J3. A terminal status never changes to another status.  (That it is
\* deleted only with its job holds by construction: see JTypeOK.)
J3_EndingStands == jst.st \in Terminal => jst.st = firstEnd
\* J5. A run, once its stop is committed, is never assigned again; and a
\* run has one assignment.
J5_AssignedOnce ==
    /\ "placed_after_stop" \notin jbad
    /\ Cardinality({n \in Agents : jasg[n] = jinc /\ jinc > 0}) <= 1
\* J6. A container runs no longer than stop_bound_ms after its run's stop
\* committed.
J6_StopHonoured == \A a \in Agents : stopAge[a] <= J6Bound
\* J7. Each start has a committed claim of this run, tenure and epoch, and
\* the run has no stop.  As a state predicate: a container that has just
\* been started (no tick since) stands on such a claim.
J7_StartHasClaim ==
    /\ "start_unclaimed" \notin jbad
    /\ \A a \in Agents :
          (jc[a].st = "run" /\ ran[a] = 0 /\ jrec[a] # None /\ run # "none")
             => /\ jo[a] # None /\ jo[a].ep = jc[a].ep
                /\ jasg[a] = jc[a].ep
\* J8. A container runs no longer than deadline_bound_ms.
J8_Deadline == \A a \in Agents : Live(a) /\ ~wedged[a] => ran[a] <= J8Bound
\* J8, second clause: after the heal no run stays open.
J8_RunsEnd == (<>healed) => <>[](~Open)
\* J9. A report is stored only under the run's stored assignment.
J9_ReportUnderAssignment == "stale_report" \notin jbad
\* J10. No report is made again and again that the store refuses.
J10_NoRefusedLoop == "refused_report" \notin jbad
\* J11. A status of `exited` is of a run that some node started in its own
\* incarnation.
J11_ExitedWasStarted == jst.st = "exited" => starts >= 1
=============================================================================
