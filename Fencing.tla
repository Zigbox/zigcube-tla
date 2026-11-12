------------------------------ MODULE Fencing ------------------------------
(***************************************************************************)
(* Zigcube's lease, fencing and authority protocol (docs/authority.md,     *)
(* sections 2 to 4), written from the documents and the Zig sources and    *)
(* independent of the sim-c1 simulator.                                    *)
(*                                                                         *)
(* One store (linearizable), one server (node controller, replica          *)
(* controller, one or more scheduler instances), N agents.  Time is        *)
(* discrete.  The store's clock is real time; an agent's clock may run     *)
(* slow, losing at most Skew ticks over one lease period.  README.md says  *)
(* what is abstracted away; FINDINGS.md what TLC found.                    *)
(*                                                                         *)
(* Revisions are not numbers here.  Every use of a revision in the         *)
(* protocol is an equality compare against the current one, so each        *)
(* holder of a revision keeps one bit instead: "what I read is still the   *)
(* current revision".  A write to a key clears the bit of every holder.    *)
(* That is exact for compare-and-set and keeps the state space finite,     *)
(* which is what lets TLC check liveness without a bound on revisions.     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Agents,          \* the nodes; one agent each
    Faulty,          \* the agents the environment's faults may touch
    Slots,           \* replica slots: one unit of work that must run once
    Scheds,          \* scheduler instances (2 = a deposed leader still acting)
    None,            \* a model value
    NL,              \* lease slots per node the store model keeps (3 is enough)
    \* --- the fencing constants (src/constants.zig), in ticks ---
    TTL,             \* lease_ttl_ms
    Margin,          \* fence_margin_ms
    StopTime,        \* fence_stop_ms: TERM to KILL
    StopGrace,       \* stop_grace_ms: TERM to KILL when the pass stops one
                     \* container whose replica is gone (not a fence)
    KillLatency,     \* fence_kill_latency_ms: KILL to the process gone
    LostGrace,       \* lost_grace_ms: mark_lost to replacement
    Skew,            \* ttl * clock_skew: the ticks the inequality allows an
                     \* agent clock to lose over one lease period (skew_ms)
    SkewActual,      \* the ticks an agent clock really may lose over one
    WindowMin,       \* fence_window_min_ms
    RenewSlack,      \* renew_slack_min_ms
    RenewRule,       \* "new": min(ttl/3, ttl - margin - slack); "old": ttl/3
    StepMax,         \* how late an agent step may run (0: the documents' model)
    HealedDelay,     \* once healed, a call is answered within this many ticks
    Setback,         \* ticks a store clock step or failover takes off every lease
    \* --- what the environment may do ---
    AllowReboot, AllowWedge,
    AllowLoss,       \* calls may be lost: a broken connection, a process restart
    StalePut,        \* a registration PUT whose connection broke, or whose
                     \* agent restarted, may still be applied later
    StaleKa,         \* a keepalive given up or lost may still be applied later
    AllowHeal,       \* faults may stop for good (the liveness configs)
    NodeCtlPrompt,   \* the node controller judges a node within the tick
    \* --- the safeguards; FALSE takes one away (the "teeth" configs) ---
    RequireInequality,  \* refuse constants that fail fencing.inequality_problem
    FenceOnConflict,    \* a refused observed write fences at once
    FenceOnLeaseGone,   \* a keepalive answered LeaseNotFound fences at once
    CompareTenure,      \* observed writes compare /nodes/<node> at the tenure
    CompareReady,       \* placements compare the node and its status
    CompareAbsent,      \* placements compare the replica and "assignment absent"
    CheckAdmissible,    \* decisions cite only admissible observations
    UseLostGrace        \* replacements wait lost_grace_ms after mark_lost

Min(x, y) == IF x <= y THEN x ELSE y
Max(x, y) == IF x >= y THEN x ELSE y

(***************************************************************************)
(* The arithmetic of src/fencing.zig.                                      *)
(***************************************************************************)
MarginNeeded == StopTime + Skew + KillLatency               \* margin_needed_ms
\* inequality_problem (ZC-E0121): margin_too_small, ttl_too_short.
InequalityOK == /\ Margin >= MarginNeeded
                /\ TTL >= Margin + WindowMin
FenceAt == TTL - Margin                 \* fence_at_ms - s
RenewAfter == IF RenewRule = "old" THEN TTL \div 3
              ELSE Min(TTL \div 3, IF FenceAt > RenewSlack THEN FenceAt - RenewSlack ELSE 0)
\* agent_io_timeout_ms: the bound on one server call of an agent that holds
\* no lease (agent_http.zig: one request per connection, no retry).  It is
\* 10 s in constants.zig, the same as lease_ttl_ms.  A call of an agent that
\* holds a lease is capped at its fence time, which is earlier.
IoTimeout == TTL
\* No agent that is not wedged gets older than this (see Urgent), and no
\* call is older.
AgeCap == Max(FenceAt + StopTime + KillLatency + StepMax, IoTimeout)
StopCap == StopGrace + KillLatency + StepMax + 1
OvlCap == TTL + StopGrace + StopTime + KillLatency + 1
ZombCap == StopTime + KillLatency + StepMax + SkewActual + 2

ASSUME /\ TTL \in Nat /\ Margin \in Nat /\ TTL > Margin
       /\ NL \in Nat /\ NL >= 2
       /\ StopGrace \in Nat
       /\ RenewRule \in {"new", "old"}
       /\ RequireInequality => InequalityOK

Leases == 1..NL

VARIABLES
    \* --- agent ---
    phase,      \* [Agents -> {"idle","held","fencing"}]; persisted in lease.json
    wedged,     \* the node is frozen: nothing on it moves, not even a KILL
    age,        \* agent-clock ticks since s, the send time of the last
                \* acknowledged request; persisted
    killAge,    \* the age at which the fence sends KILL; persisted
    lost,       \* ticks the agent's clock has lost since s
    callLost,   \* ticks the agent's clock has lost since the call was sent
    myLease,    \* the lease the agent holds, 0: none
    tenureOk,   \* the agent's tenure is the current revision of /nodes/<node>
    callKind,   \* the one server call in flight: "none", "put", "ka"
    callSt,     \* "req": not served yet; "ok", "nf": answered, reply in flight
    callL,      \* the lease the call names
    callAge,    \* agent-clock ticks since the call was sent
    pendOk,     \* the revision the served PUT made is still the current one
    stale,      \* a request the agent no longer waits for, still on its
                \* way to the store: [kind, l]
    cont,       \* [Agents -> [Slots -> {"none","run","rep","old","oldrun"}]]:
                \* the container of a slot's replica: none; running, not
                \* reported; running, reported; running, its replica since
                \* replaced; the same, the report of its start still to make
    stop,       \* [Agents -> [Slots -> 0..StopCap]]: 0, or 1 + the agent-clock
                \* ticks since the pass sent TERM to the slot's container
    \* --- store ---
    left,       \* [Agents -> [Leases -> 0..TTL]]: time a lease has left
    keyL,       \* the lease /nodes/<node> is attached to, 0: the key is absent
    status,     \* /node-status/<node>: "none", "ready", "lost"
    statusCur,  \* the status was written for the current /nodes revision
    lostAge,    \* server-clock ticks since mark_lost
    asg,        \* /assigned/<node>/<replica> as pairs <<slot, node>>
    obs,        \* [Agents -> [Slots -> None or [ten, asg]]]: the record
                \* /observed/<node>/<replica> a node keeps of a slot's replica
    plan,       \* [Scheds -> None or [s, n, nodeOk, readyOk, freeOk]]
    \* --- environment and history ---
    healed, jumped,
    ovl,        \* ticks a slot's work has run on two nodes at once, so far
    zomb,       \* ticks since an agent with containers was told its tenure ended
    bad         \* the kinds of transaction that must never commit, if any did

agentVars == <<phase, wedged, age, killAge, lost, callLost, myLease, tenureOk,
               callKind, callSt, callL, callAge, pendOk, stale, cont, stop>>
storeVars == <<left, keyL, status, statusCur, lostAge, asg, obs, plan>>
histVars  == <<healed, jumped, ovl, zomb, bad>>
vars == <<agentVars, storeVars, histVars>>

NoStale == [kind |-> "none", l |-> 0]
HasCont(a) == \E s \in Slots : cont[a][s] # "none"
Free(s) == \A n \in Agents : <<s, n>> \notin asg
NodeReady(n) == keyL[n] # 0 /\ status[n] = "ready" /\ statusCur[n]
\* authority.md section 3: tenure current, assignment current, node ready.
Admissible(n, s) == /\ obs[n][s] # None
                    /\ obs[n][s].ten /\ obs[n][s].asg /\ NodeReady(n)
\* A container the pass stops: its replica is gone from the node.
Stray(a, s) == \/ cont[a][s] \in {"old", "oldrun"}
               \/ (cont[a][s] # "none" /\ <<s, a>> \notin asg)

Init ==
    /\ phase = [a \in Agents |-> "idle"]
    /\ wedged = [a \in Agents |-> FALSE]
    /\ age = [a \in Agents |-> 0]
    /\ killAge = [a \in Agents |-> 0]
    /\ lost = [a \in Agents |-> 0]
    /\ callLost = [a \in Agents |-> 0]
    /\ myLease = [a \in Agents |-> 0]
    /\ tenureOk = [a \in Agents |-> FALSE]
    /\ callKind = [a \in Agents |-> "none"]
    /\ callSt = [a \in Agents |-> "req"]
    /\ callL = [a \in Agents |-> 0]
    /\ callAge = [a \in Agents |-> 0]
    /\ pendOk = [a \in Agents |-> FALSE]
    /\ stale = [a \in Agents |-> NoStale]
    /\ cont = [a \in Agents |-> [s \in Slots |-> "none"]]
    /\ stop = [a \in Agents |-> [s \in Slots |-> 0]]
    /\ left = [a \in Agents |-> [l \in Leases |-> 0]]
    /\ keyL = [a \in Agents |-> 0]
    /\ status = [a \in Agents |-> "none"]
    /\ statusCur = [a \in Agents |-> FALSE]
    /\ lostAge = [a \in Agents |-> 0]
    /\ asg = {}
    /\ obs = [a \in Agents |-> [s \in Slots |-> None]]
    /\ plan = [k \in Scheds |-> None]
    /\ healed = FALSE
    /\ jumped = FALSE
    /\ ovl = [s \in Slots |-> 0]
    /\ zomb = [a \in Agents |-> 0]
    /\ bad = {}

(***************************************************************************)
(* The store.                                                              *)
(***************************************************************************)
\* /nodes/<n> was put or deleted: every revision read before is superseded.
\* Gives the next values of the "still current" bits that name the key.
KeyChanged(n) ==
    /\ tenureOk' = [tenureOk EXCEPT ![n] = FALSE]
    /\ statusCur' = [statusCur EXCEPT ![n] = FALSE]
    /\ obs' = [obs EXCEPT ![n] = [s \in Slots |->
                 IF @[s] # None THEN [@[s] EXCEPT !.ten = FALSE] ELSE None]]
    /\ plan' = [k \in Scheds |->
                 IF plan[k] # None /\ plan[k].n = n
                 THEN [plan[k] EXCEPT !.nodeOk = FALSE] ELSE plan[k]]

\* /node-status/<n> was written: plans that read it are superseded.
StatusChanged(n) ==
    plan' = [k \in Scheds |->
               IF plan[k] # None /\ plan[k].n = n
               THEN [plan[k] EXCEPT !.readyOk = FALSE] ELSE plan[k]]

\* A lease the model must keep: anything else is unobservable.
Referenced(n, l) ==
    \/ keyL[n] = l
    \/ myLease[n] = l
    \/ (callKind[n] # "none" /\ callL[n] = l)
    \/ (stale[n].kind # "none" /\ stale[n].l = l)
FreeLeases(n) == {l \in Leases : ~Referenced(n, l)}

\* expire_leases: the server's timer deletes the keys of a lease that ended.
Expire(n) ==
    /\ keyL[n] # 0 /\ left[n][keyL[n]] = 0
    /\ keyL' = [keyL EXCEPT ![n] = 0]
    /\ KeyChanged(n)
    /\ pendOk' = [pendOk EXCEPT ![n] = FALSE]
    /\ UNCHANGED <<phase, wedged, age, killAge, lost, callLost, myLease, callKind,
                   callSt, callL, callAge, stale, cont, stop, left, status,
                   lostAge, asg, histVars>>

(***************************************************************************)
(* The agent: registration and renewal (agent.zig, heartbeat).             *)
(***************************************************************************)
CanAct(a) == ~wedged[a]

\* lease_grant, then the PUT of /nodes/<node> on that lease.  The grant is
\* taken as immediate; `sent` is read before it, so the lease runs TTL from
\* no earlier than `sent`.  The PUT is the call that can be late or lost.
Register(a) ==
    /\ CanAct(a) /\ phase[a] = "idle" /\ callKind[a] = "none"
    /\ FreeLeases(a) # {}
    /\ LET l == CHOOSE x \in FreeLeases(a) : \A y \in FreeLeases(a) : x <= y IN
        /\ left' = [left EXCEPT ![a][l] = TTL]
        /\ callL' = [callL EXCEPT ![a] = l]
    /\ callKind' = [callKind EXCEPT ![a] = "put"]
    /\ callSt' = [callSt EXCEPT ![a] = "req"]
    /\ callAge' = [callAge EXCEPT ![a] = 0]
    /\ callLost' = [callLost EXCEPT ![a] = 0]
    /\ UNCHANGED <<phase, wedged, age, killAge, lost, myLease, tenureOk,
                   pendOk, stale, cont, stop, keyL, status, statusCur, lostAge, asg,
                   obs, plan, histVars>>

\* The fence is looked at before the heartbeat (reconcile), so no renewal is
\* sent at or after the fence time.
Renew(a) ==
    /\ CanAct(a) /\ phase[a] = "held" /\ callKind[a] = "none"
    /\ age[a] >= RenewAfter /\ age[a] < FenceAt
    /\ callKind' = [callKind EXCEPT ![a] = "ka"]
    /\ callSt' = [callSt EXCEPT ![a] = "req"]
    /\ callL' = [callL EXCEPT ![a] = myLease[a]]
    /\ callAge' = [callAge EXCEPT ![a] = 0]
    /\ callLost' = [callLost EXCEPT ![a] = 0]
    /\ UNCHANGED <<phase, wedged, age, killAge, lost, myLease, tenureOk,
                   pendOk, stale, cont, stop, storeVars, histVars>>

\* The server applies the call in flight.  The registration PUT carries no
\* compare (agent_api.zig, register): it lands whatever the key holds.
Serve(a) ==
    /\ callKind[a] # "none" /\ callSt[a] = "req"
    /\ LET l == callL[a] IN
        IF left[a][l] = 0
        THEN /\ callSt' = [callSt EXCEPT ![a] = "nf"]      \* LeaseNotFound
             /\ UNCHANGED <<left, keyL, tenureOk, statusCur, obs, plan, pendOk>>
        ELSE /\ callSt' = [callSt EXCEPT ![a] = "ok"]
             /\ IF callKind[a] = "put"
                THEN /\ keyL' = [keyL EXCEPT ![a] = l]
                     /\ KeyChanged(a)
                     /\ pendOk' = [pendOk EXCEPT ![a] = TRUE]
                     /\ UNCHANGED left
                ELSE /\ left' = [left EXCEPT ![a][l] = TTL]
                     /\ UNCHANGED <<keyL, tenureOk, statusCur, obs, plan, pendOk>>
    /\ UNCHANGED <<phase, wedged, age, killAge, lost, callLost, myLease, callKind,
                   callL, callAge, stale, cont, stop, status, lostAge, asg, histVars>>

\* The call is over: its variables go back to their idle values.
CallDone(a) ==
    /\ callKind' = [callKind EXCEPT ![a] = "none"]
    /\ callSt' = [callSt EXCEPT ![a] = "req"]
    /\ callL' = [callL EXCEPT ![a] = 0]
    /\ callAge' = [callAge EXCEPT ![a] = 0]
    /\ callLost' = [callLost EXCEPT ![a] = 0]
    /\ pendOk' = [pendOk EXCEPT ![a] = FALSE]

\* The fence begins: TERM now, KILL at nominal + fence_stop_ms.
FenceFrom(a, nominal) ==
    /\ phase' = [phase EXCEPT ![a] = "fencing"]
    /\ killAge' = [killAge EXCEPT ![a] = nominal + StopTime]

Told(a) == zomb' = [zomb EXCEPT ![a] = IF HasCont(a) /\ @ = 0 THEN 1 ELSE @]

\* acknowledged: s becomes the send time of the request just answered.
\* After the PUT of a registration, the same step writes the node's store
\* summary (agent.zig, publish_store: the lease is new to it), and that write
\* compares /nodes/<node> at the tenure the PUT returned.  If the key was
\* written again in between, the write is refused and the fence begins now.
Ack(a) ==
    /\ CanAct(a) /\ callKind[a] # "none" /\ callSt[a] = "ok"
    /\ CallDone(a)
    /\ age' = [age EXCEPT ![a] = callAge[a]]
    /\ lost' = [lost EXCEPT ![a] = callLost[a]]
    /\ IF callKind[a] = "put"
       THEN /\ myLease' = [myLease EXCEPT ![a] = callL[a]]
            /\ tenureOk' = [tenureOk EXCEPT ![a] = pendOk[a]]
            /\ IF pendOk[a] \/ ~CompareTenure
               THEN /\ phase' = [phase EXCEPT ![a] = "held"]
                    /\ bad' = IF pendOk[a] THEN bad ELSE bad \cup {"stale_summary"}
                    /\ UNCHANGED <<killAge, zomb>>
               ELSE /\ Told(a)
                    /\ IF FenceOnConflict
                       THEN FenceFrom(a, callAge[a])
                       ELSE \* tooth: the agent carries on as if it had landed
                            /\ phase' = [phase EXCEPT ![a] = "held"]
                            /\ UNCHANGED killAge
                    /\ UNCHANGED bad
       ELSE UNCHANGED <<phase, myLease, tenureOk, killAge, zomb, bad>>
    /\ UNCHANGED <<wedged, stale, cont, stop, storeVars, healed, jumped, ovl>>

\* LeaseNotFound.  For a keepalive: "the lease has ended, so the server will
\* take the node for lost: stop at once".  For a PUT: the step fails and the
\* next one grants a new lease.
Nack(a) ==
    /\ CanAct(a) /\ callKind[a] # "none" /\ callSt[a] = "nf"
    /\ CallDone(a)
    /\ IF callKind[a] = "ka"
       THEN /\ Told(a)
            /\ IF FenceOnLeaseGone
               THEN /\ FenceFrom(a, age[a] - Min(callAge[a], age[a]))
                    /\ UNCHANGED <<myLease, tenureOk, age, lost>>
               ELSE \* tooth: register again with the containers still running
                    /\ phase' = [phase EXCEPT ![a] = "idle"]
                    /\ myLease' = [myLease EXCEPT ![a] = 0]
                    /\ tenureOk' = [tenureOk EXCEPT ![a] = FALSE]
                    /\ age' = [age EXCEPT ![a] = 0]
                    /\ lost' = [lost EXCEPT ![a] = 0]
                    /\ UNCHANGED killAge
       ELSE UNCHANGED <<phase, killAge, myLease, tenureOk, age, lost, zomb>>
    /\ UNCHANGED <<wedged, stale, cont, stop, storeVars, healed, jumped, ovl, bad>>

\* What becomes of a call the agent no longer waits for: the reply is lost,
\* the request is lost, or the request is still on its way and may be applied
\* later.
Abandon(a) ==
    /\ CallDone(a)
    /\ \/ UNCHANGED stale
       \/ /\ callSt[a] = "req" /\ stale[a].kind = "none" /\ ~healed
          /\ (callKind[a] = "put" /\ StalePut) \/ (callKind[a] = "ka" /\ StaleKa)
          /\ stale' = [stale EXCEPT ![a] = [kind |-> callKind[a], l |-> callL[a]]]

\* The agent gives a call up at its deadline.  A call of an agent that holds
\* a lease is capped at the fence time (agent.zig, calls_deadline_ms); such a
\* call is a keepalive, and the request may still be applied later.  Any
\* other call, the registration PUT among them, runs IoTimeout, and by then
\* the lease the PUT names has ended (TimedOutPutIsDead, below): a PUT that
\* timed out cannot land, so none is left in flight.
CallTimeout(a) ==
    /\ callKind[a] # "none"
    /\ \/ (phase[a] = "held" /\ age[a] >= FenceAt /\ callSt[a] = "req")
       \/ callAge[a] >= IoTimeout
    /\ IF callKind[a] = "ka" THEN Abandon(a)
       ELSE CallDone(a) /\ UNCHANGED stale
    /\ UNCHANGED <<phase, wedged, age, killAge, lost, myLease, tenureOk, cont,
                   stop, storeVars, histVars>>

\* A fault: the agent stops waiting before the deadline, because the
\* connection broke or because the agent process restarted with the call in
\* flight.  The server may already hold the request (one thread per
\* connection, server_http.zig) and apply it later.  This, and a reboot, are
\* the only ways a registration PUT is left in flight behind its agent.
\* lease.json keeps phase, age, lease, tenure and kill time and containers
\* run on, so the restart itself changes nothing else here; README.md says
\* what it leaves out.
CallLost(a) ==
    /\ callKind[a] # "none"
    /\ AllowLoss /\ ~healed /\ a \in Faulty
    /\ Abandon(a)
    /\ UNCHANGED <<phase, wedged, age, killAge, lost, myLease, tenureOk, cont,
                   stop, storeVars, histVars>>

ServeStale(a) ==
    /\ stale[a].kind # "none"
    /\ stale' = [stale EXCEPT ![a] = NoStale]
    /\ LET l == stale[a].l IN
        IF left[a][l] = 0
        THEN UNCHANGED <<left, keyL, tenureOk, statusCur, obs, plan>>
        ELSE IF stale[a].kind = "put"
             THEN /\ keyL' = [keyL EXCEPT ![a] = l]
                  /\ KeyChanged(a)
                  /\ UNCHANGED left
             ELSE /\ left' = [left EXCEPT ![a][l] = TTL]
                  /\ UNCHANGED <<keyL, tenureOk, statusCur, obs, plan>>
    /\ pendOk' = [pendOk EXCEPT ![a] =
                    @ /\ ~(stale[a].kind = "put" /\ left[a][stale[a].l] > 0)]
    /\ UNCHANGED <<phase, wedged, age, killAge, lost, callLost, myLease, callKind,
                   callSt, callL, callAge, cont, stop, status, lostAge, asg, histVars>>

DropStale(a) ==
    /\ stale[a].kind # "none"
    /\ stale' = [stale EXCEPT ![a] = NoStale]
    /\ UNCHANGED <<phase, wedged, age, killAge, lost, callLost, myLease, tenureOk,
                   callKind, callSt, callL, callAge, pendOk, cont, stop, storeVars,
                   histVars>>

(***************************************************************************)
(* The agent: fencing (agent.zig: reconcile, begin_fence, fence_step,      *)
(* fenced).                                                                *)
(***************************************************************************)
\* The lease timer: s + ttl - fence_margin on the agent's clock.
TimerFence(a) ==
    /\ CanAct(a) /\ phase[a] = "held" /\ callKind[a] = "none"
    /\ age[a] >= FenceAt
    /\ FenceFrom(a, FenceAt)
    /\ UNCHANGED <<wedged, age, lost, callLost, myLease, tenureOk, callKind, callSt,
                   callL, callAge, pendOk, stale, cont, stop, storeVars, histVars>>

\* A container ends once the fence has begun: on TERM, or on KILL.  The Tick
\* action is what makes it end by killAge + KillLatency.
ContExit(a, s) ==
    /\ ~wedged[a] /\ phase[a] = "fencing" /\ cont[a][s] # "none"
    /\ cont' = [cont EXCEPT ![a][s] = "none"]
    /\ stop' = [stop EXCEPT ![a][s] = 0]
    /\ UNCHANGED <<phase, wedged, age, killAge, lost, callLost, myLease, tenureOk,
                   callKind, callSt, callL, callAge, pendOk, stale, storeVars,
                   histVars>>

\* fenced: nothing runs; the lease and the tenure are dropped and the next
\* step registers again.
Fenced(a) ==
    /\ CanAct(a) /\ phase[a] = "fencing" /\ ~HasCont(a)
    /\ phase' = [phase EXCEPT ![a] = "idle"]
    /\ myLease' = [myLease EXCEPT ![a] = 0]
    /\ tenureOk' = [tenureOk EXCEPT ![a] = FALSE]
    /\ age' = [age EXCEPT ![a] = 0]
    /\ killAge' = [killAge EXCEPT ![a] = 0]
    /\ zomb' = [zomb EXCEPT ![a] = 0]
    /\ lost' = [lost EXCEPT ![a] = 0]
    /\ UNCHANGED <<wedged, callLost, callKind, callSt, callL, callAge, pendOk,
                   stale, cont, stop, storeVars, healed, jumped, ovl, bad>>

(***************************************************************************)
(* The agent: the pass (agent.zig, Pass).                                  *)
(***************************************************************************)
InPass(a) == /\ CanAct(a) /\ phase[a] = "held" /\ callKind[a] = "none"
             /\ age[a] < FenceAt + StepMax

Start(a, s) ==
    /\ InPass(a) /\ <<s, a>> \in asg /\ cont[a][s] = "none"
    /\ cont' = [cont EXCEPT ![a][s] = "run"]
    /\ UNCHANGED <<stop, phase, wedged, age, killAge, lost, callLost, myLease, tenureOk,
                   callKind, callSt, callL, callAge, pendOk, stale, storeVars,
                   histVars>>

\* A container whose replica the node is no longer assigned is stopped
\* (agent.zig: orphan_containers, stop_listing): TERM in the pass that sees
\* it, KILL by a later pass once stop_grace_ms has gone by.  This is not a
\* fence: the grace is stop_grace_ms, not fence_stop_ms.
StopTerm(a, s) ==
    /\ InPass(a) /\ Stray(a, s) /\ stop[a][s] = 0
    /\ stop' = [stop EXCEPT ![a][s] = 1]
    /\ UNCHANGED <<phase, wedged, age, killAge, lost, callLost, myLease, tenureOk,
                   callKind, callSt, callL, callAge, pendOk, stale, cont, storeVars,
                   histVars>>

\* The container ends: on the TERM, at any time after it, or on the KILL.
\* Urgent is what makes it end by StopGrace + KillLatency.
StrayExit(a, s) ==
    /\ ~wedged[a] /\ stop[a][s] > 0 /\ cont[a][s] # "none"
    /\ cont' = [cont EXCEPT ![a][s] = "none"]
    /\ stop' = [stop EXCEPT ![a][s] = 0]
    /\ UNCHANGED <<phase, wedged, age, killAge, lost, callLost, myLease, tenureOk,
                   callKind, callSt, callL, callAge, pendOk, stale, storeVars,
                   histVars>>

\* An observed write: made when a container's state changed, never otherwise.
\* It compares /nodes/<node> at the agent's tenure (Pass.new_batch, I2); a
\* conflict begins the fence at once (Pass.commit).  The pass that starts a
\* container makes the write in the same step, so it is made even if the
\* replica was replaced in between ("oldrun").
Reported(c) == IF c = "run" THEN "rep" ELSE "old"
Report(a, s) ==
    /\ InPass(a) /\ cont[a][s] \in {"run", "oldrun"}
    /\ IF tenureOk[a] \/ ~CompareTenure
       THEN /\ obs' = [obs EXCEPT ![a][s] =
                         [ten |-> tenureOk[a],
                          asg |-> cont[a][s] = "run" /\ <<s, a>> \in asg]]
            /\ cont' = [cont EXCEPT ![a][s] = Reported(@)]
            /\ bad' = IF tenureOk[a] THEN bad ELSE bad \cup {"stale_observation"}
            /\ UNCHANGED <<phase, killAge, zomb>>
       ELSE /\ Told(a)
            /\ IF FenceOnConflict
               THEN FenceFrom(a, age[a]) /\ UNCHANGED cont
               ELSE \* tooth: the agent carries on as if the write had landed
                    /\ cont' = [cont EXCEPT ![a][s] = Reported(@)]
                    /\ UNCHANGED <<phase, killAge>>
            /\ UNCHANGED <<obs, bad>>
    /\ UNCHANGED <<wedged, age, lost, callLost, myLease, tenureOk, callKind, callSt,
                   callL, callAge, pendOk, stale, stop, left, keyL, status,
                   statusCur, lostAge, asg, plan, healed, jumped, ovl>>

\* The record of a replica that is gone from the node is deleted once its
\* container has stopped (agent.zig, orphan_records).  The delete is an
\* observed write like any other: compared, and a conflict fences.
ForgetDue(a, s) == obs[a][s] # None /\ cont[a][s] = "none" /\ <<s, a>> \notin asg
Forget(a, s) ==
    /\ InPass(a) /\ ForgetDue(a, s)
    /\ IF tenureOk[a] \/ ~CompareTenure
       THEN /\ obs' = [obs EXCEPT ![a][s] = None]
            /\ bad' = IF tenureOk[a] THEN bad ELSE bad \cup {"stale_observation"}
            /\ UNCHANGED <<phase, killAge, zomb>>
       ELSE /\ Told(a)
            /\ IF FenceOnConflict THEN FenceFrom(a, age[a])
               ELSE UNCHANGED <<phase, killAge>>
            /\ UNCHANGED <<obs, bad>>
    /\ UNCHANGED <<wedged, age, lost, callLost, myLease, tenureOk, callKind, callSt,
                   callL, callAge, pendOk, stale, cont, stop, left, keyL, status,
                   statusCur, lostAge, asg, plan, healed, jumped, ovl>>

(***************************************************************************)
(* Agent faults.                                                           *)
(***************************************************************************)
\* A restart of the agent process is CallLost, above, for the call it had
\* in flight, and time, which is the agent not acting.  An outage that lets
\* a deadline pass is a wedge (Urgent, below).

\* The machine restarts: containers are gone, the boot id differs, the kept
\* lease is not trusted and nothing is left to fence.
Reboot(a) ==
    /\ AllowReboot /\ ~healed /\ ~wedged[a] /\ a \in Faulty
    /\ phase[a] # "idle" \/ callKind[a] # "none"
    /\ phase' = [phase EXCEPT ![a] = "idle"]
    /\ myLease' = [myLease EXCEPT ![a] = 0]
    /\ tenureOk' = [tenureOk EXCEPT ![a] = FALSE]
    /\ age' = [age EXCEPT ![a] = 0]
    /\ lost' = [lost EXCEPT ![a] = 0]
    /\ killAge' = [killAge EXCEPT ![a] = 0]
    /\ cont' = [cont EXCEPT ![a] = [s \in Slots |-> "none"]]
    /\ stop' = [stop EXCEPT ![a] = [s \in Slots |-> 0]]
    /\ zomb' = [zomb EXCEPT ![a] = 0]
    /\ IF callKind[a] # "none" THEN Abandon(a)
       ELSE UNCHANGED <<callKind, callSt, callL, callAge, callLost, pendOk, stale>>
    /\ UNCHANGED <<wedged, storeVars, healed, jumped, ovl, bad>>

Wedge(a) ==
    /\ AllowWedge /\ ~healed /\ ~wedged[a] /\ a \in Faulty
    /\ wedged' = [wedged EXCEPT ![a] = TRUE]
    /\ UNCHANGED <<phase, age, killAge, lost, callLost, myLease, tenureOk, callKind,
                   callSt, callL, callAge, pendOk, stale, cont, stop, storeVars, histVars>>

(***************************************************************************)
(* The server: node controller, replica controller, scheduler.  A          *)
(* controller whose transaction compares everything it read is one atomic  *)
(* action: a stale read would only make the transaction fail.  The         *)
(* scheduler is two actions, so that its compares can be taken away.       *)
(***************************************************************************)
MarkReady(n) ==
    /\ keyL[n] # 0 /\ ~(status[n] = "ready" /\ statusCur[n])
    /\ status' = [status EXCEPT ![n] = "ready"]
    /\ statusCur' = [statusCur EXCEPT ![n] = TRUE]
    /\ lostAge' = [lostAge EXCEPT ![n] = 0]
    /\ StatusChanged(n)
    /\ UNCHANGED <<agentVars, left, keyL, asg, obs, histVars>>

MarkLost(n) ==
    /\ keyL[n] = 0 /\ status[n] = "ready"
    /\ status' = [status EXCEPT ![n] = "lost"]
    /\ lostAge' = [lostAge EXCEPT ![n] = 0]
    /\ StatusChanged(n)
    /\ UNCHANGED <<agentVars, left, keyL, statusCur, asg, obs, histVars>>

\* remove_lost: the replica on a lost node is given up and a new replica id
\* takes the slot.  Compares the replica, the assignment, the node's status
\* and its (absent) registration.
Replace(s, n) ==
    /\ <<s, n>> \in asg
    /\ status[n] = "lost" /\ keyL[n] = 0
    /\ UseLostGrace => lostAge[n] >= LostGrace
    /\ asg' = asg \ {<<s, n>>}
    /\ obs' = [a \in Agents |->
                 [obs[a] EXCEPT ![s] = IF @ = None THEN None ELSE [@ EXCEPT !.asg = FALSE]]]
    /\ cont' = [a \in Agents |->
                  [cont[a] EXCEPT ![s] = IF @ = "none" THEN "none"
                                         ELSE IF @ \in {"run", "oldrun"} THEN "oldrun"
                                         ELSE "old"]]
    /\ plan' = [k \in Scheds |->
                  IF plan[k] # None /\ plan[k].s = s
                  THEN [plan[k] EXCEPT !.freeOk = FALSE] ELSE plan[k]]
    /\ UNCHANGED <<phase, wedged, age, killAge, lost, callLost, myLease, tenureOk,
                   callKind, callSt, callL, callAge, pendOk, stale, stop, left, keyL,
                   status, statusCur, lostAge, histVars>>

Plan(k, s, n) ==
    /\ plan[k] = None /\ Free(s) /\ NodeReady(n)
    /\ plan' = [plan EXCEPT ![k] = [s |-> s, n |-> n, nodeOk |-> TRUE,
                                    readyOk |-> TRUE, freeOk |-> TRUE]]
    /\ UNCHANGED <<agentVars, left, keyL, status, statusCur, lostAge, asg, obs,
                   histVars>>

\* The placement compare set (authority.md section 2).  A failed compare
\* drops the plan.
Commit(k) ==
    /\ plan[k] # None
    /\ LET p == plan[k]
           pass == /\ CompareReady => (p.nodeOk /\ p.readyOk)
                   /\ CompareAbsent => p.freeOk
       IN IF pass
          THEN /\ asg' = asg \cup {<<p.s, p.n>>}
               /\ plan' = [j \in Scheds |->
                             IF j = k THEN None
                             ELSE IF plan[j] # None /\ plan[j].s = p.s
                                  THEN [plan[j] EXCEPT !.freeOk = FALSE]
                                  ELSE plan[j]]
               /\ bad' = bad
                    \cup (IF NodeReady(p.n) THEN {} ELSE {"placed_not_ready"})
                    \cup (IF p.nodeOk /\ p.readyOk /\ p.freeOk THEN {}
                          ELSE {"stale_placement"})
          ELSE /\ plan' = [plan EXCEPT ![k] = None]
               /\ UNCHANGED <<asg, bad>>
    /\ UNCHANGED <<agentVars, left, keyL, status, statusCur, lostAge, obs, healed,
                   jumped, ovl, zomb>>

\* A controller acts on a node's record (counts the replica as running).  It
\* may only if the observation is admissible (replica_controller.zig,
\* admissible).  Only the forbidden case changes the state.
Decide(n, s) ==
    /\ ~CheckAdmissible /\ obs[n][s] # None /\ ~Admissible(n, s)
    /\ "inadmissible_cited" \notin bad
    /\ bad' = bad \cup {"inadmissible_cited"}
    /\ UNCHANGED <<agentVars, storeVars, healed, jumped, ovl, zomb>>

(***************************************************************************)
(* Environment.                                                            *)
(***************************************************************************)
\* The store's lease clock steps forward, or the store fails over to a copy
\* in which leases have less time left: every lease loses Setback ticks.
StoreSetback ==
    /\ Setback > 0 /\ ~jumped /\ ~healed
    /\ jumped' = TRUE
    /\ left' = [n \in Agents |-> [l \in Leases |->
                  IF left[n][l] > Setback THEN left[n][l] - Setback ELSE 0]]
    /\ UNCHANGED <<agentVars, keyL, status, statusCur, lostAge, asg, obs, plan,
                   healed, ovl, zomb, bad>>

Heal ==
    /\ AllowHeal /\ ~healed
    /\ healed' = TRUE
    /\ UNCHANGED <<agentVars, storeVars, jumped, ovl, zomb, bad>>

(***************************************************************************)
(* Time.  A tick may not pass while an agent that is not wedged has        *)
(* something it does by a deadline still to do; this is what "the agent    *)
(* process is alive and scheduled" (authority.md section 3) means here.    *)
(***************************************************************************)
\* The pass starts what is assigned and reports it in the same step
\* (agent.zig, Pass: start puts the observed record, flush commits it).
PassDue(a) ==
    /\ phase[a] = "held" /\ callKind[a] = "none" /\ age[a] < FenceAt + StepMax
    /\ \E s \in Slots : \/ (<<s, a>> \in asg /\ cont[a][s] = "none")
                        \/ cont[a][s] \in {"run", "oldrun"}
                        \/ (Stray(a, s) /\ stop[a][s] = 0)
                        \/ (ForgetDue(a, s)
                            /\ (tenureOk[a] \/ FenceOnConflict \/ ~CompareTenure))
\* The pass that sends KILL to a container it sent TERM is due, or the KILL
\* has had its time.  A keepalive that hangs holds the pass up (heartbeat
\* comes first in reconcile), until the fence takes over.
StopDue(a) ==
    /\ phase[a] = "held" /\ callKind[a] = "none"
    /\ \E s \in Slots : stop[a][s] > StopGrace + KillLatency + StepMax

Urgent(a) ==
    /\ ~wedged[a]
    /\ \/ (phase[a] = "held" /\ age[a] >= FenceAt + StepMax)      \* fence
       \/ (phase[a] = "fencing" /\ HasCont(a)                      \* kill done
           /\ age[a] >= killAge[a] + KillLatency + StepMax)
       \/ (phase[a] = "held" /\ callKind[a] = "none"               \* renew
           /\ age[a] >= RenewAfter + StepMax)
       \/ PassDue(a)                                              \* the pass
       \/ StopDue(a)
       \/ ((healed \/ a \notin Faulty) /\ callKind[a] # "none"       \* reply
           /\ callAge[a] >= HealedDelay)
       \/ (callKind[a] # "none" /\ callAge[a] >= IoTimeout)        \* timeout

\* skip: the one agent, if any, whose clock loses this tick.
NodeCtlDue(n) == \/ (keyL[n] # 0 /\ ~(status[n] = "ready" /\ statusCur[n]))
                 \/ (keyL[n] = 0 /\ status[n] = "ready")

Tick(skip) ==
    /\ \A a \in Agents : ~Urgent(a)
    /\ NodeCtlPrompt => \A n \in Agents : ~NodeCtlDue(n)
    /\ skip # None =>
          /\ ~wedged[skip] /\ skip \in Faulty
          /\ \/ (phase[skip] # "idle" /\ lost[skip] < SkewActual
                 /\ (callKind[skip] # "none" => callLost[skip] < SkewActual))
             \/ (phase[skip] = "idle" /\ callKind[skip] # "none"
                 /\ callLost[skip] < SkewActual)
    /\ lost' = [a \in Agents |->
                  IF a = skip /\ phase[a] # "idle" THEN lost[a] + 1 ELSE lost[a]]
    /\ callLost' = [a \in Agents |->
                      IF a = skip /\ callKind[a] # "none" THEN callLost[a] + 1
                      ELSE callLost[a]]
    /\ age' = [a \in Agents |->
                 IF phase[a] # "idle" /\ a # skip /\ ~wedged[a]
                 THEN Min(age[a] + 1, AgeCap) ELSE age[a]]
    /\ callAge' = [a \in Agents |->
                     IF callKind[a] # "none" /\ a # skip /\ ~wedged[a]
                     THEN Min(callAge[a] + 1, AgeCap) ELSE callAge[a]]
    /\ left' = [n \in Agents |-> [l \in Leases |->
                  IF Referenced(n, l) /\ left[n][l] > 0
                  THEN left[n][l] - 1 ELSE 0]]
    /\ lostAge' = [n \in Agents |->
                     IF status[n] = "lost" THEN Min(lostAge[n] + 1, LostGrace)
                     ELSE 0]
    /\ stop' = [a \in Agents |-> [s \in Slots |->
                  IF stop[a][s] > 0 /\ a # skip /\ ~wedged[a]
                  THEN Min(stop[a][s] + 1, StopCap) ELSE stop[a][s]]]
    /\ ovl' = [s \in Slots |->
                 IF Cardinality({a \in Agents : cont[a][s] # "none"}) >= 2
                 THEN Min(ovl[s] + 1, OvlCap) ELSE 0]
    /\ zomb' = [a \in Agents |->
                  IF zomb[a] > 0 /\ HasCont(a) THEN Min(zomb[a] + 1, ZombCap)
                  ELSE zomb[a]]
    /\ UNCHANGED <<phase, wedged, killAge, myLease, tenureOk, callKind, callSt,
                   callL, pendOk, stale, cont, keyL, status, statusCur, asg, obs,
                   plan, healed, jumped, bad>>

AgentStep(a) ==
    \/ Register(a) \/ Renew(a) \/ Ack(a) \/ Nack(a) \/ TimerFence(a) \/ Fenced(a)
    \/ \E s \in Slots : \/ Start(a, s) \/ Report(a, s) \/ Forget(a, s)
                        \/ StopTerm(a, s) \/ StrayExit(a, s) \/ ContExit(a, s)
NetStep(a) == Serve(a) \/ ServeStale(a) \/ DropStale(a)
ServerStep ==
    \/ \E n \in Agents : Expire(n) \/ MarkReady(n) \/ MarkLost(n)
    \/ \E s \in Slots, n \in Agents : Replace(s, n)
    \/ \E k \in Scheds, s \in Slots, n \in Agents : Plan(k, s, n)
    \/ \E k \in Scheds : Commit(k)
Fault ==
    \/ \E a \in Agents : CallLost(a) \/ Reboot(a) \/ Wedge(a)
    \/ \E n \in Agents, s \in Slots : Decide(n, s)
    \/ StoreSetback
    \/ Heal

Next ==
    \/ \E a \in Agents : AgentStep(a) \/ CallTimeout(a) \/ NetStep(a)
    \/ ServerStep
    \/ Fault
    \/ \E skip \in Agents \cup {None} : Tick(skip)

Spec == Init /\ [][Next]_vars

\* Everything the protocol does itself happens eventually; faults need not.
Fairness ==
    /\ WF_vars(\E skip \in Agents \cup {None} : Tick(skip))
    /\ \A a \in Agents :
          /\ WF_vars(AgentStep(a))
          /\ WF_vars(NetStep(a))
          /\ WF_vars(CallTimeout(a))
    /\ \A n \in Agents : WF_vars(Expire(n)) /\ WF_vars(MarkReady(n)) /\ WF_vars(MarkLost(n))
    /\ WF_vars(\E s \in Slots, n \in Agents : Replace(s, n))
    /\ \A k \in Scheds : WF_vars(\E s \in Slots, n \in Agents : Plan(k, s, n))
                         /\ WF_vars(Commit(k))
LiveSpec == Spec /\ Fairness

(***************************************************************************)
(* Properties.  The I-numbers are those of authority.md section 4.         *)
(***************************************************************************)
TypeOK ==
    /\ phase \in [Agents -> {"idle", "held", "fencing"}]
    /\ wedged \in [Agents -> BOOLEAN]
    /\ age \in [Agents -> 0..AgeCap] /\ callAge \in [Agents -> 0..AgeCap]
    /\ lost \in [Agents -> 0..SkewActual] /\ callLost \in [Agents -> 0..SkewActual]
    /\ killAge \in [Agents -> 0..(AgeCap + StopTime)]
    /\ myLease \in [Agents -> 0..NL] /\ keyL \in [Agents -> 0..NL]
    /\ callKind \in [Agents -> {"none", "put", "ka"}]
    /\ callSt \in [Agents -> {"req", "ok", "nf"}]
    /\ cont \in [Agents -> [Slots -> {"none", "run", "rep", "old", "oldrun"}]]
    /\ stop \in [Agents -> [Slots -> 0..StopCap]]
    /\ \A a \in Agents, s \in Slots : stop[a][s] > 0 => cont[a][s] # "none"
    /\ left \in [Agents -> [Leases -> 0..TTL]]
    /\ status \in [Agents -> {"none", "ready", "lost"}]
    /\ asg \subseteq (Slots \X Agents)

\* The store model never runs out of lease slots (a check of the model).
LeaseSlotsSuffice ==
    \A a \in Agents : (phase[a] = "idle" /\ callKind[a] = "none") => FreeLeases(a) # {}

\* Why a registration PUT that timed out cannot land: when the agent gives a
\* registration PUT up at IoTimeout, the lease the PUT names has ended, so
\* the store would refuse it (store_postgres.zig, check_leases).
TimedOutPutIsDead ==
    \A a \in Agents : (callKind[a] = "put" /\ callAge[a] >= IoTimeout)
                          => left[a][callL[a]] = 0

\* I1a. Each replica id has at most one assignment, and at most one tenure
\* under which an observation of it is admissible.  Every node keeps its own
\* record of a slot, so this is over all of them: at most one node's record
\* is admissible, and it is the record of the node the slot is assigned to,
\* under a registration that exists.
I1a_OneAssignment ==
    \A s \in Slots : Cardinality({n \in Agents : <<s, n>> \in asg}) <= 1
I1a_OneAdmissibleTenure ==
    \A s \in Slots :
        /\ Cardinality({n \in Agents : Admissible(n, s)}) <= 1
        /\ \A n \in Agents : Admissible(n, s) => (<<s, n>> \in asg /\ keyL[n] # 0)

\* I1b, as the arithmetic of section 3 gives it: the agent has finished
\* stopping before any replacement is placed, so a slot's work never runs on
\* two nodes at once.
I1b_NoOverlap ==
    \A s \in Slots : Cardinality({a \in Agents : cont[a][s] # "none"}) <= 1
\* I1b, as section 4 states it: not for longer than lost_grace_ms plus kill
\* latency.
I1b_Window == \A s \in Slots : ovl[s] <= LostGrace + KillLatency
\* Not a property: a probe.  Its counterexample is a run in which the pass
\* stops a container whose replica was replaced, and the container and its
\* replacement both run for the whole of stop_grace_ms plus the kill latency.
StrayOverlapShorterThanStopGrace ==
    \A a \in Agents, s \in Slots :
        ~(/\ phase[a] = "held" /\ stop[a][s] > StopGrace + KillLatency
          /\ ovl[s] >= StopGrace + KillLatency)

\* I2. No transaction commits whose tenure or placement epoch was superseded.
I2_NoStaleCommit ==
    bad \cap {"stale_observation", "stale_summary", "stale_placement"} = {}
\* I3. No decision cites an inadmissible observation.
I3_NoInadmissibleCause == "inadmissible_cited" \notin bad
\* I7. No placement onto a node that is not ready.
I7_PlacedOnReady == "placed_not_ready" \notin bad

\* The inequality of section 3, seen from the store: when an agent's lease
\* ends, its containers are gone or go at that instant (Urgent: no tick
\* passes first).
DeadBeforeExpiry ==
    \A a \in Agents :
        (HasCont(a) /\ ~wedged[a] /\ myLease[a] # 0 /\ left[a][myLease[a]] = 0)
            => Urgent(a)

\* Decision 2026-11-08: an agent told that its tenure ended has stopped
\* everything within the fence's own time, not at its next lease timer.
TenureEndFencesAtOnce ==
    \A a \in Agents : zomb[a] <= StopTime + KillLatency + StepMax + SkewActual + 1

\* Liveness (authority.md section 3, "fencing settles"; core.md, a healed
\* node gets work back).
Stable == \A a \in Agents :
            phase[a] = "held" /\ tenureOk[a] /\ NodeReady(a)
Working == \A s \in Slots : \E a \in Agents :
            <<s, a>> \in asg /\ cont[a][s] \in {"run", "rep"}
FencingSettles == (<>healed) => <>[]Stable
WorkComesBack == (<>healed) => <>[]Working

\* For configs in which every agent is in Faulty, or none is.
Symm == Permutations(Agents) \cup Permutations(Slots) \cup Permutations(Scheds)
\* For the others.
SymmNoAgents == Permutations(Slots) \cup Permutations(Scheds)
=============================================================================
