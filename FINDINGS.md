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
| 1 | A late duplicate of a registration PUT moves the node key onto an orphan lease | **protocol bug** (I1b; and a node that stays lost) | `finding-stale-put`, `finding-stale-put-window`, `finding-stale-put-live` | `I1b_NoOverlap`, `I1b_Window`, `FencingSettles` violated |
| 2 | The lost grace is counted from the first `mark_lost`, so a second expiry can have none | code differs from authority.md | `finding-spent-grace` | `I1b_NoOverlap` violated (same tick); `I1b_Window` holds |
| 3 | Lease deadlines are absolute store-clock values | code differs from authority.md | `finding-store-setback` | `I1b_Window` violated |
| 4 | The inequality has no term for a late agent step | gap in authority.md, zero slack in the constants | `finding-step-lag` | `I1b_NoOverlap` violated; holds when the lag is under `lost_grace` |

With those four faults excluded, every invariant holds in every passing
config, and TLC caught every safeguard that was taken away (README, teeth
table).

## 1. A late registration PUT re-attaches the node key to an orphan lease

**This is a real protocol bug, in the code and in authority.md alike.**

The agent registers with `lease_grant` and then a PUT of `/nodes/<node>`
attached to the new lease (`src/agent.zig:745-757`). The server applies that
PUT with no compare (`src/agent_api.zig:284-314`). The agent adopts the lease
only when the PUT's reply arrives (`src/agent.zig:760-762`); if the call
fails, the next heartbeat grants another lease and PUTs again.

A PUT that the agent gave up on can still be applied later: the request was
sent, the connection broke or timed out, and the server (or a proxy that
retries) runs it after the agent's next registration succeeded. Then:

1. `/nodes/<node>` is now attached to the abandoned lease L1, which nobody
   renews. Its revision changed, so the agent's tenure is superseded.
2. The agent holds L2 and renews it. A keepalive looks only at the lease
   (`src/agent_api.zig:316-331`), so it succeeds: the agent's fence timer is
   pushed back on every renewal, for a lease that no longer protects anything.
3. L1 expires. The node key goes, `mark_lost` runs
   (`src/node_controller.zig:218-241`), and after `lost_grace_ms` the replica
   controller replaces the node's replicas
   (`src/replica_controller.zig:292-304`, `541-565`) while the agent is in
   `held`, well before its fence time, with the containers running.

The fencing inequality does not help: it relates the agent's fence to the
lease the agent renews, and the store expired another one.

What bounds the damage in the code: the agent's next observed write is refused
(the tenure compare fails, `src/agent.zig:1392-1398`) and it fences at once
(decision 2026-11-08). So the overlap needs the agent to make no observed
write between the stale PUT and the replacement, which is the usual state of a
node whose containers are all running and reported. A connected agent then
sees the replica gone and stops the stray container on its next pass
(`src/agent.zig:1339-1346`); one that is partitioned from the watch but not
from keepalives, or slow, runs on (this last case is read from the code; the
model's agent always runs its pass on time, so TLC's traces show the bounded
forms). `finding-stale-put-window` shows the overlap outlasting
`lost_grace_ms` plus kill latency even so.

The same fault also breaks liveness without any overlap
(`finding-stale-put-live`): with nothing running, the agent renews L2 for
ever, never writes, never learns; the node stays lost and gets no work.

**Trace** (`finding-stale-put`, 28 states, `I1b_NoOverlap`):

```
 2 Register a1     lease L1 granted (ttl 6); PUT /nodes/a1 on L1 sent
 3 CallFail a1     the agent gives the PUT up; the request is still on its way
 4-7 Tick x4       L1 has 2 left
 8 Register a1     lease L2 granted; PUT /nodes/a1 on L2 sent
 9 Serve           PUT(L2) applied: /nodes/a1 -> L2          (reply delayed)
10 ServeStale      PUT(L1) applied: /nodes/a1 -> L1          <-- the bug
11 MarkReady a1
12-13 Plan, Commit s1 assigned to a1
14 Tick            L1 has 1 left, L2 has 5
15-18              a2 registers, is marked ready
19 Tick            L1 has 0 left
20 Expire a1       /nodes/a1 deleted (it was on L1); L2 lives on, 4 left
21 MarkLost a1
22 Tick            lost for 1 = LostGrace
23 Ack a1          reply to PUT(L2) arrives: a1 is `held` on L2, age 2 < fence time 3
24 Start a1        a1 starts s1
25 Replace         replica controller: a1 is lost, grace over; s1 freed
26-27 Plan, Commit s1 assigned to a2
28 Start a2        s1 runs on a1 and on a2.  a1: phase held, lease L2 with 3 left,
                   2 ticks before its fence time.  I1b_NoOverlap violated.
```

Here a1 has not yet reported, so its next pass ends it (the stray stop, or the
refused report and the fence at once). `finding-stale-put-window` (37 states)
continues that way: the report at state 25 is refused, a1 fences at once, and
its container is still there 3 ticks after a2's started; the window I1b names
is `LostGrace + KillLatency` = 2. The fence at once takes `StopTime +
KillLatency` (2900 ms in Zigcube) and the replacement did not wait for it,
because the store never promised to: the lease it expired was not the agent's.

`finding-stale-put-live` (one agent, nothing to run), after the faults stop:

```
 2 Register a1     L1; PUT sent      3 CallFail (PUT still on its way)
 4 Heal            no fault from here on
 9 Register a1     L2; PUT sent     10 Serve: /nodes/a1 -> L2
11 ServeStale      /nodes/a1 -> L1  13 Ack: a1 held on L2
16 Expire          /nodes/a1 deleted with L1
17 MarkLost a1
18-23              Tick, Renew(L2), Serve ok, Ack, Tick, Tick; back to 18, for ever
```

The node is lost, its agent is `held` and renewing, and nothing in the
protocol tells it.

**Suggested repair** (not applied, not modelled as a fix beyond the first):

- Make the registration a transaction that compares on the lease it replaces
  ("`/nodes/<node>` absent, or attached to the lease I last held"), or carry a
  per-agent registration counter in the value and refuse a lower one. Then a
  late duplicate fails.
- And have the keepalive reply (or the agent's renewal) check that
  `/nodes/<node>` is still attached to the lease being renewed, so that an
  agent whose key moved fences as for `LeaseNotFound`.

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

**Trace** (`finding-spent-grace`, 34 states, `I1b_NoOverlap`):

```
 2-6               a1 registers on L1 (reply not yet back), marked ready; s1 assigned to a1
 7 CallFail a1     the reply to the PUT is lost; a1 is idle
 8-10 Tick x3
11 Register a1     L2 granted; PUT sent, delayed
12-14 Tick x3      L1 has 0 left
15 Expire a1       /nodes/a1 deleted
16 MarkLost a1     status lost, at_ms = now (t0)
17 Serve           PUT(L2) applied: /nodes/a1 -> L2.  The node controller does not
                   get to it: status stays `lost` with at_ms = t0
18 Ack a1          a1 held on L2, age 2
19 Start a1        a1 starts s1 (its assignment was never removed)
20 Renew a1        keepalive sent, then lost (23)
21 Tick            t0 + LostGrace has passed
24 TimerFence a1   age 3 = fence time: TERM; KILL due at 4, gone by 5
28-29 Tick x2      L2 has 0 left; a1 age 5: the container goes in this tick
30 Expire a1       /nodes/a1 deleted
31 Replace         status is `lost` since t0, grace long over: s1 freed at once
32-33 Plan, Commit s1 assigned to a2
34 Start a2        same tick as a1's kill completes.  I1b_NoOverlap violated.
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

The model's `Setback` does this to one lease. With a setback larger than the
margin, TLC finds the overlap past the window.

What the code does have: after such an expiry the agent's next keepalive gets
`LeaseNotFound` and it fences at once (`src/agent.zig:738-742`); the
`setback-fences-at-once` config checks that this holds
(`TenureEndFencesAtOnce`). That bounds the overlap by the renewal interval
plus the fence time, not by the window I1b names.

An asynchronous standby is a different matter: `docs/operations.md:20-29`
says it is unsupported (ZC-E0215), so it is not a finding.

**Trace** (`finding-store-setback`, `I1b_Window`):

```
 2-6               a1 registers on L1 (reply delayed), marked ready; s1 assigned to a1
 7 StoreSetback    the store's clock steps forward: L1 has 1 left, not 6
 8 Tick            L1 has 0 left
 9-10              a2 registers
11 Expire a1       /nodes/a1 deleted
13 MarkLost a1
15 Tick            lost for 1 = LostGrace
16 Ack a1          the reply to a1's PUT arrives: held, age 2, a full tick before
                   its fence time
17 Start a1        a1 starts s1
18 Report a1       refused (tenure superseded): a1 fences at once, KILL due at 3
19 Replace         s1 freed
20-23              s1 assigned to a2, started, reported
24-29 Tick x3      a1's container is there for 3 ticks next to a2's.
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
`d` fences late by `d`. The inequality in `src/fencing.zig:23` and `36-40` is
`margin >= stop + skew + kill_latency`, and Zigcube's constants meet it with
equality (`src/constants.zig:132-157`). So any lag eats into `lost_grace_ms`
(1000 ms), and a lag above it is an overlap.

authority.md section 3 assumes the agent "alive and scheduled"; it gives no
number. `fence_poll_ms` is 100, so a healthy agent is within 100 ms; a step
that blocks (a slow runtime call inside a pass, a long GC-less pause under
memory pressure) is not bounded by anything the agent checks.

TLC: with a lag of one tick and a lost grace of one tick the two meet
(`finding-step-lag`, `I1b_NoOverlap`, zero-length overlap); with a lost grace
of two ticks everything holds (`step-lag-within-grace`).

**Trace** (`finding-step-lag`, `I1b_NoOverlap`):

```
 2-5               a1 registers on L1, held, marked ready
 6-9 Tick x4       a1's clock lost one tick (the skew bound): age 3, L1 has 2 left
10-15              a2 registers; s1 assigned to a1
16 Start a1        a1 starts s1
17 TimerFence a1   age 3: TERM.  KILL nominally at 4, gone by 5; with a step one
                   tick late, by 6
18-19 Tick x2      L1 has 0 left; a1 age 5
20 Expire a1
21 MarkLost a1
22 Tick            lost for 1 = LostGrace; a1 age 6: the container goes in this tick
23 Replace         s1 freed
24-25 Plan, Commit s1 assigned to a2
26 Start a2        a1's container is still there.  I1b_NoOverlap violated.
```

**Suggested repair:** add the step bound to `margin_needed_ms` (and to
ZC-E0121), and have the fence fire from a timer that does not wait for the
pass.

## Smaller differences between authority.md and the code

- **`mark_lost` time.** authority.md says the node is declared lost "at
  expiry"; the code stamps `at_ms = now` when the node controller gets to it
  (`src/node_controller.zig:218-241`). A slow node controller makes the grace
  longer, which is safe; see finding 2 for the case where it is not.
- **Fence on a refused write.** Decision 2026-11-08 says the agent fences at
  once when told its tenure ended. The code does so for `LeaseNotFound` on a
  keepalive (`src/agent.zig:738-742`) and for a refused observed write
  (`src/agent.zig:1392-1398`). It learns nothing from a keepalive that
  succeeds on a lease whose key moved (finding 1). The model follows the code.
- **Old renewal rule.** `src/fencing.zig:89` keeps the old `ttl / 3` rule for
  the test; `teeth-old-renew` is the model's version of
  `src/agent_fence_test.zig`: with a fence window of `ttl / 3` the agent
  fences on every lease and never settles. The rule of 2026-11-06
  (`src/fencing.zig:78-83`) passes in the same constants (`live-short-window`).

## What TLC did not find

In the passing configs (README, results table) I1a, I1b (both forms), I2, I3,
I7, the 2026-11-08 rule and both liveness properties hold, under call loss,
delay, late replies, stale keepalives, crashes, reboots, two schedulers, and
skew up to the bound. That is a statement about the model at these sizes, with
the cuts the README lists.
