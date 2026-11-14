# zigcube-tla

A TLA+ model of Zigcube's lease, fencing and authority protocol, checked with
TLC. It is the model that `docs/authority.md` (end of section 4) asks for
before C7.

It was written from `docs/authority.md`, the decisions of 2026-10-27,
2026-10-30, 2026-11-06, 2026-11-08 and 2026-11-12, and the Zig sources
(`src/fencing.zig`, `src/agent.zig`, `src/agent_api.zig`,
`src/node_controller.zig`, `src/replica_controller.zig`,
`src/store_postgres.zig`) at Zigcube commit `f7736a7`. It does not use the
sim-c1 simulator and shares nothing with it.

`Jobs.tla` extends it to Zigcube's jobs (the checks J1 to J11 of
`docs/core.md`), from the job controller, the scheduler, retention and the
agent's job path at the same commit: see [Jobs](#jobs).

`Rollout.tla` is the rollout budget and state machine of C3, and `Mesh.tla`
the mesh address allocation of C4 slice 1, each from its own branch of
Zigcube and each a module of its own: see [Rollouts](#rollouts) and
[Mesh addresses](#mesh-addresses).

**What TLC found is in [FINDINGS.md](FINDINGS.md).** Read that first.

## How to run

```sh
./run.sh                  # every config but the slow ones; about 45 minutes on 4 cores (16 fencing, 13 jobs, 23 rollout, 12 mesh)
./run.sh --slow           # the slow ones too; about 25 minutes more
./run.sh base teeth-skew  # only these
```

Needs Java 11 or later and `curl`. `run.sh` downloads `tla2tools.jar` v1.7.4
into `.tools/` (not committed), checks its SHA-256, runs TLC on each config
(against `Fencing.tla`, or the module a `\* MODULE` line names) and compares
the result with the config's `\* EXPECT` line. It exits non-zero
when any config gives another result: a passing config that fails, or a
"teeth" config in which TLC no longer finds the violation. TLC's full output,
with the counterexample traces, is left in `out/`.

`.github/workflows/tlc.yml` runs `./run.sh` on pull requests and on `main`.

## What is modelled

One module, `Fencing.tla`.

| Part | In the model |
|---|---|
| Store | Linearizable: every transaction is one action. Leases with a ttl, attached keys deleted at expiry (`Expire`), compare-and-set on revisions. |
| Agent (one per node) | Registration (`lease_grant`, then the PUT of `/nodes/<node>`, which carries no compare, then `publish_store`'s write of the node's store summary, which compares the tenure the PUT returned), renewal by the rule of `fencing.renew_after_ms`, the fence timer at `s + ttl − fence_margin`, the fence itself (TERM, KILL at the nominal fence time plus `fence_stop_ms`, gone `fence_kill_latency_ms` later), fencing at once on `LeaseNotFound` and on a refused compared write, registering again when nothing runs, the pass (start what is assigned and report it under the tenure compare; TERM a stray container, KILL it `stop_grace_ms` later; delete the record of a replica that is gone, under the same compare). |
| Transport | One request per connection, no retries (`src/agent_http.zig`). A call ends at its deadline (`CallTimeout`): the fence time for an agent that holds a lease, `agent_io_timeout_ms` = the ttl otherwise. A registration PUT that timed out names a lease that has ended, so it cannot land (`TimedOutPutIsDead`). Only a broken connection or a restart of the agent process (`CallLost`, a fault) or a reboot leaves a PUT in flight behind its agent. |
| Server | Node controller (`mark_ready`, `mark_lost`), replica controller (`remove_lost` after `lost_grace_ms`, the admissibility check), one or two scheduler instances (plan, then a commit with the placement compare set). |
| Faults | Calls lost, delayed or answered late; a call whose connection broke, or whose agent restarted, applied later (`StalePut`, `StaleKa`); agent crash (a lost call; see below); machine reboot; wedged node; agent clock running slow; a store clock that steps forward, so that every lease has less time left (`Setback`). |
| Time | Discrete ticks. The store's clock is real time. An agent's clock may lose at most `SkewActual` ticks per lease period; the inequality is evaluated with `Skew`. |

The fencing inequality is a definition, `InequalityOK`, the same two tests as
`fencing.inequality_problem` (ZC-E0121): `Margin >= StopTime + Skew +
KillLatency` and `TTL >= Margin + WindowMin`. The module `ASSUME`s it unless a
config sets `RequireInequality = FALSE`, so constants that the agent would
refuse are refused by TLC before it starts.

The constants in the configs are Zigcube's divided down, with the same
structure: `TTL 6, Margin 3, StopTime 1, KillLatency 1, Skew 1, LostGrace 1,
StopGrace 3` against `10000, 3000, 2000, 900, 100, 1000, 5000` ms. As in
Zigcube, the margin equals what the inequality needs exactly: there is no
slack but the lost grace. And as in Zigcube, `stop_grace_ms` (the grace of an
ordinary stop, `src/constants.zig:161`) is longer than `fence_stop_ms` and
longer than the window I1b names (`LostGrace + KillLatency`, 2 ticks, 1.9 s):
a stray container takes up to `StopGrace + KillLatency` (4 ticks, 5.9 s) to
go.

### Revisions are bits

Every use of a revision in the protocol is an equality compare against the
current one. So each holder of a revision (the agent's tenure, a status
record, an observation, a scheduler's plan) keeps one bit, "what I read is
still current", and a write to the key clears the bits of all holders. This is
exact for compare-and-set, and it keeps the state space finite without a bound
on revisions, which is what lets TLC check the liveness properties.

### Urgency instead of real-time clocks

"The agent process is alive and scheduled" (authority.md section 3) is
modelled as: a tick cannot pass while an agent that is not wedged has a
deadline due (`Urgent`): the fence at its time, the KILL done, a renewal sent
once it is due, the pass run, a stray container gone `StopGrace +
KillLatency` after its TERM, a call given up at its deadline. `StepMax` lets a
step be that many ticks late. The fence's KILL is due at the nominal fence
time plus `fence_stop_ms` whenever the fence began (`begin_fence(ctx, at)`,
`src/agent.zig`), so a late step adds only what the step that sends the KILL
is late by. A wedged node is exempt from all of it, and nothing on it moves.

## What is abstracted away, and why

- **Agent crash and restart** is not a separate action. `lease.json` holds the
  phase, `s`, the lease, the tenure and the kill time; containers run on; and
  `restore` reads the file back. What a crash loses is the call in flight
  (`CallLost`, which may leave the request at the server) and time (which is
  the agent not acting, bounded by `Urgent`; an outage longer than a deadline
  is a wedge). A **reboot** is separate: the containers are gone and the kept
  lease is dropped.
- **The store summary is written once per lease**, in the step that adopts
  the lease. Two things the code also does are left out. `store_lease` is in
  memory, so a restarted agent that restores a held lease writes the summary
  again, and that write would catch a moved node key; the model's restart
  makes no write. And the summary is written again when its content changes
  (an image pulled); in the model the report of a started container stands
  for every compared write of that pass. Both make the model's agent learn of
  a superseded tenure later than the real one can, never earlier. Nodes are
  assumed to have an image store (`ctx.images`); without one `publish_store`
  writes nothing and the model's `Ack` is too strong.
- **A stray container may ignore TERM** for the whole of `stop_grace_ms`; one
  that exits on TERM is the same model with a shorter overlap.
- **`lease_grant` is immediate and never lost**; the PUT after it is the call
  that can be late or lost. A grant that is lost only leaves an unused lease.
- **A failed flush of the pass's reports** is not modelled: the report of a
  started container is made within the tick, and before the agent's next
  heartbeat (`reconcile` flushes in the step that ran the stages). A flush
  lost to the network would be retried after the next heartbeat.
- **Replica ids.** A slot is one unit of work that must run once. Replacing a
  replica marks the old container `old` (`oldrun` if its start is still to be
  reported) and frees the slot; the new replica id is not a value. The
  observed record is one per node and slot (`/observed/.../<node>/<replica>`
  in Zigcube), so two nodes can each hold a record of the same slot.
- **Postgres** is the linearizable store. An asynchronous standby is
  unsupported (`docs/operations.md`) and not modelled. What a failover or a
  clock step can do to leases is modelled as `Setback`.
- **Not modelled:** I4 (writer roles), I5 (`why` completeness), I6
  (allocations), jobs (section 6: claims, runs, deadlines), a server ttl
  different from the agent's (the runtime ZC-E0121 path), failures to persist
  `lease.json`, the OpenShell relay fence (decision 2026-11-12), scale-down
  and moves, more than one unit of work per slot.

### What was cut to make TLC finish

- **Faults touch one agent** (`Faulty = {a1}`) in every config but
  `both-faulty`; the other agents register, renew and run work with prompt
  replies. With both agents faulty the state space is about 40 million
  distinct states and takes 15 minutes (see the results table).
- **The node controller is prompt** (`NodeCtlPrompt`): it judges a node within
  the tick. Without that TLC finds finding 2; `slow-node-controller` and
  `finding-spent-grace` run with it off.
- Two or three agents, one slot (two in `two-slots`), one tick = 1/6 of the
  ttl. Leases the protocol can no longer observe are zeroed; counters are
  capped just above the bound they are checked against.
- Symmetry over slots and scheduler instances in the safety configs; none in
  the liveness configs.

## Properties

| Property in `Fencing.tla` | authority.md | Says |
|---|---|---|
| `I1a_OneAssignment` | I1a | A slot's replica has at most one assignment. |
| `I1a_OneAdmissibleTenure` | I1a, section 3 | Of the nodes' records of a slot, at most one is admissible, and it is the assigned node's, under its registered tenure. |
| `DeadBeforeExpiry` | section 3, the inequality | When an agent's lease ends at the store, its containers are gone (or go within the tick). |
| `I1b_NoOverlap` | I1b; section 3, "the agent has finished stopping before any replacement is placed" | A slot's work never runs on two nodes at once. |
| `I1b_Window` | I1b as section 4 words it | Not for longer than `lost_grace_ms` plus kill latency. |
| `I2_NoStaleCommit` | I2 | No observed write, store summary or placement commits on a superseded tenure or plan. |
| `I3_NoInadmissibleCause` | I3 | No decision cites an inadmissible record, whichever node wrote it. |
| `I7_PlacedOnReady` | I7 | No placement onto a node that is not ready at the commit. |
| `TenureEndFencesAtOnce` | decision 2026-11-08 | An agent told that its tenure ended has stopped everything within the fence's own time. |
| `FencingSettles` (liveness) | section 3; decision 2026-11-06 | Once faults stop, every agent holds a lease, a current tenure and a ready node, for good. |
| `WorkComesBack` (liveness) | `docs/core.md` | Once faults stop, every slot is assigned and running on its node, for good. |
| `TimedOutPutIsDead` | `src/agent_http.zig`, `agent_io_timeout_ms` = ttl | When a registration PUT reaches its timeout, the lease it names has ended at the store: a timed-out PUT cannot land. |
| `StrayOverlapShorterThanStopGrace` | | A probe, not a property: false in `finding-stale-put-stop-grace`, where it gives the trace of finding 1 at its full length. |
| `TypeOK`, `LeaseSlotsSuffice` | | Checks of the model itself. |

The liveness properties are checked under `Fairness`: weak fairness of time,
of each agent's steps, of delivery, and of each server action. No fairness is
assumed of faults.

`I1b_NoOverlap` counts an old instance that goes within the same tick as its
replacement starts as an overlap. The model's tick is the resolution: it
cannot tell "equal" from "one millisecond late".

## Results

TLC 2.19 (tla2tools v1.7.4), 4 workers, OpenJDK 21.

| config                       | expected                                   | result                                     |  generated |  distinct | depth |  time |  |
|------------------------------|--------------------------------------------|--------------------------------------------|------------|-----------|-------|-------|------|
| base                         | ok                                         | ok                                         |     919477 |    205460 |    48 |    5s | pass |
| both-faulty (`--slow`)       | ok                                         | ok                                         |  263672693 |  39528972 |    72 |  890s | pass |
| finding-spent-grace          | invariant I1b_NoOverlap                    | invariant I1b_NoOverlap                    |    1517764 |    317625 |    35 |    7s | pass |
| finding-stale-put            | invariant I1b_NoOverlap                    | invariant I1b_NoOverlap                    |   17813409 |   3602889 |    30 |   55s | pass |
| finding-stale-put-live       | temporal                                   | temporal                                   |    2376595 |    644760 |     - |   66s | pass |
| finding-stale-put-stop-grace | invariant StrayOverlapShorterThanStopGrace | invariant StrayOverlapShorterThanStopGrace |   37549972 |   7188046 |    43 |  114s | pass |
| finding-stale-put-window     | invariant I1b_Window                       | invariant I1b_Window                       |   32780313 |   6422954 |    40 |  100s | pass |
| finding-step-lag             | invariant I1b_NoOverlap                    | invariant I1b_NoOverlap                    |    1564499 |    402738 |    26 |    8s | pass |
| finding-store-setback        | invariant I1b_Window                       | invariant I1b_Window                       |    9478043 |   2037122 |    32 |   30s | pass |
| live                         | ok                                         | ok                                         |    1741678 |    410920 |    49 |   61s | pass |
| live-short-window            | ok                                         | ok                                         |    1597470 |    367228 |    49 |   52s | pass |
| setback-fences-at-once       | ok                                         | ok                                         |   21855739 |   4301414 |    71 |   75s | pass |
| slow-node-controller         | ok                                         | ok                                         |    2083138 |    411456 |    52 |    9s | pass |
| stale-keepalive              | ok                                         | ok                                         |   21490010 |   3736060 |    69 |   69s | pass |
| step-lag-within-grace        | ok                                         | ok                                         |   16606061 |   3421392 |    66 |   60s | pass |
| teeth-inadmissible           | invariant I3_NoInadmissibleCause           | invariant I3_NoInadmissibleCause           |       9901 |      3602 |    13 |    1s | pass |
| teeth-margin                 | invariant I1b_NoOverlap                    | invariant I1b_NoOverlap                    |     618390 |    140821 |    29 |    4s | pass |
| teeth-no-absent-compare      | invariant I1a_OneAssignment                | invariant I1a_OneAssignment                |       3845 |      1402 |    11 |    1s | pass |
| teeth-no-fence-on-conflict   | invariant TenureEndFencesAtOnce            | invariant TenureEndFencesAtOnce            |     778535 |    204791 |    20 |    5s | pass |
| teeth-no-fence-on-lease-gone | invariant TenureEndFencesAtOnce            | invariant TenureEndFencesAtOnce            |     663696 |    171910 |    20 |    4s | pass |
| teeth-no-lost-grace          | invariant I1b_NoOverlap                    | invariant I1b_NoOverlap                    |     484199 |    115772 |    28 |    4s | pass |
| teeth-no-ready-compare       | invariant I7_PlacedOnReady                 | invariant I7_PlacedOnReady                 |        852 |       388 |    10 |    1s | pass |
| teeth-no-tenure-compare      | invariant I2_NoStaleCommit                 | invariant I2_NoStaleCommit                 |       6330 |      2459 |    10 |    1s | pass |
| teeth-old-renew              | temporal                                   | temporal                                   |    2011738 |    555195 |     - |   65s | pass |
| teeth-skew                   | invariant I1b_NoOverlap                    | invariant I1b_NoOverlap                    |     722016 |    165661 |    29 |    4s | pass |
| teeth-skew-window            | invariant I1b_Window                       | invariant I1b_Window                       |    2044941 |    447186 |    36 |    9s | pass |
| teeth-wedge                  | invariant I1b_Window                       | invariant I1b_Window                       |    1432837 |    389624 |    33 |    7s | pass |
| three-agents                 | ok                                         | ok                                         |   14147571 |   2675000 |    54 |   55s | pass |
| two-schedulers               | ok                                         | ok                                         |    3912841 |    731390 |    63 |   17s | pass |
| two-slots                    | ok                                         | ok                                         |    6464011 |   1337502 |    64 |   29s | pass |

Generated and distinct states are TLC's counts when it stopped: at the end for a
passing config, at the violation for the others. `both-faulty` (faults on both
agents) is not run by default because it takes about 15 minutes on its own; it
ran to the end with nothing violated.

A config named `teeth-*` takes one safeguard away, or breaks one assumption
that authority.md states, and must fail: "a model that cannot fail proves
nothing". A config named `finding-*` runs the protocol as the code has it,
under a fault that authority.md does not exclude, and fails; each is a finding
in FINDINGS.md. `finding-stale-put-stop-grace` checks a probe and not a
property: its trace is finding 1 with the stray container there for the whole
of `stop_grace_ms` plus the kill latency.

| Teeth config | What is taken away | TLC reports |
|---|---|---|
| `teeth-skew` | the skew bound: the agent clock loses 2 ticks, the inequality allows 1 | `I1b_NoOverlap` violated |
| `teeth-skew-window` | the skew bound, by far (5 ticks) | `I1b_Window` violated |
| `teeth-wedge` | "the agent is alive and scheduled": a wedged node | `I1b_Window` violated |
| `teeth-margin` | ZC-E0121: `fence_margin` one tick under what the inequality needs | `I1b_NoOverlap` violated |
| `teeth-no-lost-grace` | `lost_grace_ms` | `I1b_NoOverlap` violated |
| `teeth-old-renew` | the 2026-11-06 renewal rule: back to `ttl / 3` with a fence window of `ttl / 3` | `FencingSettles` violated: the agent fences on every lease |
| `teeth-no-fence-on-conflict` | 2026-11-08: a refused compared write no longer fences at once | `TenureEndFencesAtOnce` violated |
| `teeth-no-fence-on-lease-gone` | `LeaseNotFound` on a keepalive no longer fences at once | `TenureEndFencesAtOnce` violated |
| `teeth-no-tenure-compare` | the tenure compare of the agent's writes | `I2_NoStaleCommit` violated |
| `teeth-no-ready-compare` | the node and status compares of a placement | `I7_PlacedOnReady` violated |
| `teeth-no-absent-compare` | the "assignment absent" compare, with two schedulers | `I1a_OneAssignment` violated |
| `teeth-inadmissible` | the admissibility check | `I3_NoInadmissibleCause` violated |

## Jobs

`Jobs.tla` extends `Fencing.tla` with Zigcube's jobs: the checks J1 to J11 of
`docs/core.md`, and section 7 of authority.md. It was written from
`src/job_controller.zig`, `src/scheduler.zig` (`place_run`, `release_run`),
`src/job_retention.zig` and `src/agent_jobs.zig` at Zigcube commit `f7736a7`,
and, like the rest, shares nothing with the simulator.

Every step of `Fencing.tla` is a step of `Jobs.tla`, with the job state
following it: a write of `/nodes/<node>` ends the tenure that observations
and the job's status were written under, a fence stops the job's container, a
reboot loses it. A job step of an agent is a step of its pass (`InPass`), its
claim and its reports are observed writes that compare the tenure, and a
refused one begins the fence.

### What is modelled

One job name, through `MaxInc` incarnations:

- **Server.** Submit (the API's create and the controller's create of the run
  and the status); cancel; placement as read then commit, the commit comparing
  the node, its status, the job's status, the run and the absence of an
  assignment; the controller's transactions (`mark_running` on an admissible
  claim, the ending on an admissible report, the fence report from the node
  the status names, the stop for cancel, for a run not claimed by `start_by`
  and for a lost node, the ending of a run whose claim's tenure has ended
  after the lost grace); `release_run`; retention's `drop_job`.
- **Agent.** The pass of `Work.one`: the `claiming` record, the claim, the
  `claimed` record and the start, as one pass or cut after the record or
  after the claim (a crash, a lost reply, an input that is not there yet);
  `claimed_unstarted` with its test that the claim is this tenure's and this
  epoch's; `not_started`, `gone`, `unknown`, `stopped`; the stop for the run's
  stop, the deadline (also with no server, from the start record) and a run
  that is no longer served; the report under the run's current assignment and
  the local ending of a run with none; leftovers of an earlier job of the
  name (`is_stale_epoch`, `stop_stale`).
- **Faults.** All of `Fencing.tla`'s (call loss, timeouts, late replies,
  expiry, reboot), a reboot that also loses the state directory
  (`AllowWipe`), and in one config the directory lost with the machine up
  (`AllowDirLoss`).

An assignment's epoch is the number of the incarnation it was written in.
The code compares epochs for equality and against the run's
`create_revision`; a node is assigned a run at most once per incarnation, so
both compares are exact in this encoding.

### What is abstracted away

- **One job.** Jobs do not interact except through the scheduler's capacity,
  which is one boolean here (`Placeable`).
- **No `placed` status and no `running` observation.** Neither decides
  anything in the controller.
- **Retention's hour.** `drop_job` runs an hour or more after the ending. No
  model of ticks spans that; here it may run once every call is answered or
  given up and every fence and stop is over (`Quiet`). Whether the scheduler
  has released the assignment by then is a switch (`ReleasePrompt`), because
  nothing in the code makes it so: finding 5.
- **Clock error.** Job configs run with `SkewActual = 0`. The base model
  lets the agent clock lose a tick per lease period, which is far coarser
  than a rate and swamps the job timers (two ticks of grace). The fencing
  configs cover skew for the fence itself.
- **The tenure-ended wait.** The controller waits `lost_grace_ms` after it
  sees that a claim's node key was written again; the model does not wait in
  that case (the old agent life has fenced or rebooted before the key can be
  written again). For an expired key it waits the lost grace.
- **Stops are immediate where the code uses no grace** (`stop_stale`).
- **The input fetch** is one switch (`FetchSlow`: the claim and the start may
  be passes apart); its failure kinds are not modelled.
- **J4** (a watch client sees every ending once) is about the watch stream,
  which the model does not have.
- **J7's "the run has no stop"** is judged as the code judges it, on the run
  as the pass read it. See FINDINGS.md, smaller differences.

### Properties

| Property in `Jobs.tla` | core.md | Says |
|---|---|---|
| `J1_NotAliveAfterEnding` | J1 | A job container is not alive after its job reached a terminal status. The simulator allows `overlap_ms_max`; with no clock error and no late step the model's bound is zero ticks, and it is held to that. |
| `J2_StartedOnce` | J2 | A run is started at most once in an incarnation, on any node and in any agent life. |
| `J3_EndingStands` | J3 | A terminal status never changes. (That the status goes only with its job is in `JTypeOK`.) |
| | J4 | Not expressible: no watch stream in the model. |
| `J5_AssignedOnce` | J5 | No placement commits after the run's stop, and a run has one assignment. |
| `J6_StopHonoured` | J6 | A container runs no longer than the stop bound after its run's stop committed: the grace and the kill latency, or the rest of the fence if the agent is in a call. |
| `J7_StartHasClaim` | J7 | Every start stands on a committed claim of this run under the assignment's epoch. |
| `J8_Deadline` | J8 | A container runs no longer than the deadline, the grace and the kill latency. |
| `J8_RunsEnd` (liveness) | J8, second clause | Once faults stop, no run stays open. |
| `J9_ReportUnderAssignment` | J9 | A report is stored only under the run's stored assignment. |
| `J10_NoRefusedLoop` | J10 | No report is made that the store must refuse for want of an assignment. Reads are atomic in the model, so the correct agent makes none; the simulator's form is a bound on the count. |
| `J11_ExitedWasStarted` | J11 | A status of `exited` is of a run started in its own incarnation. |
| `JTypeOK` | | The model itself; job, run and status exist together. |

`J8_RunsEnd` is checked under `JFairness`: weak fairness of time, of each
agent's steps (lease and job), of delivery, and of each controller and
scheduler action. None of faults, of cancel, of retention or of release.

The job configs also check `TypeOK`, `LeaseSlotsSuffice`,
`TimedOutPutIsDead`, `I2_NoStaleCommit` and `DeadBeforeExpiry` of the base
model.

### Results

| Config | Checks | Result | Generated | Distinct | Depth | Time (4 cores) |
|---|---|---|---|---|---|---|
| `jobs-base` | all invariants | pass | 12,436,137 | 2,534,830 | 54 | 75 s |
| `jobs-reuse` | all invariants, two incarnations | pass | 29,404,090 | 5,909,465 | 60 | 163 s |
| `jobs-live` | `J8_RunsEnd`; call loss, no reboot | pass | 1,333,275 | 412,372 | 54 | 64 s |
| `jobs-live-reboot` | `J8_RunsEnd`; reboot, no call loss | pass | 4,006,025 | 1,011,586 | 56 | 179 s |
| `jobs-live-unplaceable` | `J8_RunsEnd`; a run that fits nowhere | pass | 221,679 | 54,236 | 29 | 9 s |
| `jobs-two-nodes` | all invariants; two nodes, one faulty (call loss, expiry; no reboot, cancel or slow fetch) | pass | 12,797,065 | 3,585,118 | 59 | 129 s |

The teeth and finding configs each take between one second and one minute.

`jobs-base` is one node with every fault but a wedge; `jobs-two-nodes` has a second, correct node and
fewer faults on the first (two nodes with reboots and cancels do not fit a
CI run);
`jobs-reuse` follows the name through two incarnations; the `jobs-live*`
configs check `J8_RunsEnd`, each with part of the faults, because liveness
over the whole of `jobs-base` with a heal does not finish in half an hour.

| Teeth config | What is taken away (simulator tooth) | TLC reports |
|---|---|---|
| `teeth-job-claim` | the start waits for the committed claim (`job_claim`) | `J7_StartHasClaim` violated |
| `teeth-job-restart` | a container that ended is not started again (`job_restart`) | `J2_StartedOnce` violated |
| `teeth-job-wipe` | a claim with no start record is reported lost (`job_wipe`) | `J2_StartedOnce` violated |
| `teeth-job-double` | the run compare of a placement (`job_double`) | `J5_AssignedOnce` violated |
| `teeth-job-rewrite` | a late report is dropped (`job_rewrite`) | `J3_EndingStands` violated |
| `teeth-job-cancel` | the agent honours the run's stop (`job_cancel`) | `J6_StopHonoured` violated |
| `teeth-job-deadline` | the deadline (`job_deadline`) | `J8_Deadline` violated |
| `teeth-job-deadline-offline` | the deadline with no server (`deadline_offline`) | `J8_Deadline` violated |
| `teeth-job-unclaimed` | the stop of a run nobody claimed by `start_by` (`job_unclaimed`) | `J8_RunsEnd` violated |
| `teeth-job-stale` | the report names the current assignment (`job_stale`) | `J9_ReportUnderAssignment` violated |
| `teeth-job-refused-loop` | a run with no assignment ends locally (`job_refused_loop`) | `J10_NoRefusedLoop` violated |
| `teeth-job-reuse` | the stale-epoch test (`job_reuse`) | `J11_ExitedWasStarted` violated |
| `teeth-job-no-fence` | the fence stops job containers | `J1_NotAliveAfterEnding` violated |

The findings have a config each: `finding-job-reuse-assigned` (J2) and
`finding-job-reuse-report` (J11) for finding 5, `finding-job-dirloss` (J8)
for finding 6. Each is a spec with one switch off the code's actual
behaviour (`ReleasePrompt = FALSE`, `AllowDirLoss = TRUE`), not a removed
safeguard.

The simulator's teeth with no counterpart: `job_gap` (J4), `deadline_late`
(a deadline enforced some seconds late: the model's deadline is exact, and
`teeth-job-deadline` removes it), `job_evicted` (a controller sweep that
stops after 512 jobs: the model has one) and `job_ledger_small` (the
simulator's own ledger).

## Rollouts

`Rollout.tla` is Zigcube's rolling update (C3): the budget a rollout gives
the replica controller, and the rollout's phases. It was written from
`docs/briefs/c3.md` ("Controller design" and the checks R1, R2, R4, R7 and
R8), `src/rollout_plan.zig`, `docs/keys.md` (`/rollouts`) and the decision
`2026-11-13-c3-slice6-rollout-plan.md` at Zigcube commit `2954195` (branch
`claude/c3-slice6-rollout-plan`).

At that commit the pure plan (slice 6) and the keys (slice 5) exist; the two
controllers that use them (slice 7) do not. The module therefore models the
design the brief gives them, and is a check of that design ahead of the
code. It stands alone: it does not extend `Fencing.tla` (see "What is
abstracted away" below for where the two meet).

### What is modelled

| Part | In the model |
|---|---|
| The service | Its generation, its replica count, whether an apply or a rollback wrote it. A user applies a new generation (good, or bad: its replicas never turn ready), scales, pauses and resumes. A scale makes no generation. |
| Replicas | Counted by generation and state: starting, ready, unready for good, stopping (live until seen stopped). |
| `rollout_plan.budget` | `start`, `retire` and `retire_unready` exactly as the function computes them for a rolling policy, with `done`. |
| The rollout controller | One pass is one transaction: it begins a rollout when the service's generation is not the record's target (from any phase), completes it, applies a pause or resume, and writes the budget. Failure (ready timeout, a held replica, the progress deadline) fails it or pauses it, by `on_failure`. |
| The automatic rollback | The API's rollback handler: a new generation with the spec of the one before, compared on the service's revision. |
| The replica controller | Starts and retires within the budget (`Spend` says which budget: FINDINGS.md 7), only while the rollout runs and only for the record's target. Failure replacement never waits for the budget. Outside a rollout a scale down stops the extra replicas. |
| Faults | A replica is lost (its node was lost and it is marked so, or it crashed for good); a ready replica turns unready for good. |

### What is abstracted away

- **Time.** There is no clock. The progress deadline and the ready timeout
  are actions that may fire while the rollout is not done; in the liveness
  configs they do fire if it stays not done. `min_ready_ms`, the deadline
  arithmetic of a pause and the restart count are not modelled.
- **The lease and fencing model.** `Lose` is the step after
  `Fencing.tla`'s `MarkLost`: the replica is gone from the controller's
  count. Between a node's death and that mark, the records count a dead
  replica as ready. R1 is on the controller's view, as the brief words it,
  so that window (I1b's, seconds) is outside it: the real number of ready
  replicas can be lower than the view's by the replicas of nodes not yet
  declared lost. The modules are not composed.
- **One service, replicas as counts.** Which replica is retired among equals
  does not matter to the checks. Placement, and so "surge cannot be placed",
  is not modelled.
- **Recreate.** Only the rolling policy; the brief says R1 does not hold for
  recreate.
- **How a pause arrives.** `/rollouts` has one writer, so a pause is an
  intent the rollout controller applies on its next pass. The brief does not
  say where the intent is kept.
- **The rollout controller's pass is atomic.** That is the best it can be;
  finding 7 does not depend on a stale rollout controller.

### Properties

| Name | Brief | Statement |
|---|---|---|
| `R1_MinAvailable` | R1 | no retirement by a rollout leaves fewer ready replicas than `desired - max_unavailable`, on the replica controller's view when it acts |
| `R1_ReadyFloor` | R1 | with no fault and no scale, ready replicas are at least `desired - max_unavailable` in every state |
| `R2_SurgeBound` | R2 | no start (by the budget or as failure replacement) leaves more live replicas than `desired + max_surge` |
| `R2_LiveCeiling` | R2 | live replicas are at most `desired + max_surge` in every state (configs without a scale) |
| `R4_PauseHolds` | R4 | while the record is paused the rollout starts and retires nothing |
| `R4_NoBudgetAtRest` | R4 | a record that is paused, failed or complete carries no budget |
| `R8_UserWins` | R8 | an automatic rollback never replaces a newer apply |
| `R7_RolloutEnds` | R7 | a rollout always ends: complete, paused, or failed with its rollback made (liveness) |
| `R7_Completes` | R7 | with good releases, no pause and no deadline, the rollout completes (liveness) |

R3 (history), R5 and R6 of the brief are about records the model does not
have.

### Results

| Config | Checks | Result | Generated | Distinct | Depth | Time (4 cores) |
|---|---|---|---|---|---|---|
| `rollout-base` | all invariants; surge 1, unavailable 0; two applies (good or bad), two of pause, resume; two faults; a new rollout over one in flight | pass | 5,873,925 | 940,825 | 29 | 54 s |
| `rollout-unavailable` | the same with surge 0, unavailable 1 | pass | 1,831,912 | 314,096 | 26 | 18 s |
| `rollout-scale` | all but `R2_LiveCeiling`; the user also scales between 1 and 3; one fault | pass | 13,490,026 | 2,172,656 | 35 | 138 s |
| `rollout-floor` | all invariants and `R1_ReadyFloor`; no faults | pass | 243,246 | 57,220 | 27 | 5 s |
| `rollout-first` | all invariants; a new service, its first generation good or bad | pass | 21,179,704 | 2,953,820 | 28 | 186 s |
| `rollout-pause-policy` | all invariants; `on_failure pause` | pass | 648,118 | 105,662 | 22 | 9 s |
| `rollout-no-unready` | all invariants; no unready retirement rule | pass | 2,742,231 | 481,844 | 28 | 17 s |
| `rollout-once-quiet` | all invariants; `Spend = "once"`, no fault, no scale | pass | 133,421 | 32,479 | 30 | 2 s |
| `rollout-once-no-target-check` | the same, and a budget is spent whatever its target | pass | 135,629 | 32,843 | 29 | 3 s |
| `rollout-live` | `R7_RolloutEnds`; two applies, one fault | pass | 128,614 | 29,467 | 25 | 119 s |
| `rollout-live-user` | `R7_RolloutEnds`; one apply, one fault, two of pause, resume | pass | 67,650 | 12,981 | 23 | 13 s |
| `rollout-live-pause-policy` | `R7_RolloutEnds`; `on_failure pause` | pass | 13,874 | 3,335 | 19 | 15 s |
| `rollout-live-no-unready` | `R7_RolloutEnds`; no unready retirement rule | pass | 74,782 | 18,661 | 24 | 45 s |
| `rollout-completes` | `R7_Completes`; good releases, old replicas may go unready, no deadline | pass | 20,664 | 4,557 | 20 | 23 s |

`Spend = "recheck"` in every passing config but the two `rollout-once-*`
ones. The liveness configs are smaller than `rollout-base`, because TLC
checks liveness slowly: `rollout-live` has no pause or resume,
`rollout-live-user` one apply. `rollout-live-full` (two applies, one pause
or resume, one fault) is marked slow and runs with `./run.sh --slow`: it
passed, 671,841 generated, 128,896 distinct, depth 27, 508 s.

**With and without the unready retirement rule** (`retire_unready`, added in
slice 6): safety is the same without it (`rollout-no-unready`). Every
rollout still ends without it (`rollout-live-no-unready`), but only because
the deadline fails it: with the deadline taken away, a rollout whose old
generation has a replica that is running and unready never retires that
replica and never completes (`teeth-rollout-no-unready-stalls`), where with
the rule it does (`rollout-completes`).

| Teeth config | What is taken away | TLC reports |
|---|---|---|
| `teeth-rollout-no-phase-check` | the replica controller spends budget only while the rollout runs | `R4_PauseHolds` violated (781 states) |
| `teeth-rollout-no-cas` | the automatic rollback compares the service revision | `R8_UserWins` violated (904 states) |
| `teeth-rollout-replace-ignores-stopping` | failure replacement counts a stopping replica as live | `R2_SurgeBound` violated (16,857 states) |
| `teeth-rollout-no-unready-stalls` | the unready retirement rule, with no deadline | `R7_Completes` violated (1,216 states) |

The `finding-rollout-*` configs are FINDINGS.md 7 and 8.

## Mesh addresses

`Mesh.tla` is the allocation of mesh addresses (C4 slice 1): the address in
127.77.0.0/16 a service takes when it is first written, its release when the
service is deleted, the 24-hour quarantine, the 500 probes and ZC-E0207. It
was written from `src/mesh_address.zig`, `src/apply.zig` (`apply`,
`delete_service`), `src/api.zig` (`apply_attempts_max`) and the decision
`2026-11-13-mesh-address-allocation.md` at Zigcube commit `18e9838` (branch
`claude/c4-slice1`). It does not use `src/mesh_address_test.zig`.

### What is modelled

The store is linearizable: a read is one step, a transaction is one step and
commits only if every key it compares is at the revision that was read
(revision 0: the key must not exist). An API request is several reads and
one transaction, and any number of other requests may commit between its
steps. That is the race the slice's review found untested in the code: two
or more creates and deletes in flight, each having read the counter and the
holds at different moments.

| Part | In the model |
|---|---|
| A create | `CStart` reads the service (one that has an address keeps it); `CCounter` reads `/mesh-address-next`; `CProbe` reads one hold per step, up to `ProbesMax`; `CReplicas` looks for replicas of a released hold's service; `CCommit` is the transaction, comparing the service, the counter and the hold. A refused transaction is planned again from fresh reads, `AttemptsMax` times, then ZC-E0105. |
| A delete | `DStart` reads the service; `DHold` reads the hold of its address (a hold that names another service, or is released, is left alone); `DCommit` deletes the service and stamps the hold released, comparing both. |
| The block | `1..AddrMax` with the wrap, for 1..65,534. The counter is not advanced by a refusal. |
| The quarantine | `Quarantine` ticks, measured as the code does: the server's wall clock at the create against the stamp of the release. |
| Replicas | A live service gets replica records; they go at any time. A hold's service is looked up by name. |
| Faults | The server's wall clock steps forward (`ClockStep`, off in the passing configs). |

Not modelled: the store failing; `history.delete_all` before a delete (its
own transactions); the service record's other fields and updates of a
service that has an address (one read, no allocation); two API servers with
different clocks (a step of one clock gives the same traces).

Where the lease and fencing model matters: a replica "remains" while a
record of it does, which is what the code reads. That its container is gone
when its records are is I1b of `Fencing.tla`, seconds against a quarantine
of a day; the modules are not composed.

### Properties

| Name | Statement |
|---|---|
| `M1_Unique` | no two live services hold one address |
| `M2_HoldNamesHolder` | the hold of a live service's address names it and is not released |
| `M2b_NoLeak` | a hold that is not released is its live service's address |
| `M3_Quarantine` | an address is not taken within the quarantine of its release, in real time |
| `M4_NoOldReplica` | while a service holds an address, no replica record is left of another service that held it |
| `M5_HoldsStay` | a hold is never deleted |
| `M6_ExhaustedMeansFull` | no create is refused ZC-E0207 having passed over an address that was free but for a namesake's replicas (FINDINGS.md 9) |
| `M7_RequestsEnd` | allocation terminates: every request ends, created, kept, deleted, or refused with ZC-E0105 or ZC-E0207 (liveness) |

### Results

| Config | Checks | Result | Generated | Distinct | Depth | Time (4 cores) |
|---|---|---|---|---|---|---|
| `mesh-base` | M1 to M5; every interleaving of 6 creates and deletes, two in flight; the block wraps and addresses are reused | pass | 17,342,620 | 4,785,696 | 47 | 47 s |
| `mesh-counter-only` | the same without the hold compare | pass | 17,342,620 | 4,785,696 | 47 | 48 s |
| `mesh-hold-only` | the same without the counter compare | pass | 18,214,618 | 4,982,756 | 48 | 50 s |
| `mesh-by-incarnation` | M1 to M6 with the repair of finding 9 | pass | 16,856,516 | 4,599,204 | 46 | 43 s |
| `mesh-live` | `M7_RequestsEnd`; 5 requests | pass | 4,694,922 | 1,244,532 | 38 | 72 s |

Every config has two service names, two requests in flight, a block of 2
addresses, 2 probes, a quarantine of 2 ticks and 2 attempts
(`finding-mesh-clock-step`: 1 address).

The compare-and-set race: with both compares the model finds no
interleaving of creates and deletes that breaks M1 to M5. Either compare
alone is enough in the model (`mesh-counter-only`, `mesh-hold-only`): every
create writes the counter, so two creates that read the same counter cannot
both commit, and every create writes its hold, so two creates of one number
cannot both commit. With neither, two services take one address within 10 steps
(`teeth-mesh-no-compare`). The compare of the service key is what keeps two
creates of one name from each taking an address
(`teeth-mesh-no-service-compare`: the first address leaks).

| Teeth config | What is taken away | TLC reports |
|---|---|---|
| `teeth-mesh-no-compare` | both the counter compare and the hold compare | `M1_Unique` violated (856 states) |
| `teeth-mesh-no-service-compare` | the compare of `/services/<name>` | `M2b_NoLeak` violated (810 states) |
| `teeth-mesh-no-quarantine` | the quarantine | `M3_Quarantine` violated (75,551 states) |
| `teeth-mesh-no-replica-check` | the wait for the old service's replicas | `M4_NoOldReplica` violated (306,813 states) |
| `teeth-mesh-forget-hold` | the released hold: the delete deletes it | `M5_HoldsStay` violated (327 states) |

The `finding-mesh-*` configs are FINDINGS.md 9 and 10; `mesh-by-incarnation`
is the repair of 9.

## Files

- `Fencing.tla`: the lease, fencing and authority model.
- `Jobs.tla`: jobs, on top of it.
- `Rollout.tla`: the rollout budget and phases (C3).
- `Mesh.tla`: mesh address allocation and release (C4 slice 1).
- `configs/*.cfg`: one TLC config each; line 1 says what it is, line 2 what
  TLC must report, `\* SLOW` on line 3 keeps it out of the default run,
  `\* MODULE <name>` on line 3 marks a config of another module than
  `Fencing.tla`.
- `run.sh`: the runner. `.github/workflows/tlc.yml`: CI.
- `FINDINGS.md`: what TLC found, with traces and the places in Zigcube.
