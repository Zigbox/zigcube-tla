# Findings

What TLC found when the model follows the Zig code and `docs/authority.md`
where they differ. File and line numbers are in Zigbox/zigcube at commit
`f7736a7` for findings 1 to 6, at `2954195` (branch
`claude/c3-slice6-rollout-plan`) for 7, 8 and 11, and at `18e9838` (branch
`claude/c4-slice1`) for 9 and 10 (9 also notes the branch's later head `b9ae3bd`). Nothing in Zigcube was changed.

Each finding names the config that reproduces it; `./run.sh <config>` leaves
the full trace in `out/<config>.out`. The traces below are those traces, one
line per step, with the variables that matter. Times are in ticks; in every
config `TTL = 6`, the fence is at agent time 3 (`FenceAt = TTL − Margin`), and
`LostGrace = 1` unless said.

| # | What | Kind | Config | TLC reports |
|---|---|---|---|---|
| 1 | A registration PUT whose agent restarted, or whose connection broke, lands after the next registration and moves the node key onto an orphan lease | **protocol bug** (I1b; and a node that stays lost) | `finding-stale-put`, `finding-stale-put-window`, `finding-stale-put-stop-grace`, `finding-stale-put-live` | `I1b_NoOverlap`, `I1b_Window`, the stop-grace probe, `FencingSettles` violated |
| 2 | The lost grace is counted from the first `mark_lost`, so a second expiry can have none | code differs from authority.md | `finding-spent-grace` | `I1b_NoOverlap` violated (same tick); `I1b_Window` holds |
| 3 | Lease deadlines are absolute store-clock values | code differs from authority.md | `finding-store-setback` | `I1b_Window` violated |
| 4 | The inequality has no term for a late agent step | gap in authority.md, zero slack in the constants | `finding-step-lag` | `I1b_NoOverlap` violated; holds when the lag is under `lost_grace` |
| 5 | Retention deletes a job without looking at its run's assignment; if the scheduler has not released it and the name is used again, the agent claims under the old assignment and starts the run on every pass, or the old run's ending is reported again and ends the new job | **protocol bug** (J2: a run that never ends; J11: a job ended by another job's report), needs an assignment that outlives its job by an hour | `finding-job-reuse-assigned`, `finding-job-reuse-report` | `J2_StartedOnce` violated; `J11_ExitedWasStarted` violated |
| 6 | A state directory lost under a running agent: no fence, no start records, the job containers run on | gap the simulator names and does not cover | `finding-job-dirloss` | `J8_Deadline` violated |
| 7 | The budget in `/rollouts` is a count with no view attached; the replica controller spends it after a node is lost, after a scale, or twice | gap in the C3 brief (slice 7 is not built): R1 and R2 fail | `finding-rollout-once-fault`, `finding-rollout-once-scale`, `finding-rollout-once-surge`, `finding-rollout-stored-r1`, `finding-rollout-stored-r2` | `R1_MinAvailable`, `R2_SurgeBound` violated; hold when the replica controller evaluates the budget on its own read |
| 8 | A first generation that fails has nothing to roll back to and stays `failed` with the rollback owed | R7 does not hold as worded (the slice-6 decision names the case) | `finding-rollout-first-generation` | `R7_RolloutEnds` violated |
| 9 | A mesh address released by a service whose name is in use again is never reusable; ZC-E0207 with free addresses, and then for every create | **protocol bug** (availability, after the counter wraps) | `finding-mesh-namesake` | `M6_ExhaustedMeansFull` violated; holds with the hold named by incarnation |
| 10 | The quarantine is a difference of API-server wall-clock readings | same kind as 3, with a day of room | `finding-mesh-clock-step` | `M3_Quarantine` violated |

With those faults excluded (for 7: with the replica controller evaluating
the budget itself), every invariant holds in every passing config, and TLC caught every safeguard that was taken away (README, teeth
table).

## 1. A late registration PUT re-attaches the node key to an orphan lease

**This is a real protocol bug, in the code and in authority.md alike. Its
trigger is narrower than the first version of this file said, and the trace is
a different one.**

The agent registers with `lease_grant` and then a PUT of `/nodes/<node>`
attached to the new lease (`src/agent.zig:745-757`). The server applies that
PUT with no compare (`src/agent_api.zig:284-314`). The agent adopts the lease
and the tenure only when the PUT's reply arrives (`src/agent.zig:759-761`); if
the call fails, the next heartbeat grants another lease and PUTs again.

### What it takes

A registration PUT has to be applied after the PUT of the agent's next
registration. Over Zigcube's transport that is not a timeout:

- The agent's client makes one request per connection and never retries
  (`src/agent_http.zig:1-9`), and nothing in Zigcube's own path does.
- A registration PUT runs `agent_io_timeout_ms` = 10 s
  (`src/constants.zig:285`), which is the ttl. The lease was granted before
  the PUT was sent, so when the PUT times out its lease has ended and the
  store refuses the write (`store_postgres.zig`, `check_leases`). The model
  checks this as `TimedOutPutIsDead` in every config. (The model's agent clock
  only runs slow. An agent clock that runs fast gives the call up early by the
  same fraction; that edge is not modelled.)

What is left: the agent stops waiting before the timeout while the server
still holds the request. That is a **restart of the agent process** with the
PUT in flight (the agent was idle, so `lease.json` is absent and it registers
again at once), a **connection that broke** after the request was read, or a
reboot. The server runs each connection on a thread of its own
(`src/server_http.zig`), and the store call of that thread can wait for a
pool connection and for the revision lock, 5 s each
(`src/store_postgres.zig:364-366`, `src/constants.zig:80`), while the PUT of
the new registration gets through first. In the model this is the fault
`CallLost`; `CallTimeout` leaves no PUT behind.

So the request must be held at the server for longer than the agent takes to
come back and register again, and for less than what is left of the first
lease (under 10 s). **This is read from the code; I have not reproduced it
against a running Zigcube.**

### What happens then

1. `/nodes/<node>` is attached to the abandoned lease L1, which nobody
   renews. Its revision changed, so the agent's tenure is superseded.
2. The agent holds L2 and renews it. A keepalive looks only at the lease
   (`src/agent_api.zig:316-331`), so it succeeds: the agent's fence timer is
   pushed back on every renewal, for a lease that no longer protects anything.
3. L1 expires. The node key goes, `mark_lost` runs
   (`src/node_controller.zig:218-241`), and after `lost_grace_ms` the replica
   controller replaces the node's replicas
   (`src/replica_controller.zig:292-304`, `541-565`) while the agent is in
   `held`, before its fence time, with the containers running.

The fencing inequality does not help: it relates the agent's fence to the
lease the agent renews, and the store expired another one.

### What the agent's compared writes catch

Every write the agent makes after the PUT compares `/nodes/<node>` at its
tenure, and a refusal fences at once (decision 2026-11-08):

- `publish_store` writes the node's store summary in the step that adopts the
  lease (`src/agent.zig:562-600`; `store_lease != lease`). A stale PUT that
  landed **between the new PUT and this write** is caught here: the agent
  fences with nothing running and registers again. The model does this write
  in `Ack`. The first version of the model did not, and its trace, in which
  the stale PUT landed before the reply to the new one, is not possible.
- The pass reports a started container, and deletes the record of a replica
  that is gone, under the same compare (`src/agent.zig:1392-1398`).

So the stale PUT does damage only if it lands **after the agent's last
compared write**. Two cases, both found by TLC:

**(a) After the report of a running container** (`finding-stale-put-stop-grace`).
The agent has nothing more to write. L1 expires, the replica is replaced, and
the agent learns it from the watch: its container is now a stray. It stops the
stray as an ordinary stop (`orphan_containers`, `stop_listing`,
`src/agent.zig:1339-1346`, `940`): TERM, then KILL `stop_grace_ms` = 5000 ms
later (`src/constants.zig:161`), not the fence's 2000 ms. A container that
ignores TERM is there for `stop_grace_ms` + kill latency = **5.9 s** next to
its replacement. The window I1b names is `lost_grace_ms` + kill latency =
**1.9 s**. Only when the container is gone does the agent delete its record,
get refused, fence and register again.

**(b) After the summary write, on a node with no work yet**
(`finding-stale-put`, `finding-stale-put-window`). This needs the request held
only for the restart and one registration. Work that is placed on the node
shortly before L1 expires is started; the report is refused and the agent
fences at once; but the replacement was due `lost_grace_ms` after L1's expiry
and does not wait for that fence. The fence at once takes `fence_stop_ms` +
kill latency = 2.9 s, against the window of 1.9 s.

An agent that is cut off from the watch but not from keepalives would run on
past these bounds; the model's agent always runs its pass on time, so TLC's
traces show the bounded forms.

The same fault also breaks liveness without any overlap
(`finding-stale-put-live`): with nothing running, the agent renews its lease
for ever, never writes, never learns; the node stays lost and gets no work.

### Traces

**Case (a)** (`finding-stale-put-stop-grace`, 43 states). The config checks
`StrayOverlapShorterThanStopGrace`, which is a probe and not a property of
the protocol: it is false exactly when a held agent's stray is still there
`StopGrace + KillLatency` ticks after its TERM, next to the replacement.

```
 2 Register a1     lease L1 granted (ttl 6); PUT /nodes/a1 on L1 sent
 3-4 Tick x2
 5 CallLost a1     the agent process restarts (or the connection breaks);
                   the PUT is still at the server
 6-8 Tick x3       L1 has 1 left
 9 Register a1     lease L2 granted; PUT /nodes/a1 on L2 sent
10 Serve           PUT(L2) applied: /nodes/a1 -> L2
11 Ack a1          a1 is `held` on L2; the summary write compares the tenure: ok
12 MarkReady a1
13-14 Plan, Commit s1 assigned to a1
15 Start a1        a1 starts s1
16 Report a1       compared write, ok.  a1's last compared write.
17 ServeStale      PUT(L1) applied: /nodes/a1 -> L1          <-- the bug
                   a1's tenure is superseded; a1 is not told
18 MarkReady a1    (the node's new revision)
19 Tick            L1 has 0 left, L2 has 5
20 Expire a1       /nodes/a1 deleted (it was on L1); L2 lives on
21 MarkLost a1
22 Tick            lost for 1 = LostGrace
23-26              a2 registers, is acknowledged and marked ready
27 Replace         replica controller: a1 is lost, grace over; s1 freed.
                   a1's container is now a stray
28 StopTerm a1     a1's pass sees it: TERM (stop grace 3 ticks)
29-30 Plan, Commit s1 assigned to a2
31-32 Start, Report a2 starts s1.  s1 runs on a1 and on a2
33-43              4 ticks pass.  a1 renews L2 (34-37) and is `held` throughout,
                   tenure superseded, with no compared write to make.
43                 a1's container is still there 4 ticks after its TERM
                   (StopGrace 3 + KillLatency 1: 5.9 s), next to a2's for 4
                   ticks.  The window is LostGrace + KillLatency = 2 (1.9 s).
```

`I1b_NoOverlap` is violated at state 31 of this trace and `I1b_Window` at
state 41, when the third tick of overlap passes; the configs that check those
stop at shorter traces, of case (b).

**Case (b)** (`finding-stale-put`, 29 states, `I1b_NoOverlap`):

```
 2 Register a1     L1 granted; PUT on L1 sent
 3 CallLost a1     restart or broken connection; the PUT is still at the server
 4-5 Tick x2       L1 has 4 left
 6 Register a1     L2 granted; PUT on L2 sent
 7 Serve           /nodes/a1 -> L2
 8 Ack a1          `held` on L2; summary write ok.  a1's last compared write.
 9 ServeStale      PUT(L1) applied: /nodes/a1 -> L1          <-- the bug
10-11 MarkReady a1, Plan
12-14 Tick x3      L1 has 1 left, L2 has 3
15-17              a2 registers
18 Commit          s1 assigned to a1
19 Start a1        a1 starts s1
20 Report a1       refused: a1 fences at once.  KILL due in 1, gone in 2
22 Tick            L1 has 0 left
23 Expire a1       /nodes/a1 deleted
24 MarkLost a1
25 Tick            lost for 1 = LostGrace; a1's container goes in this tick
26 Replace         s1 freed
27-28 Plan, Commit s1 assigned to a2
29 Start a2        a1's container is still there.  I1b_NoOverlap violated.
```

`finding-stale-put-window` (39 states, `I1b_Window`) is the same case with the
work placed one tick later: the assignment commits just before L1 expires
(state 18), a1 starts s1 after the node was marked lost and the grace had run
(23), its report is refused and it fences at once (24), and the replica is
replaced in the same tick (29). a1's container is there for 3 ticks next to
a2's (the fence's 2, and one tick its clock may lose); the window is 2.

`finding-stale-put-live` (one agent, nothing to run):

```
 2 Register a1     L1; PUT sent       3 CallLost (PUT(L1) still at the server)
 4 Register a1     L2; PUT sent       9 PUT(L1) is dropped
10 CallLost a1     PUT(L2) still at the server
11 Register a1     L3; PUT sent      13 Serve: /nodes/a1 -> L3
14 Heal            no fault from here on
15 Ack a1          `held` on L3; summary write ok
16 ServeStale      PUT(L2) applied: /nodes/a1 -> L2, which has 1 left
20 Expire          /nodes/a1 deleted with L2
21 MarkLost a1
19-23              a1 renews L3: served, acknowledged
24-28              Tick, Tick, Renew(L3), Serve ok, Ack; back to 24, for ever
```

The node is lost, its agent is `held` and renewing, and nothing in the
protocol tells it.

**Suggested repair** (not applied, not modelled as a fix beyond the first):

- Make the registration a transaction that compares on the lease it replaces
  ("`/nodes/<node>` absent, or attached to the lease I last held"), or carry a
  per-agent registration counter in the value and refuse a lower one. Then a
  late PUT fails.
- And have the keepalive reply (or the agent's renewal) check that
  `/nodes/<node>` is still attached to the lease being renewed, so that an
  agent whose key moved fences as for `LeaseNotFound`.
- Separately from the bug: a stray container is stopped with `stop_grace_ms`,
  which is longer than the I1b window. Whatever else makes a stray next to a
  live replacement gets the same 5.9 s.

In the model, `StalePut = FALSE` is the first repair: all invariants hold
(`base` and the others).

## 2. The lost grace can already be spent

authority.md section 3 (lines 247-256): the server "declares the node lost at
expiry, then waits `lost_grace_ms` before anything is placed elsewhere".

The code computes the wait from the `at_ms` of the `lost` status record
(`src/replica_controller.zig:300`, `due = status.rec.at_ms +| lost_grace_ms`),
and that record is written by the node controller when it judges the node
(`src/node_controller.zig:218-241`). `lost_placement` returns null only when
the node entry exists with a newer revision than the status
(`src/replica_controller.zig:292-304`).

So: a node is lost (status `lost`, `at_ms = t0`), registers again, and its new
lease expires before the node controller has judged the new tenure (it never
wrote `ready`). The node entry is absent again, the status is still `lost`
with the old `t0`, and `t0 + lost_grace_ms` is long past. The replica
controller replaces at the instant of expiry, with no grace.

The agent's own fence still ran on time, so by the inequality its containers
are gone at expiry. The overlap TLC reports is of zero length: the kill
completes and the replacement starts in the same tick. In Zigcube's constants
that is the case where `fence_margin` has exactly what the inequality needs
(3000 = 2000 + 100 + 900) and the lost grace was the only slack. `I1b_Window`
holds (`slow-node-controller`).

It needs a node controller that is behind by a whole lease period, and work
assigned to a node that was never marked ready again; I7 forbids the second
for new placements, so the work must have been placed before the first loss
and not yet removed. Small, but it is a place where the code is weaker than
the sentence in authority.md.

**Trace** (`finding-spent-grace`, 35 states, `I1b_NoOverlap`):

```
 2-6               a1 registers on L1 (reply not yet back), marked ready; s1 assigned to a1
 7 CallLost a1     the reply to the PUT is lost; a1 is idle
 8-10 Tick x3
11 Register a1     L2 granted; PUT sent, delayed
12-14 Tick x3      L1 has 0 left
15 Expire a1       /nodes/a1 deleted
16 MarkLost a1     status lost, at_ms = now (t0)
17 Serve           PUT(L2) applied: /nodes/a1 -> L2.  The node controller does not
                   get to it: status stays `lost` with at_ms = t0
18 Ack a1          a1 held on L2, age 2; summary write ok
19-20 Start, Report a1 starts s1 (its assignment was never removed) and reports it
21 Renew a1        keepalive sent; it hangs and is given up at the fence time (23)
22 Tick            t0 + LostGrace has passed
24 TimerFence a1   age 3 = fence time: TERM; KILL due at 4, gone by 5
25-27              a2 registers
28-29 Tick x2      L2 has 0 left; a1 age 5: the container goes in this tick
30 Expire a1       /nodes/a1 deleted
32 Replace         status is `lost` since t0, grace long over: s1 freed at once
33-34 Plan, Commit s1 assigned to a2
35 Start a2        same tick as a1's kill completes.  I1b_NoOverlap violated.
```

**Suggested repair:** count the grace from the expiry that the replica
controller sees (a `lost` record written at each expiry, or `remove_lost`
refusing a status older than the node's last tenure), or give `fence_margin`
real slack.

## 3. Lease deadlines are absolute store-clock values

authority.md line 261: "Absolute clock values do not matter"; the argument of
section 3 uses only durations on each side.

That is true of the agent (monotonic clock, `s` taken before the request). It
is not true of the store: Postgres leases expire by `clock_timestamp()`
(`src/store_postgres.zig:163`, and 23-27, 311-314, 327), the SQLite store by
wall time (`docs/store-design.md:127-128`, `295-296`). If the database clock
steps forward (NTP step, VM resume, or a failover to a synchronous standby
whose clock is ahead), every lease loses that much time at once and can expire
before its agent's fence.

The model's `StoreSetback` does the same: one step takes `Setback` ticks from
every lease of every node at once, so several nodes can expire in the same
tick. With a setback larger than the margin, TLC finds the overlap past the
window. (In the trace below only a1 holds a lease when the clock steps; a2
registers after it.)

What the code does have: after such an expiry the agent's next keepalive gets
`LeaseNotFound` and it fences at once (`src/agent.zig:738-742`); the
`setback-fences-at-once` config checks that this holds
(`TenureEndFencesAtOnce`). That bounds the overlap by the renewal interval
plus the fence time, not by the window I1b names.

An asynchronous standby is a different matter: `docs/operations.md:20-29`
says it is unsupported (ZC-E0215), so it is not a finding.

**Trace** (`finding-store-setback`, 32 states, `I1b_Window`):

```
 2-9               a1 registers on L1, is marked ready, is assigned s1, starts it
                   and reports it
10 StoreSetback    the store's clock steps forward: every lease loses 5 ticks.
                   L1 has 1 left, not 6
11 Tick            L1 has 0 left; a1 age 1
12-14              a2 registers (after the step)
15 Expire a1       /nodes/a1 deleted
16 MarkLost a1
18 Tick            lost for 1 = LostGrace; a1 age 2
19-21 Renew a1     keepalive: LeaseNotFound.  a1 fences at once: KILL due at 3,
                   gone by 4
22 Replace         s1 freed
23-26              s1 assigned to a2, started, reported
27-32 Tick x3      a1's container is there for 3 ticks next to a2's (the fence's
                   2, and one tick a1's clock may lose).
                   Window is LostGrace + KillLatency = 2.  I1b_Window violated.
```

**Suggested repair:** say in authority.md that the store's clock must not step
forward by more than a stated bound (and add that bound to the inequality), or
keep lease deadlines on a clock that failover carries over (a store-side
monotonic counter). At least, record it as an assumption next to the skew
bound.

## 4. No term for a late agent step

The agent checks its fence time at the start of a reconcile step
(`src/agent.zig:472-483`, the check is at 479-482). A step that starts late by
`d` sends TERM late by `d`, but not KILL: `begin_fence(ctx, at)` is given the
nominal fence time, and the KILL is due at `at + fence_stop_ms` whenever the
fence began (`src/agent.zig:848`). A late start of the fence only shortens the
container's time to stop cleanly. What adds zombie time is lag on the step
that sends the KILL (`fence_step`, `src/agent.zig:867`): a step that should
run at `at + fence_stop_ms` and runs `d` later kills `d` later.

The inequality in `src/fencing.zig:23` and `36-40` is `margin >= stop + skew +
kill_latency`, with no term for that lag, and Zigcube's constants meet it with
equality (`src/constants.zig:132-157`). So any lag on the KILL step eats into
`lost_grace_ms` (1000 ms), and a lag above it is an overlap.

The model has it this way: `TimerFence` sets the KILL time from `FenceAt`, not
from the agent's age, and `StepMax` is how late the step that completes the
kill may be.

authority.md section 3 assumes the agent "alive and scheduled"; it gives no
number. `fence_poll_ms` is 100, so a healthy agent is within 100 ms; a step
that blocks (a slow runtime call inside a pass, a long GC-less pause under
memory pressure) is not bounded by anything the agent checks.

TLC: with a KILL step one tick late and a lost grace of one tick the two meet
(`finding-step-lag`, `I1b_NoOverlap`, zero-length overlap); with a lost grace
of two ticks everything holds (`step-lag-within-grace`).

**Trace** (`finding-step-lag`, 26 states, `I1b_NoOverlap`):

```
 2-6               a1 registers on L1, held, marked ready; s1 planned on a1
 7-10 Tick x4      a1's clock lost one tick (the skew bound): age 3, L1 has 2 left
11-12              s1 assigned to a1; a1 starts s1
13 TimerFence a1   age 3 = fence time: TERM.  KILL due at 4 (nominal), gone by 5;
                   with the KILL step one tick late, by 6
14-15 Tick x2      L1 has 0 left; a1 age 5
16-18              a2 registers
19 Expire a1
20 MarkLost a1
22 Tick            lost for 1 = LostGrace; a1 age 6: the container goes in this tick
23 Replace         s1 freed
24-25 Plan, Commit s1 assigned to a2
26 Start a2        a1's container is still there.  I1b_NoOverlap violated.
```

**Suggested repair:** add a bound on the lag of the KILL step to
`margin_needed_ms` (and to ZC-E0121), and have the KILL fire from a timer that
does not wait for a reconcile step.

## 5. Retention deletes a job whose run is still assigned

Findings 5 and 6 are from the jobs model (`Jobs.tla`), written from zigcube
`f7736a7`.

`drop_job` (`src/job_retention.zig:308-321`) deletes `/jobs/<name>`, the
input, `/job-runs/<name>-job`, `/job-status/<name>` and the node's
observation in one transaction that compares the status's revision and
nothing else. `/assigned/<node>/<name>-job` is neither read nor deleted. The
scheduler is expected to have released it by then: `release_run`
(`src/scheduler.zig:773`) releases the assignment of a run whose status is
terminal, and retention waits at least an hour (`job_finished_age_ms_min`,
`src/constants.zig:995`).

Nothing makes that so. `release_run` returns without releasing when the
node's allocation is unaccounted (`view.alloc_revision == 0`, line 793), when
the subtraction fails (794), when the pass has no budget left (796), and of
course when no scheduler runs. The first two are standing conditions, not
delays. If the assignment is still there when retention deletes the job, and
the name is then submitted again before a scheduler pass releases it ("its
job is gone"), the run id `<name>-job` is the same and:

- the scheduler does not place the new run (the id is assigned) and does not
  release the old assignment any more (the status is `pending`, line 784);
- the agent on that node sees a served run and an assignment and claims it
  (`claim`, `src/agent_jobs.zig:724`) under the old assignment's epoch. Every
  compare of the claim passes: the tenure, the run, the assignment at that
  epoch. It starts the container;
- the job controller finds the claim admissible and marks the job running;
- on the agent's next pass its own start record, its own observation and its
  own container carry an epoch older than the run's `create_revision`, which
  is what `is_stale_epoch` (`src/agent_jobs.zig:348`) takes for leftovers of
  an earlier job of the name. `stop_stale` (372) kills the container with no
  grace, the record counts as absent, the observation as not seen, and the
  agent claims and starts again. And again on every pass.

One run id is started over and over within one incarnation (J2), each
container killed after one pass, with a status of `running` throughout.
The run's deadline never fires (each container is new) and nothing in the
store changes, so no controller ends it: it lasts until someone deletes the
assignment or cancels the job. The stale-epoch test is right for what it was
written for; it assumes that an assignment older than its run cannot exist.

The simulator does not reach this: its scheduler always releases an ended
run long before the simulated hour, so J2 never sees a reused name with an
old assignment.

**How likely.** It needs an assignment that outlives its job by an hour: a
scheduler that is down or without a leader for that long while retention
runs, or a node whose allocation is unaccounted or contradictory for that
long (both are reported by the auditor, neither stops retention), and then
a second job of the same name. Rare; when it happens it does not heal.

TLC: `finding-job-reuse-assigned` (`ReleasePrompt = FALSE`: retention may
run while the run is assigned), `J2_StartedOnce`, 16 states. With
`ReleasePrompt = TRUE` two incarnations hold every property (`jobs-reuse`).

**Trace** (`finding-job-reuse-assigned`):

```
 2 Submit           incarnation 1: job, run, status pending
 3-6                a1 registers on L1, held, marked ready
 7 SPlan a1         the scheduler reads: pending, no stop, a1 ready
 8 Cancel           a client cancels the job
 9 SCommit          /assigned/a1/<id> written, epoch 1 (the run has no stop yet)
10 CStopCancel      the controller writes the run's stop
11 CEndUnstarted    no claim: status cancelled
12 Retention        job, run, status deleted.  The assignment stays.
13 Submit           incarnation 2: the same run id, a new create_revision
14 JClaim a1        a1: served run, assignment (epoch 1), no record: claims
                    under epoch 1 and starts.  starts = 1
15 JDropStale a1    next pass: record and container are "older than the run":
                    container killed, record dropped, observation not seen
16 JClaim a1        claims and starts again.  starts = 2: J2_StartedOnce
```

(The cancel is only TLC's shortest way to an ended job with an assignment;
any ending does.)

**Second form: the old run's ending ends the new job.** If the old run was
started and ended on the node, the agent still has its record and its ended
container when retention deletes the job together with the node's
observation. On its next pass the agent finds no observation of the ending
(`seen_of`, `src/agent_jobs.zig:329`) and reports it again (`stopped`, 664;
`report`, 1083). The report compares the tenure and the assignment at its
epoch, both unchanged, and not the run, so the store accepts it whether or
not a run of that id exists. Once the name is submitted again, the job
controller reads a stopped observation from the node's current tenure under
the epoch the run id is assigned at: `admissible`
(`src/job_controller.zig:776`) compares the node key's revision, the
assignment's revision and the node's readiness, and nothing of the run. The
new job goes from `pending` to `exited` (or `failed`) with the old run's
exit code and was never started (J11). If the agent's pass comes after the
submit instead, it is the first form.

TLC: `finding-job-reuse-report`, `J11_ExitedWasStarted`, 16 states. The two
configs differ only in which of the two invariants they check, so that each
reports one result at the same depth.

**Trace** (`finding-job-reuse-report`):

```
 2-5              a1 registers on L1, held, marked ready
 6 Submit           incarnation 1: job, run, status pending
 7-8 SPlan, SCommit /assigned/a1/<id> written, epoch 1
 9 JClaim a1        claims and starts
10 JExit a1         the container exits
11 JReport a1       observation: stopped, exit, tenure of a1, epoch 1
12 CEndReport       status exited
13 Retention        job, run, status and the observation deleted.
                    The assignment stays.
14 JReport a1       record and ended container are there, the observation
                    is not: reports stopped again under epoch 1.  Accepted.
15 Submit           incarnation 2: the same run id, status pending
16 CEndReport       the observation is admissible: status exited.
                    No start in incarnation 2: J11_ExitedWasStarted
```

**Suggested repair:** make the deletion and the assignment exclusive.
Either `drop_job` reads the run's assignment and leaves the job for a later
pass while one exists (compare its absence in the transaction), or the job
controller's create refuses or waits while `/assigned/*/<name>-job` exists.
On the agent, a claim whose subject epoch is older than the run's
`create_revision` can be refused locally: that assignment is not of this
run. For the second form, `admissible` can refuse an observation whose
assignment epoch is older than the run's `create_revision`, which is the
agent's own `is_stale_epoch` test on the controller's side.

## 6. A lost state directory leaves job containers that nothing stops

docs/core.md says what the simulator's disk loss does not cover: "a state
directory removed by hand while the host and its containers stay up", and
that J1, J8 and I1b fail on it in the simulator because the simulated
runtime keeps its container records in that directory. The model has no such
artefact (the runtime lists its containers whatever happens to the agent's
directory) and shows what is left of the problem in the real design.

An agent that starts and finds no lease file takes it for "a first start or
a finished fence" (`src/agent.zig:811-815`) and fences nothing. The job
containers of the previous agent process still run. With the start records
gone, nothing on the node knows their deadlines: the offline deadline
(`Agent.before_call`) works from the start record. Once the agent has
registered, its pass finds a container with no record (`unknown`), stops it
and reports the run lost, so the damage is bounded by the time to register.
If the store cannot be reached, there is no such pass: the containers run
with no fence and no deadline while the node's old lease expires, the node
is declared lost and the job controller ends the job.

TLC: `finding-job-dirloss` (`AllowDirLoss = TRUE`), `J8_Deadline`, 15 states.
J1 follows once the node is declared lost and the job ended. The config does
not check J1, because the model ends a job at once when its claim's node key
is written again (README, "the tenure-ended wait"), which is right only while
an agent life cannot outlive its tenure unfenced, and this fault is exactly
that.

**Trace** (`finding-job-dirloss`):

```
 2-5                a1 registers on L1, held, marked ready
 6-8                job submitted, placed on a1
 9 JClaim a1        a1 claims and starts the container
10 Tick             running for 1
11 JDirLoss a1      state directory lost, agent process restarted: no lease
                    file, no start record; phase idle, no fence.  The
                    container runs
12-15 Tick x4       a1 does not reach the store.  Running for 5 > deadline 2
                    + grace 1 + kill latency 1: J8_Deadline
```

This is a known cut of the simulator rather than something it gets wrong;
it is here because the trace needs no artefact of a simulated runtime. For
replica containers the same step gives an unfenced container on a lost node
(I1b); the model's slot containers were not extended to show it.

**Suggested repair:** an agent that starts with no lease file and finds
containers with its labels treats it as a lost tenure and fences them before
it registers (the runtime's listing, not the state directory, is the witness
that this is not a first start).

## 7. The stored rollout budget outlives the view it was computed from

Slice 7 of C3 (the rollout controller and the replica controller's use of
the budget) is not built at `2954195`; this is a finding about the design in
`docs/briefs/c3.md` ("Controller design") and `docs/keys.md` (`/rollouts`),
ahead of the code.

**Slice 7 since.** Zigcube now has branch `claude/c3-slice7-controller`
(head `c510eb7`). I have not read it: this pass had no access to the Zigcube
repository. Per the second review of this PR, its `replica_controller.zig`
(`roll_out`, `roll_of`) skips the budget when the service's `mod_revision`
is past the record's `budget_revision`, bounds starts by its own `room =
live_max -| live`, subtracts what the counter moved since the budget, and
retires a running replica only while `running >= replicas -
max_unavailable` on its own snapshot. That is close to the repair below: it
closes the `stored` and `once` traces when the lost mark or the unready
replica is in its snapshot. Whether it closes the last trace below
(`finding-rollout-recheck-records`) depends on what its transaction
compares, which the review does not say. So read this finding as a gap in
the brief, which slice 7 closes if its commit compares what the repair
says; it is not filed against `c510eb7`.

The brief has the rollout controller write the plan into `/rollouts` and the
replica controller obey it: "it starts a new replica only within `may_start`
and retires an old one only within `may_retire`". The budget in the record
is three counts (`start`, `retire`, `retire_unready`). A count is true of the
replicas, the readiness and the service record the rollout controller read.
The replica controller acts later, in another transaction, and R1 is worded
on its view: "every retirement by a rollout leaves `ready >= desired -
max_unavailable` on the controller's view at the revision before it".
Nothing in the record says which view the count belongs to, so anything that
changes between the plan and the act is spent against a count that no longer
holds.

`Rollout.tla` has the switch `Spend` for the ways to read "obeys":

| `Spend` | The replica controller | R1, R2 |
|---|---|---|
| `stored` | acts whenever the count in the record is above zero | fail with no fault at all: two passes spend one count twice |
| `once` | spends each written budget at most once (it remembers the revision) | fail when a replica is lost, or the user scales, between the plan and the act |
| `recheck`, `Compares = "records"` | evaluates `rollout_plan.budget` itself on what it reads, then commits in a transaction that compares the service record, the `/rollouts` record and `/replicas/` | R1 fails when a replica is lost or turns unhealthy between the read and the commit |
| `recheck`, `Compares = "counted"` | the same, and the transaction also compares every `/observed` key and node key it counted | hold (`rollout-base`; the other passing configs use `Compares = "atomic"`, read and commit in one step, which is the same thing: below) |

All traces: `desired = 2`, `max_surge = 1`, `max_unavailable = 0` (the
defaults), so `ready_min = 2` and `live_max = 3`.

**Trace** (`finding-rollout-once-fault`, R1): a lost node between the plan
and the act.

```
 1                  generation 1 is complete: 2 replicas ready
 2 Apply            the user applies generation 2
 3 RoPass           the rollout begins; budget: start 1, retire 0
 4 RcStart          a replica of generation 2 is started (live 3)
 5 Ready            it is ready: ready 3
 6 RoPass           budget: start 0, retire 1   (ready 3 - ready_min 2)
 7 Lose             a node is lost and its generation-1 replica marked
                    lost: ready 2
 8 RcRetire         the replica controller spends "retire 1" on the other
                    generation-1 replica: ready 1 < 2
```

The brief allows for the fault ("faults such as a lost node can lower
`ready` by themselves; the check is that the rollout never causes the
drop"): step 7 is the fault, and step 8 is the rollout, retiring a ready
replica when its own view has no ready replica to spare. Zigcube then serves
from one replica where the policy promised two, until the replacement is
ready. This is the case the feature exists for: a node dying during a
deploy.

**Trace** (`finding-rollout-once-scale`, R1): steps 1 to 6 as above, then

```
 7 Scale            the user scales to 3: ready_min is now 3, ready is 3
 8 RcRetire         "retire 1" is spent: ready 2 < 3
```

**Trace** (`finding-rollout-once-surge`, R2):

```
 2 Apply            generation 2
 3 RoPass           budget: start 1
 4 Scale            the user scales to 1: live_max is now 2, live is 2
 5 RcStart          "start 1" is spent: live 3 > 2
```

**Traces** (`finding-rollout-stored-r1`, `finding-rollout-stored-r2`): no
fault and no user.

```
 1-6                as above; budget: start 0, retire 1
 7 RcRetire         a pass retires one generation-1 replica: ready 2
 8 RcRetire         the next pass reads the same record: ready 1 < 2
```

```
 3 RoPass           budget: start 1
 4 RcStart          live 3
 5 RcStart          the next pass reads the same record: live 4 > 3
```

**Trace** (`finding-rollout-recheck-records`, R1): the replica controller
computes the budget itself, but on a read that a fault overtakes.

```
 2 Apply            generation 2
 3 RoPass           the rollout begins
 4-5 RcRead, RcCommit  a replica of generation 2 is started
 6 Ready            it is ready: ready 3
 7 RcRead           the replica controller reads: ready 3, ready_min 2;
                    budget retire 1; it will retire a generation-1 replica
 8 Lose             the generation-2 replica's node is lost and marked:
                    ready 2
 9 RcCommit         the transaction compares /services, /rollouts and
                    /replicas/, none of which moved: a generation-1
                    replica is retired, ready 1 < 2
```

This is the `once` trace with the plan and the act in one process. A read
followed by a separate commit is "once" again unless the commit fails when
what was counted has moved. An agent's write of an unhealthy replica in
place of step 8 does the same.

With no fault and no scale, `once` holds every check (`rollout-once-quiet`),
and so does a budget written for one target and spent after a newer apply
(`rollout-once-no-target-check`): a stale count is only wrong when `ready`,
`live` or `desired` moved against it.

**Suggested repair:** the replica controller calls `rollout_plan.budget`
itself, on the replicas, the observed readiness, the lost marks and the
service record it reads, and acts within that (or within the smaller of
that and the stored count), in a transaction that compares the
`mod_revision` of **every** key it counted: the service record, the
`/rollouts` record, the `/replicas/` records, and each `/observed` key and
node key (lost mark) that went into `ready` and `live`. At most
`replicas_max` of each. Being the only writer of `/replicas/` is not
enough: readiness is written by the agents and lost marks by the node
controller, and those are what move under it (`finding-rollout-recheck-records`).
With those compares a commit happens only on the state it read, so it is
the same as reading and acting in one step; that is why the other passing
configs use `Compares = "atomic"` (smaller), and `rollout-base` checks the
split read and commit with the compares. The record then
carries the phase, the target and the deadline, which is what only the
rollout controller knows, and its `budget` is for `zcube` to show. The
function is pure and in the core, so nothing new is needed. A cheaper repair
that keeps the stored count as the authority (the record names the `ready`,
`live` and `desired` it was computed from, and the replica controller spends
it only while they still hold) closes the traces above too, and stalls
whenever they differ.

`sim-c3`'s R1 witness should take a node loss between a `/rollouts` write
and the next replica controller pass; a witness that only loses nodes
between passes of both controllers does not see this.

## 8. A failed first generation never ends

R7 as the task and the brief word it: a rollout always ends, complete,
paused, or failed and then rolled back. With `on_failure rollback` a failed
apply owes a rollback, and the rollback handler makes a generation from the
one before. A service's first generation has none before it. The handler
refuses, the rollout stays `failed` with the rollback owed, and the
controller calls the handler again on every pass.

The slice-6 decision knows this (item 4: "without the pause it would stay
`failed` calling it") and lets a user's pause end it. It is here because
the property fails without a user: `finding-rollout-first-generation`,
`R7_RolloutEnds` violated.

**Trace** (`finding-rollout-first-generation`):

```
 1                  a new service: generation 1 rolls out
 2-3 RcStart x2     two replicas started
 4 Ready            one is ready
 5 RoFail           the progress deadline passes: phase failed, rollback
                    owed
 6 Ready            the second is ready: the service is whole
 7 ...              Rollback is refused (from = 0); the record stays failed
                    and owed, for ever
```

The image need not be bad: here the first rollout was only slow, both
replicas are ready one step later, and the record still says `failed` with
a rollback owed, because done wins over failure only while the rollout is
running.

**Suggested repair:** `rollout_plan.State` has no `from` (only the
`/rollouts` record has it, `docs/keys.md`), so one of: the rollout
controller checks the record's `from` before it calls the rollback handler,
and when it is 0 writes `failed` with no rollback owed (the decision's
"nothing to roll back to"); or `rollback_owed` takes a `first: bool` (or
`from`) as an input next to `reason`; or the controller treats that failure
as `on_failure pause`. Either makes R7 hold as
worded; the passing liveness configs (`rollout-live*`) are services that
have a generation to go back to.

## 9. An address released by a name that is in use again is never free

`mesh_address.reusable` (`src/mesh_address.zig:121-128` at `18e9838`) takes
a released hold when the quarantine has passed and
`replicas_remain(hold.service)` is false. The hold names its service by
**name**, and `replicas_remain` (`:132`) looks for any replica record under
that name. A service that is deleted and applied again takes a new address
(decision 2026-11-13: "a deleted and re-applied service takes a new
address"), and its old hold keeps its name. From then on the old address is
unusable for as long as a service of that name has a replica, which for a
name like `web` is for ever: the replicas that "remain" are the new
service's, on another address.

So every delete and re-apply of a name that stays in use costs one address
for good. The block has 65,534. **The leak is the bug**: once the counter
has wrapped, a probe passes over addresses that are free in every sense the
decision gives (released a day ago, no replica of the service that held
them).

**At `18e9838`** (what `Mesh.tla` models: its `Next1` probes consecutive
numbers) the leak also refuses creates. ZC-E0207 "127.77.0.0/16 has no free
address" is raised when 500 numbers in a row are unusable, and with
`services_max = 256` that takes at least 244 quarantined or name-blocked
ones. `exhausted` writes nothing, so the counter stays where it is and every
later create is refused at the same place until one of those names is
deleted and its replicas are gone. A deploy script that replaces one
service by delete and apply makes such a run: 500 replacements of `web`
with no other create between them are 500 consecutive holds named `web`,
499 of them released, none ever reusable while `web` runs.

**At `b9ae3bd`** (the head of `claude/c4-slice1` since review; I have not
read it, this pass had no access to the Zigcube repository, and this
paragraph is the second review's reading of it) `assign` probes 250 numbers
in order, then 250 spread over the whole block with stride 261. A run of
name-blocked holds after the counter then no longer refuses creates while
the block has free numbers elsewhere: E0207 with a namesake needs about 500
blocked numbers spread over the block, so the refusal above is much rarer
than at `18e9838`, and the "advance the counter" repair below is
overtaken. The leak is unchanged: `reusable` still calls
`replicas_remain(ctx, hold.service, observed)`, keyed on the name, and the
decision's "after which nothing creates `/replicas/<old>/`" is false exactly
when the name is applied again.

It needs 65,534 creates before it shows, which a cluster that redeploys by
delete and apply reaches in time and one that only updates never does.

TLC: `finding-mesh-namesake`, `M6_ExhaustedMeansFull` violated. The model's
block is 2 addresses and 2 probes, probed in order as at `18e9838`; M6 is
how the leak shows in a block that small, under either probe order.

**Trace** (`finding-mesh-namesake`):

```
 2-5   r1: create a          a takes address 1; counter 2
 7-9   r1: delete a          hold 1 = {a, released at 0}
11-15  r1: create a          a takes address 2; the counter wraps to 1
14,16  r2: a create          reads the counter: candidate 1
17     RepAppear a           the new a, on address 2, has a replica
18-19  Tick x2               clock 2: hold 1 is out of quarantine
20     r2 probes 1           released, quarantine passed: look for replicas
21     r2: replicas of "a"   one remains: address 1 is passed over
22     r2 probes 2           held by a.  Two probes: ZC-E0207
```

Address 1 was free: released a quarantine ago, and no replica of the
service that held it is left. (In TLC's shortest trace r2 is a second create
of `a` that read the service before step 15; the name r2 creates plays no
part, and a create of `b` at step 14 is refused the same way.) With
`HoldByIncarnation = TRUE` (below) the same config passes
(`mesh-by-incarnation`).

**Suggested repair:** make the hold name the incarnation, not the name: put
the service's creation stamp in the hold (the `/rollouts` record already
carries `service_created` for the same purpose) and have `replicas_remain`
ask for replicas of that incarnation; or, with no new field, let
`replicas_remain` ignore the name when a live `/services/<name>` holds a
different address and was created after `released_at_ms` (its replicas are
then the new service's, as long as the old one's are gone by the end of the
quarantine, which I1b bounds in seconds). `mesh-by-incarnation` checks the
first of these only. The "no new field" variant is **not checked**: in this
model, where a replica record may outlive its service, it would drop the old
incarnation's replica check whenever a namesake lives and so break M4, and
it compares the service's creation time with `released_at_ms`, two
wall-clock readings (finding 10). At `18e9838`, `exhausted` could also
advance the counter past the run it probed, so that one bad run does not
refuse every create; `b9ae3bd`'s spread probes do that job.

## 10. The quarantine is a difference of wall-clock readings

`release` stamps `released_at_ms = ctx.clock.now_ms()` on the API server
that handles the delete, and `reusable` compares it with `now_ms()` on the
API server that handles a later create (`src/mesh_address.zig:64`,
`:124-126`). A reading that is behind the stamp is handled (`now <
released`: not reusable). One that is ahead is not: a server whose clock was
stepped forward, or two servers whose clocks differ, end the quarantine
early by that much. It is finding 3 again (absolute wall-clock values in
the store), with far more room: the quarantine is a day, so it takes a
clock that is wrong by hours to matter.

TLC: `finding-mesh-clock-step` (`ClockStep = 2 = Quarantine`),
`M3_Quarantine` violated: address 1 is released at 0, the clock of the
server steps, and a create takes address 1 at real time 0.

**Suggested repair:** none needed for skew of seconds. If it is to hold
under a stepped clock, stamp the release with the store's clock (as lease
deadlines are) or keep the release's store revision and a bound on revision
age.

## 11. While paused, a lost old replica is replaced by the paused release

The brief's R4: "While paused, the rollout starts and retires nothing
(failure replacement of **same-generation** replicas still happens)". Its
design of the replica controller: a failed replica is "replaced under the
same rules as today", and today's rule starts a replica of the service's
spec, which during a rollout is the new generation. The two disagree when
an old replica fails while the rollout is paused.

TLC: `finding-rollout-pause-replace` (`ReplaceSameGen = FALSE`, "the same
rules as today"), `R4_PauseHolds` violated.

**Trace** (`finding-rollout-pause-replace`):

```
 2-3 Apply x2       generations 2 and 3
 4 RoPass           the rollout of 3 begins: budget start 1
 5 Ask pause        the user pauses
 6 RoPass           paused, nothing of generation 3 started
 7 Lose             a node is lost: a generation-1 replica is marked lost
 8 RcReplace        failure replacement starts a replica of generation 3
```

In practice: an operator pauses a suspect release, a node dies, and the
suspect release gets a replica anyway, at a time the operator was told
nothing of it would start.

The passing configs take R4's reading (`ReplaceSameGen = TRUE`): while
paused, a lost replica is replaced by one of its own generation, and a
shortfall with no lost replica behind it (a scale up while paused, or a
retirement that finished stopping after the pause) waits for the resume.
In the model the replacement owed is remembered from the loss until the
rollout controller's next pass leaves the record in another phase than
paused.

**Suggested repair:** the brief says which rule wins. If R4's: failure
replacement while a rollout is paused (or failed) starts the generation of
the replica it replaces, which the replica record names, and the brief says
what happens to a shortfall that no failed replica explains. If "the same
rules as today": R4's parenthesis says replacement may start the target
generation while paused.

## Smaller differences between authority.md and the code

- **`mark_lost` time.** authority.md says the node is declared lost "at
  expiry"; the code stamps `at_ms = now` when the node controller gets to it
  (`src/node_controller.zig:218-241`). A slow node controller makes the grace
  longer, which is safe; see finding 2 for the case where it is not.
- **Fence on a refused write.** Decision 2026-11-08 says the agent fences at
  once when told its tenure ended. The code does so for `LeaseNotFound` on a
  keepalive (`src/agent.zig:738-742`), for a refused observed write
  (`src/agent.zig:1392-1398`) and for a refused store summary
  (`publish_store`). It learns nothing from a keepalive that
  succeeds on a lease whose key moved (finding 1). The model follows the code.
- **Stray stop.** A container whose replica is gone from the node is stopped
  with `stop_grace_ms` (5000 ms), not `fence_stop_ms` (2000 ms). authority.md
  bounds I1b's overlap by `lost_grace_ms` plus kill latency (1.9 s) and does
  not mention this stop. In the passing configs no stray ever has a live
  replacement next to it; finding 1 is where it shows.
- **Old renewal rule.** `src/fencing.zig:89` keeps the old `ttl / 3` rule for
  the test; `teeth-old-renew` is the model's version of
  `src/agent_fence_test.zig`: with a fence window of `ttl / 3` the agent
  fences on every lease and never settles. The rule of 2026-11-06
  (`src/fencing.zig:78-83`) passes in the same constants (`live-short-window`).
- **J7's "the run has no stop".** core.md's J7 says each start has a
  committed claim "and the run has no stop". The agent judges that on the run
  as its pass read it: `claim` returns if the run has a stop, then writes the
  claim (which compares the run's revision), fetches the input and starts
  (`src/agent_jobs.zig:724`, `begin`); a later pass that finds
  `claimed_unstarted` tests the run it read at its own start. A stop that
  commits after the claim and before the start is not seen by that start. It
  is seen on the next pass and honoured within the grace (J6 holds), so what
  the code keeps is "no stop when the claim committed", up to one pass. The
  model has it the same way.

- **Failure replacement and stopping replicas.** The C3 brief says failure
  replacement "never waits for `may_start`". If it counts live replicas
  without the stopping ones it starts a replica past `desired + max_surge`
  (`teeth-rollout-replace-ignores-stopping`, R2). The brief does not say
  which count it uses; `rollout_plan` counts a stopping replica as live.
- **Two compares where one would do.** The create's transaction compares
  both `/mesh-address-next` and the hold. In the model either alone keeps
  M1 to M5 (`mesh-counter-only`, `mesh-hold-only`). Not a fault: the second
  is the one that survives a change to how the counter is written.
- **ZC-E0105 under concurrent creates.** Every create writes the counter, so
  creates of different services conflict with each other, and one that loses
  `apply_attempts_max` times in a row is refused ZC-E0105 though nothing
  else is wrong. The model has it as an outcome (`M7_RequestsEnd` counts it
  as ending).

## What TLC did not find

In the passing configs (README, results table) I1a, I1b (both forms), I2, I3,
I7, the 2026-11-08 rule, `TimedOutPutIsDead` and both liveness properties
hold, under call loss, delay, late replies, timeouts, stale keepalives,
crashes, reboots, two schedulers, and skew up to the bound. That is a statement about the model at these sizes, with
the cuts the README lists.

For jobs: with the scheduler releasing ended runs before retention and no
state directory lost under a running agent (findings 5 and 6), J1 to J3 and
J5 to J11 hold on one node under call loss, timeouts, late replies, expiry,
reboots with and without the state directory, cancels at any moment, slow
input fetches and, in `jobs-reuse`, a second incarnation of the name. J4 is
not expressible. The job configs have one job and no clock error. Two nodes
are checked with call loss and expiry only (`jobs-two-nodes`); reboots,
cancels and slow fetches are checked on one node.

For rollouts (`Rollout.tla`, the design of the brief with the replica
controller evaluating the budget itself and comparing every key it counted,
and replacing a lost replica by its own generation while paused): R1, R2,
R4 and R8 hold with surge 1 and with unavailable 1, across lost replicas,
replicas that turn unready, pause and resume, a scale, bad releases,
automatic rollback and a new apply over a rollout in flight. Under those
settings R1, R2, R4 and R8 are the replica controller's and the rollback's
own guards (R1: `Budget.r > 0` implies `ready - 1 >= ready_min`; R2: the
start and replacement guards; R4: the phase check and same-generation
replacement; R8: the rollback's compare), so these "holds" results are true
by construction. The content is elsewhere: the state invariants
(`R1_ReadyFloor`, `R2_LiveCeiling`, `R4_NoBudgetAtRest`), the finding
configs (which show what each guard is needed against), the teeth, and R7.

R7: with no progress deadline, so that a rollout fails only from a real
cause (a replica unready for good, or a bad release's replica),
a rollout of a service that has an earlier generation always ends
(`rollout-live-no-deadline`, `rollout-live-user-no-deadline`); a replica
controller that never starts a replica fails that check
(`teeth-rollout-no-start`). The configs with the deadline (`rollout-live`,
`-live-user`, `-live-pause-policy`, `-live-no-unready`, `-live-full`) check
only that the deadline ends what nothing else ends: the deadline is weakly
fair, so it rescues every stall, and they cannot see one. The unready
retirement rule changes no safety check.

One service, replicas as counts, no clock, no placement, and the recreate
policy is not modelled. The lease and fencing model is not composed with
it: a replica of a node that is dead and not yet declared lost counts as
ready here, as it does to the controller.

Not checked: the rollback's compare is on the generation in the model and
on the service record's revision in the brief. A scale between the failure
and the rollback changes the revision and not the generation: the model
rolls back, the brief's compare fails, and the brief does not say whether
the controller reads again and retries or leaves the rollout `failed` with
a rollback owed (an R7 question like finding 8). No liveness config scales.

For mesh addresses (`Mesh.tla`): no interleaving of two requests in flight
over six creates and deletes of two names gives one address to two live
services, reuses one inside the quarantine or while a replica record of its
old service is left, leaks one or deletes a hold; and every request ends.
The compare-and-set race that review B of C4 slice 1 found untested has no
bad outcome in the model, with both compares or with either one. The block
is 2 addresses with 2 probes; the store never fails; clocks are right
(finding 10 is the model with one that is not).
