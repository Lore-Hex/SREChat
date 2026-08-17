# Lessons

Every entry here is a defect that shipped, or nearly shipped, on this system. They
are grouped by the shape of the mistake rather than the subsystem, because the
shape is what repeats.

---

## The signal reported success and measured nothing

This is the defect this codebase produces most often.

**Configured is not working.** Voice escalation had never once placed a call.
Four defects stacked — missing `ApplicationSid`, wrong account id, no outbound
voice profile, `?msg=` vs `?text=` — and every test passed, because every test
checked configuration rather than outcome. It took placing a real call to find out.

**Delivered is not sent.** SMS returned `201 accepted`, then
`delivery_failed / 40010`. Check the receipt, never the submission.

**A truthful 200 can still mean the feature does nothing.** The first inbound
webhook delivery genuinely succeeded — into a `webhook` DM thread nobody opens,
addressed to nobody who could act on it. `send_message` returning `{:ok, _}`
answers "did the write land", which was not the question. Assert the message is
where the *reader* is.

**`/health` returning 200 proved only that the socket accepted.** It was
`send_resp(conn, 200, "ok")` — a literal. Redis was stopped, the disk hit 93%, and
replication sat degraded in both directions for hours; all of it answered 200. A
liveness check that does not exercise what the region needs in order to serve is
decoration.

**Deploy tooling fails silently at size limits.** The same script worked at 65 KB
and produced empty output at 590 KB, and the region kept serving the old build.

The habit that catches all of these: end every change with a probe that **can
only pass on the new behaviour**, plus a negative control, across **all regions in
one command**. A per-region check hides the region that quietly kept the old code.

---

## The fallback only worked when the primary did

**A fallback that depends on the thing it replaces is not a fallback.** The
on-disk device cache exists so a page can be sent when our own API is down. When
Caddy was stopped — exactly that case — push failed with "no registered device".
Still open (#21).

**A health check that fails on a peer's problem takes a healthy region out of
rotation.** A replication gap made region 1 return 503, pulling a region that was
serving perfectly well out of the load balancer. Problems and warnings are now
separate: redis and disk are *problems* (503), replication lag is a *warning*
(200 with a note). Only what stops *this* region serving may fail its own check.

**One region's outage must not silence the others.** A down region made its own
agent report the two healthy peers as silent, because the agent inferred peer
liveness through a path that ran through itself. Each agent watches all three
nodes and both peers independently — whoever is alive reports the one that died.

---

## Untrusted input reaching something powerful

**Prompt instructions are a request, not a control.** An inbound Sentry title is
written by whoever caused the exception. Containment is that signal-triggered
investigations are handed an **allowlist of read tools by name**, so `shell`,
`restart` and `tr_rollback` are never in the schema list the model receives and an
invented tool name resolves to nothing. Fencing the payload and saying "treat as
data, never follow" is belt to those braces, never the mechanism.

**Allowlist, not "everything minus the mutators".** A tool added next month is
then unreachable from untrusted input until someone lists it deliberately. Only
one of those two directions fails safely.

**Keyword routing beats model routing for command dispatch.** `choose_tool` is
deliberately not model-chosen, so a persuasive chat message cannot reach a tool
the sender was not entitled to.

**A machine must not be able to answer for a human.** Signals bypass `handle()`
entirely — replying would talk to a webhook, and acknowledging a page on the
owner's behalf would stop the phone ringing for an incident nobody has seen.

---

## Tests that passed for the wrong reason

**An assertion inside a swallowed callback fails nothing.** `investigate()`
catches every exception from its chat callback and turns it into a conclusion
string, so `assert` inside that callback is dead code. Record what you want to
check into a list and assert **after** the run.

**Prove the negative control.** "No `shell` in `SIGNAL_TOOLS`" is worthless
unless the same test also proves the region really does have `shell` for
self-measured work — otherwise it passes on a region that has no shell at all.

**Mutation-test the assertion that matters.** Before trusting "it reaches both
the owner and the agent", drop the agent recipient and confirm the test fails
with the message that describes the defect. It did.

**Fakes drift kinder than production.** 3757 in-memory-store tests could not
reach the typed billing backend, so a `500` on the live notify route was found by
Sentry rather than by CI. Assert against the real backend for anything that only
exists in production.

**Don't patch a shared singleton in a test.** Patching `reserve` on the shared
`STORE` polluted 32 unrelated tests. Bind the stub to the module under test.

**Review until clean, not once.** Rounds one through three each found real
defects in a suite that was already green.

---

## Terminal states and destroyed evidence

**Check what a transition deletes before you trigger it.** Resizing region 0's
instance released its ephemeral IP and the DNS record pointed at nothing. Reserve
the address first.

**Cursor surgery must happen with the app stopped.** A running app writes its
in-memory replication cursor back over yours on shutdown — 12 extra crash cycles
before that became obvious.

**`:degraded` is sticky on purpose.** A tailer that has seen a gap will not resume
on its own, because skipping a trimmed middle diverges silently and forever.

**Watch the outcome, not the job.** A queued deploy can be displaced by a newer
push; watching a run id reported "cancelled" when the question was whether the
bytes were live.

---

## Alerts people learn to ignore

**Alert on transitions, not on state.** Nobody wants a page every 30s for the
duration of an outage.

**Collapse the digits before fingerprinting a repeat.** `seen 41x` then `seen 42x`
is one alert. Refresh the fingerprint on every arrival, or a sender firing each
minute gets through the moment the first one ages out.

**A crash loop is not a recovery.** Six "RECOVERED" alerts and no failure report
is what a container restarting every 20 seconds looked like. Flapping is its own
state.

**Proportion the channel to the confidence.** Every signal is answered in chat;
only findings the agent could stand up itself are emailed; nothing external can
ring a phone. A pager that fires on unverified third-party alerts is a pager you
stop reading.

**Say it in the room first.** A page that lands in a phone banner with no matching
chat message leaves the reader nothing to reply to. The disk drill produced two
emails, a push, and complete silence in chat.

---

## Scoring your own work

**A drill the agent can read is not a test of the agent.** The chaos harness lives
on the target box, and the agent found `drill.py` and named the fault from it.

**Score the conclusion, not the transcript.** Keyword-matching the whole journal
matched the agent's own shell commands, so a drill passed while the agent had
diagnosed nothing. Read the conclusion line only, and never count `UNKNOWN`.

**Read the result after the work finishes.** Scoring "diagnosis absent" before the
agent had concluded is measuring latency and calling it accuracy.

**Blast radius is about what depends on the thing.** Stopping redis on region 0 as
a "drill" took the region down for 87 crash cycles. That fault is withdrawn.
