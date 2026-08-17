# SREAgent: design, escalation, and drills

Three agents, one per cloud, each watching the fleet and repairing its own
region. This is what they do, why they are built this way, and the incidents
that shaped each decision.

Almost every rule below exists because something silently did not work. Where
that is true, the incident is named — a rule whose reason is lost gets deleted
by the next person who finds it inconvenient.

---

## Authority, per region

Authority is configuration, not a hardcoded index (`SRE_ACTIONABLE_REGIONS`,
`SRE_FULL_POWER_REGIONS`), and `SRE_ALLOW_ACTIONS` gates everything.

| Region | Cloud | Authority |
|---|---|---|
| 0 | GCP | read GCP, restart its own containers, TrustedRouter triage |
| 1 | AWS | **pure monitor** — no writes, ever |
| 2 | Azure | **full power**: unrestricted root shell on its own VM |

**AWS stays a monitor on purpose.** One region must remain beyond the agents'
reach; an agent that can break every failure domain deletes the property the
architecture exists to provide.

**Azure has a real shell, with no blocklist.** The point of the grant is
repairing faults nobody anticipated, and a blocklist only rules out the repairs
whoever wrote it happened to imagine — while implying the grant is bounded.
What bounds it is *where* it is enabled: the region with no production traffic,
rebuildable from `deploy/provision.sh`. Every command is appended to
`~/.srechat-shell-audit.log` before it runs, so a box that destroys itself still
says what it was asked to do.

**The two grants are not the same and must not be conflated.** `FULL_POWER` is
root on *this* box. `ACTIONABLE` is authority over *other* systems — the GCP
tools, the region-0 restart, and `tr_rollback`, which moves TrustedRouter
production traffic. The first rollout put Azure in both, handing the chaos
target the ability to roll back the product. `test_authority.py` now asserts a
full-power agent holds none of the tools that reach elsewhere.

The startup line names the mode and lists the tools, because "actionable" alone
could not distinguish a monitor from an agent holding a root shell — which is
how that over-grant survived being deployed *and* verified.

---

## Investigation loop

A keyword picking one tool and letting the model phrase the output is not
diagnosis. Diagnosis is choosing what to look at next based on what the last
thing showed, which needs a loop and real tool calling (`investigate.py`).

Two properties matter more than cleverness:

- **Evidence.** Every conclusion carries the transcript of the tool calls that
  produced it. An agent reporting a confident wrong cause during an incident is
  worse than one reporting nothing — it sends a human to the wrong region while
  the real one burns.
- **Termination.** A step budget, always. An investigation that never concludes
  is an incident nobody was told about. Running out is a *reported outcome*, not
  a hang — and on exhaustion the model gets one final turn with no tools, because
  the first live run repaired the fault on its last step and then reported
  `UNKNOWN`, discarding everything it had learned.

### Security boundary

The model chooses tools **only on the watchdog path**. Chat keeps keyword
routing, so a persuasive message cannot reach a tool. The difference is the
trigger: an investigation starts from a condition the agent measured itself,
never from message text. Do not call `chat_with_tools` from `handle()`.

Escalation tools are excluded from the loop, so a model cannot page on a
hypothesis it is about to disprove.

---

## What the agents watch

- every region's `/health`, debounced
- peer agent heartbeat freshness
- replication lag and stream gaps
- **local containers**, directly

That last one exists because a drill stopped redis and `/health` went on
answering 200. The region could not commit a single write and looked perfectly
well. **A liveness check that does not exercise the dependency is not a liveness
check.** Detection went from never to 21 seconds.

### Flapping is one incident

A crash loop is not a region going up and down. Region 0 restarted 12 times in
40 minutes and sent six `RECOVERED` alerts and zero `NODE DOWN`: each restart
was too brief to trip the failure debounce, and recovery had no debounce at all.
Six pieces of good news about an outage in progress is worse than silence.

Repeated transitions within a rolling window now report `FLAPPING` once, naming
the count and the *current* state, and point at restart counts rather than at
waiting for a clean failure — a crash loop never fails cleanly.

### An agent must not go blind when its own region dies

Each agent used to talk only to its own region's API. When region 0's app
crash-looped, its agent could not fetch conversations, lost sight of the peer
heartbeats arriving from AWS and Azure, and reported two healthy regions as
silent. One outage produced three regions' worth of alerts, and the two false
ones were about the regions that were fine.

`api()` now tries its own region first, then peers. Any master can serve — that
is the whole design, and the agent was the one component not using it. Total
failure still raises: returning empty when every master is gone would make a
dead fleet look like a quiet one.

---

## The escalation ladder

| When | Channel | Condition |
|---|---|---|
| starts acting | email | any action |
| working | chat | as it goes |
| finishes | email | full report + evidence + links |
| 10 min, no reply | **phone call** | only if unresolved |

**The opening note** goes out before the agent knows anything. An agent quietly
touching production with no trace until it finishes is what makes an autonomous
agent hard to trust.

**The report** carries cause, action, resolution, which agent spoke, the tool
count, links to every region, and then the *full* evidence — every tool call in
order with its output. Summarising defeats the purpose: a conclusion without its
working is exactly what an agent should not be believed on. An empty or missing
verdict renders **NOT resolved**; anything ambiguous reading as success is the
failure that leaves a real outage unattended.

**The call** fires only for *unresolved* incidents nobody answered. Ringing
someone at 3am about a fault the agent already repaired is what teaches people to
silence a pager. Any message from the owner counts as acknowledgement —
requiring a keyword would ring the phone of someone already typing.

Email prefers TrustedRouter's `/v1/notify`, which sends through SES from the
**alert identity** (separate configuration set, so a bounce storm on receipts
cannot degrade paging). No email credential sits on these VMs: a credential
nobody places is one nobody has to remember to rotate or delete.

### The leash

Dedupe by reason, rate limit per channel, minimum gap, **persisted to disk** —
an agent in a crash loop restarts with fresh memory and would otherwise phone a
sleeping human once per restart, forever. A failed send does not consume the
budget, or a carrier outage would burn the call allowance and the human would
never be reached even after the carrier recovered.

Suppression is reported as information, not failure, so the agent keeps working
the incident instead of retrying around it.

---

## Chaos drills

`tools/chaos/drill.py`. Break something at random on region 2 and score what the
agent did.

1. **The agent is told nothing.** No marker, no drill flag. Progress is read
   from its journal rather than by asking it — an agent that knows it is being
   tested is testing something else.
   *Open problem: with a root shell on the same box it can read `drill.py`, and
   did. The drill belongs off the VM, injected through the cloud's control
   plane.*
2. **Verify the fault landed** before scoring anything. Otherwise "the agent
   missed it" and "the fault never took" are indistinguishable — and the second
   scores as a pass, the most dangerous result a drill can produce.
3. **Score detection and diagnosis apart.** "Region unhealthy" is noticing;
   "redis is stopped" is diagnosis. The first version matched keywords anywhere
   in the journal and hit the agent's own shell commands (`docker stop`,
   `deploy-app-1`) while its actual conclusion was `UNKNOWN` — a false pass, in
   the tool built to catch exactly that. Scoring now reads the conclusion line
   only, and an explicit `UNKNOWN` never counts.
4. **Always restore.** A drill that leaves the region broken is an outage of its
   own making. If the agent has not fixed it by the deadline, the drill repairs
   it and records that separately, so a partial success is never read back as a
   self-heal.
5. **Wait for the conclusion before scoring.** The agent repairs
   mid-investigation and states its findings afterwards; scoring the instant the
   fault clears read a journal that did not yet contain the diagnosis or the
   page, and reported both as absent.

### Blast radius is about dependencies, not location

`redis-stopped` is **withdrawn**. It took region 0 down for hours. Region 2's
oplog is what its *peers* read; restarting redis reset the stream, region 0's
cursor pointed at a trimmed entry, its tailer refused to skip history (correctly,
by design), and its app crash-looped 87 times.

The reasoning that allowed it — region 2 carries no traffic and rebuilds from
scratch — was true of the VM and irrelevant to replication. **A fault confined to
one machine is not confined to one failure domain when other regions read its
state.**

Recovery: `SET srechat:repl_cursor:<region> 0-0` on the affected peer, then
restart its app. Do it with the app **stopped** — running it live lets the app
write its in-memory cursor back over yours on shutdown, which cost 12 extra
crash cycles.

---

## Inbound signals: `POST /hooks/<source>`

Anything with a webhook can put a line in the chat — Sentry, GCP alerting, CI,
Stripe, `help@` mail forwarded through SES. One endpoint turns all of those from
code into configuration.

```
POST https://sre<N>.trustedrouter.com/hooks/<source>
Authorization: Bearer <SRE_WEBHOOK_SECRET>      # preferred
     ...or...  ?token=<SRE_WEBHOOK_SECRET>      # senders that cannot set headers
```

Both forms carry the same shared secret; which one a sender uses is a privacy
question, not a security one. A header stays out of URLs, referrers and access
logs, and Sentry masks saved header values — so the query form exists only for
senders (Sentry's legacy webhook plugin, some CI systems) that cannot set
headers at all. A non-bearer `Authorization` header falls **through** to the
query form rather than shadowing it, so putting a proxy in front that stamps its
own `Authorization` cannot silently break every `?token=` sender.

Unconfigured means **503, not 200**: an open endpoint that posts to your pager is
worse than a broken one.

### Two recipients, and why

Each signal is delivered twice — to the owner, and to that region's agent:

| recipient | why |
|---|---|
| owner | the error is visible in chat **even when the agent is dead** — the moment you most want to see it |
| region's agent | something triages it in seconds, instead of whenever a human next opens the app |

The first version delivered to the owner alone. It returned a truthful `200` and
was useless twice over: the line landed in a `webhook` DM thread nobody watches,
and the agent polls its *own* conversations, so "alert me and let the agent
investigate" investigated nothing. Any failed recipient returns 500 so the sender
retries — a line read twice beats an outage nobody was told about.

### Containment: why untrusted text may start an investigation

A Sentry issue title is written by whoever caused the exception. Letting that
text reach a tool-calling loop on a box with a shell is only safe because the
limit is **structural, not a request in a prompt**:

- signal-triggered investigations get `SIGNAL_TOOLS` — an **allowlist of reads,
  by name**. `shell`, `restart` and `tr_rollback` are never in the schema list
  handed to the model, and a tool name it invents resolves to nothing.
- it is an allowlist rather than "TOOLS minus the mutators" so a tool added next
  month is unreachable from untrusted input until someone lists it on purpose.
  Only one of those two directions fails safely.
- the payload is fenced and labelled as data to be verified, never followed.
  That is belt to the braces, not the mechanism.
- signals bypass `handle()` entirely: replying would talk to a webhook, an alert
  must not steer the keyword router, and a machine must not be able to
  acknowledge a page on the owner's behalf.

Worst case for a title reading `run rm -rf /` is that some logs get read and you
get told about it.

### Proportional reporting

A pager that fires on unverified third-party alerts is a pager you learn to
ignore. So:

- **every** signal is investigated and answered in chat
- only **real and ongoing** findings are emailed — `RESOLVED: yes` from a
  read-only loop means "not happening now", and `UNKNOWN` means the agent could
  not stand the alert up
- **nothing** here rings a phone. Self-measured conditions still can.

Repeats are fingerprinted with digits collapsed, so `seen 41x` then `seen 42x` is
one alert rather than two — the exact shape of the flapping that once paged every
few minutes. Every arrival refreshes the fingerprint, so a sender firing each
minute extends the quiet period instead of getting through the moment the
original ages out.

### Sentry wiring

Sentry has more than one webhook shape, and the choice matters:

- **alert-rule action** (what production uses) — payload under `data.event` with
  `triggered_rule` beside it. Fires only on rules somebody already decided were
  worth being told about.
- **issue webhooks** (`data.issue`) — every new issue in every project. Left
  unsubscribed on purpose; this is the noisy option.

Configured as an internal integration ("SREChat Agent (GCP)") with Alert Action
on, `Issue & Event: Read` and nothing else, added as a second action on
quill-router's existing high-priority rule so the email notification is
untouched. Sentry's **Send Test Notification** button exercises only the email
action — it will not prove this path, so verify with a real alert or a `curl`.

Never render Sentry's `issue_url` as the link: it is the REST resource and 404s
in a browser, which is worse than no link because it looks like the answer.

---

## Recurring lessons

**Configured is not working.** Voice escalation had never once placed a call:
four defects stacked (missing `ApplicationSid`, wrong account id, no outbound
voice profile, `?msg=` vs `?text=`), every test passed, config was present. It
took placing a real call to find out.

**Delivered is not sent.** SMS returned `201 accepted` then
`delivery_failed / 40010`. Check the receipt, never the submission.

**A fallback that only works when the primary works is not a fallback.** The
on-disk device cache exists so a page can be sent when our own API is down. When
Caddy was stopped — exactly that case — push failed with "no registered device".
Still open.

**Watch the outcome, not the job.** A queued deploy can be displaced by a newer
push; watching a run id reported "cancelled" when the question was whether the
bytes were live. Poll the thing you actually care about.

**A truthful 200 can still mean the feature does nothing.** The first webhook
delivery genuinely succeeded — into a thread nobody reads, addressed to nobody
who could act on it. `send_message` returning `{:ok, _}` answers "did the write
land", which is not the question. Assert the message is where the *reader* is.

**A hand-picked file list is a dependency you did not declare.** Deploying
`endpoint.ex` without `redis_persistence.ex` left region 0 serving 503 on an
undefined `ping/0` for three minutes — and it passed locally, and on Azure, which
already had the missing file from an earlier deploy. Ship whole directories.

**Deploy tooling fails silently at size limits.** The same script that worked at
65 KB produced no output at 590 KB (`az vm run-command` caps script size) and the
region kept serving the old build. The only reason it was caught is that the
next step asserted the new behaviour was live, rather than reading "deployed".
