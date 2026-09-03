"""Autonomous investigation: observe, hypothesise, run tools, conclude, act.

The agent could already answer a question by keyword-matching one tool and
letting the LLM phrase the output. That is not diagnosis. Diagnosis is choosing
what to look at next BASED ON what the last thing showed, which needs a loop
and real tool calling.

Two properties matter more than cleverness here:

EVIDENCE. Every conclusion is built only from tool output that actually ran, and
the transcript of those calls is returned alongside the conclusion. An agent
that reports a confident wrong cause during an incident is worse than one that
reports nothing, because it sends a human to the wrong region while the real one
burns. The transcript is what makes a claim checkable after the fact.

TERMINATION. A step budget, always. An investigation that never concludes is an
incident nobody was told about, and an LLM given tools will happily keep looking.
Running out of steps is a reportable outcome, not a crash.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from typing import Any, Callable

# A tool is (callable, description); the callable takes one string arg.
ToolTable = dict[str, tuple[Callable[[str], str], str]]

MAX_STEPS = 12
MAX_TOOL_CHARS = 4000


@dataclass
class Step:
    tool: str
    arg: str
    output: str
    seconds: float


@dataclass
class Investigation:
    trigger: str
    conclusion: str
    steps: list[Step] = field(default_factory=list)
    exhausted: bool = False

    @property
    def evidence(self) -> str:
        """The tool calls, as a record a human can audit.

        Returned with every conclusion so a claim can be checked against what
        actually ran rather than taken on trust.
        """
        if not self.steps:
            return "(no tools were run)"
        return "\n".join(
            f"$ {s.tool}{' ' + s.arg if s.arg else ''}  ({s.seconds:.1f}s)\n{s.output}"
            for s in self.steps
        )

    @property
    def tools_used(self) -> list[str]:
        return [s.tool for s in self.steps]


def build_tool_schemas(tools: ToolTable) -> list[dict[str, Any]]:
    """OpenAI-compatible schemas from the agent's own tool table.

    Derived rather than hand-written so a tool cannot exist in one and not the
    other — a schema listing a tool the agent does not have produces a call it
    cannot answer, and vice versa hides capability from the model.
    """
    return [
        {
            "type": "function",
            "function": {
                "name": name,
                "description": description,
                "parameters": {
                    "type": "object",
                    "properties": {
                        "arg": {
                            "type": "string",
                            "description": "Argument for the tool; empty string if it takes none.",
                        }
                    },
                    "required": ["arg"],
                },
            },
        }
        for name, (_fn, description) in sorted(tools.items())
    ]


SYSTEM = """You are an SRE agent investigating a production anomaly on your own region.

Work the problem: call a tool, read what it says, and let that decide what you
look at next. Do not guess at a cause you have not seen evidence for.

Rules:
- Every claim you make must be supported by output you actually received. If a
  tool failed or returned nothing, say so; do not fill the gap with a plausible
  story.
- If you can safely repair the fault yourself, do it, then re-run a tool to
  CONFIRM it is fixed. A repair you did not verify is a guess.
- When you are done, reply with plain text and no tool call, in this shape:
    CAUSE: <one line, or UNKNOWN>
    EVIDENCE: <which tool output shows it>
    ACTION: <what you changed, or NONE>
    RESOLVED: <yes|no>
- Prefer the least destructive action that fixes it. You are on a live region.
"""


def investigate(
    trigger: str,
    tools: ToolTable,
    chat: Callable[[list[dict[str, Any]], list[dict[str, Any]]], dict[str, Any]],
    *,
    max_steps: int = MAX_STEPS,
    log: Callable[[str], None] = lambda _m: None,
) -> Investigation:
    """Run the loop until the model concludes or the step budget runs out.

    `chat` takes (messages, tool_schemas) and returns an assistant message dict,
    so this module needs no HTTP client and stays testable without a network.
    """
    schemas = build_tool_schemas(tools)
    messages: list[dict[str, Any]] = [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": f"Anomaly detected: {trigger}\n\nInvestigate."},
    ]
    result = Investigation(trigger=trigger, conclusion="")

    for _step in range(max_steps):
        try:
            reply = chat(messages, schemas)
        except Exception as exc:  # noqa: BLE001 — a dead brain must still report
            result.conclusion = f"CAUSE: UNKNOWN\nEVIDENCE: investigation failed: {exc}\nACTION: NONE\nRESOLVED: no"
            return result

        calls = reply.get("tool_calls") or []
        if not calls:
            result.conclusion = ensure_fields(
                reply.get("content") or "", result.tools_used, "concluded normally"
            )
            return result

        messages.append(reply)
        for call in calls:
            name = ((call.get("function") or {}).get("name") or "").strip()
            raw_args = (call.get("function") or {}).get("arguments") or "{}"
            try:
                arg = str(json.loads(raw_args).get("arg", ""))
            except (ValueError, AttributeError):
                # A malformed argument is the model's mistake to recover from,
                # not ours to crash on.
                arg = ""

            entry = tools.get(name)
            started = time.time()
            if entry is None:
                output = f"no such tool: {name}"
            else:
                try:
                    output = entry[0](arg)
                except Exception as exc:  # noqa: BLE001
                    # Fed back rather than raised: a failing tool is itself a
                    # finding, and often the most informative one.
                    output = f"tool raised {type(exc).__name__}: {exc}"
            output = (output or "")[:MAX_TOOL_CHARS]
            elapsed = time.time() - started

            log(f"  investigate: {name}({arg}) -> {len(output)} chars in {elapsed:.1f}s")
            result.steps.append(Step(tool=name, arg=arg, output=output, seconds=elapsed))
            messages.append(
                {"role": "tool", "tool_call_id": call.get("id", ""), "content": output}
            )

    # Out of steps, but not out of information. The first live run repaired the
    # fault on its last step and then reported UNKNOWN, because hitting the
    # budget threw away everything it had learned. Ask once more with no tools:
    # the model cannot look further, only state what it already found.
    result.exhausted = True
    messages.append({
        "role": "user",
        "content": (
            "You are out of investigation steps. Do not request any more tools. "
            "State your conclusion now from what you already saw, in the required "
            "format. If you repaired something, say so in ACTION."
        ),
    })
    try:
        final = chat(messages, [])
        stated = (final.get("content") or "").strip()
    except Exception:  # noqa: BLE001
        stated = ""

    result.conclusion = ensure_fields(
        stated, result.tools_used, f"ran out of steps after {max_steps} rounds"
    )
    return result


def ensure_fields(text: str, tools_used: list[str], note: str) -> str:
    """Guarantee a conclusion that parses.

    The model is asked for CAUSE/EVIDENCE/ACTION/RESOLVED and usually complies,
    but not always: one live run answered with plain prose after 15 tool calls.
    That was accepted verbatim, parsed to four empty strings, and went out as an
    emailed incident report and a phone push saying cause='' action=''
    resolved='' — a page with nothing in it.

    Non-empty is not the same as usable. Keep whatever the model said, as
    EVIDENCE, but never hand a caller a conclusion with no CAUSE.
    """
    stated = (text or "").strip()
    if parse_conclusion(stated)["cause"]:
        return stated

    body = stated or "(the model returned nothing)"
    return (
        f"CAUSE: UNKNOWN\n"
        f"EVIDENCE: {note}; the model did not answer in the required format. "
        f"It said: {body[:600]} (tools: {', '.join(tools_used) or 'none'})\n"
        f"ACTION: NONE\n"
        f"RESOLVED: no"
    )


def parse_conclusion(text: str) -> dict[str, str]:
    """Pull the structured fields out, tolerating a chatty model.

    Absent fields come back empty rather than missing, so a caller can never
    read a stale value from a previous investigation by accident.
    """
    fields = {"cause": "", "evidence": "", "action": "", "resolved": ""}
    for line in (text or "").splitlines():
        for key in fields:
            prefix = f"{key}:"
            if line.strip().lower().startswith(prefix):
                fields[key] = line.split(":", 1)[1].strip()
    return fields


def is_resolved(text: str) -> bool:
    return parse_conclusion(text)["resolved"].strip().lower().startswith("y")
