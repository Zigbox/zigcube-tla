# Findings

What TLC found when the model follows the Zig code and `docs/authority.md`
where they differ. File and line numbers are in Zigbox/zigcube at commit
`f7736a7`. Nothing in Zigcube was changed.

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
| 5 | Retention deletes a job without looking at its run's assignment; if the scheduler has not released it and the name is used again, the agent claims under the old assignment and starts the run on every pass | **protocol bug** (J2; a run that never ends), needs an assignment that outlives its job by an hour | `finding-job-reuse-assigned` | `J2_StartedOnce` violated |
| 6 | A state directory lost under a running agent: no fence, no start records, the job containers run on | gap the simulator names and does not cover | `finding-job-dirloss` | `J8_Deadline` violated (then J1) |

With those six faults excluded, every invariant holds in every passing
config, and TLC caught every safeguard that was taken away (README, teeth
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

**Suggested repair:** make the deletion and the assignment exclusive.
Either `drop_job` reads the run's assignment and leaves the job for a later
pass while one exists (compare its absence in the transaction), or the job
controller's create refuses or waits while `/assigned/*/<name>-job` exists.
On the agent, a claim whose subject epoch is older than the run's
`create_revision` can be refused locally: that assignment is not of this
run.

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

TLC: `finding-job-dirloss` (`AllowDirLoss = TRUE`), `J8_Deadline`, 15 states;
the same run goes on to violate `J1_NotAliveAfterEnding`.

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

## What TLC did not find

In the passing configs (README, results table) I1a, I1b (both forms), I2, I3,
I7, the 2026-11-08 rule, `TimedOutPutIsDead` and both liveness properties
hold, under call loss, delay, late replies, timeouts, stale keepalives,
crashes, reboots, two schedulers, and skew up to the bound. That is a statement about the model at these sizes, with
the cuts the README lists.
