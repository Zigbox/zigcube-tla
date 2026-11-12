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

**What TLC found is in [FINDINGS.md](FINDINGS.md).** Read that first.

## How to run

```sh
./run.sh                  # every config but the slow one; about 16 minutes on 4 cores
./run.sh --slow           # the slow one too
./run.sh base teeth-skew  # only these
```

Needs Java 11 or later and `curl`. `run.sh` downloads `tla2tools.jar` v1.7.4
into `.tools/` (not committed), checks its SHA-256, runs TLC on each config
and compares the result with the config's `\* EXPECT` line. It exits non-zero
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
  replies. With both agents faulty the state space is above 18 million
  distinct states (see the results table).
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
| both-faulty (`--slow`)       | ok                                         | not finished (see below)                   |          - |         - |     - |     - | not run by default |
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
agents) was stopped by hand with its queue still growing; nothing was violated
in the 18 million states it had seen. It is not evidence either way.

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

## Files

- `Fencing.tla`: the model.
- `configs/*.cfg`: one TLC config each; line 1 says what it is, line 2 what
  TLC must report, `\* SLOW` on line 3 keeps it out of the default run.
- `run.sh`: the runner. `.github/workflows/tlc.yml`: CI.
- `FINDINGS.md`: what TLC found, with traces and the places in Zigcube.
