"""The investigation loop.

The properties worth testing are not "does it call the LLM" but: does it stop,
does it survive a tool that explodes, and is its conclusion traceable to output
that actually ran.
"""

from __future__ import annotations

import json

from investigate import (
    Investigation,
    build_tool_schemas,
    investigate,
    is_resolved,
    parse_conclusion,
)


def _call(name: str, arg: str = "", call_id: str = "c1") -> dict:
    return {
        "id": call_id,
        "function": {"name": name, "arguments": json.dumps({"arg": arg})},
    }


def _scripted(*replies):
    """An LLM that returns each reply in turn, then concludes."""
    remaining = list(replies)

    def chat(_messages, _schemas):
        if remaining:
            return remaining.pop(0)
        return {"content": "CAUSE: done\nEVIDENCE: none\nACTION: NONE\nRESOLVED: yes"}

    return chat


class TestSchemas:
    def test_schemas_are_derived_from_the_real_tool_table(self) -> None:
        # Hand-written schemas drift: one lists a tool the agent lacks and the
        # model calls something that cannot answer.
        tools = {"containers": (lambda a: "ok", "docker containers"),
                 "logs": (lambda a: "ok", "recent logs")}

        schemas = build_tool_schemas(tools)

        assert [s["function"]["name"] for s in schemas] == ["containers", "logs"]
        assert schemas[0]["function"]["description"] == "docker containers"


class TestTheLoop:
    def test_it_runs_a_tool_and_feeds_the_output_back(self) -> None:
        seen = []
        tools = {"containers": (lambda a: (seen.append(a), "app: exited")[1], "containers")}
        chat = _scripted({"tool_calls": [_call("containers")]})

        result = investigate("app unreachable", tools, chat)

        assert result.tools_used == ["containers"]
        assert "app: exited" in result.evidence
        assert is_resolved(result.conclusion)

    def test_it_stops_at_the_step_budget(self) -> None:
        # An investigation that never concludes is an incident nobody was told
        # about. Running out is a reportable outcome, not a hang.
        tools = {"containers": (lambda a: "still looking", "containers")}

        def always_calls(_messages, _schemas):
            return {"tool_calls": [_call("containers")]}

        result = investigate("something", tools, always_calls, max_steps=3)

        assert result.exhausted
        assert len(result.steps) == 3
        assert not is_resolved(result.conclusion)
        assert "ran out of steps" in result.conclusion

    def test_a_tool_that_raises_becomes_evidence_not_a_crash(self) -> None:
        # A failing tool is often the most informative finding available.
        def boom(_arg):
            raise RuntimeError("docker socket missing")

        tools = {"containers": (boom, "containers")}
        chat = _scripted({"tool_calls": [_call("containers")]})

        result = investigate("app unreachable", tools, chat)

        assert "docker socket missing" in result.evidence
        assert result.steps[0].output.startswith("tool raised RuntimeError")

    def test_an_unknown_tool_is_reported_back_to_the_model(self) -> None:
        chat = _scripted({"tool_calls": [_call("nonexistent")]})

        result = investigate("x", {"real": (lambda a: "ok", "real")}, chat)

        assert "no such tool: nonexistent" in result.evidence

    def test_malformed_arguments_do_not_crash_the_loop(self) -> None:
        tools = {"logs": (lambda a: f"arg={a!r}", "logs")}
        bad = {"tool_calls": [{"id": "c1", "function": {"name": "logs", "arguments": "not json"}}]}

        result = investigate("x", tools, _scripted(bad))

        assert result.steps[0].arg == ""

    def test_a_dead_brain_still_produces_a_report(self) -> None:
        # If the LLM is unreachable the agent must still say something a human
        # can act on, rather than vanishing mid-incident.
        def dead(_messages, _schemas):
            raise ConnectionError("TR unreachable")

        result = investigate("app down", {}, dead)

        assert "investigation failed" in result.conclusion
        assert not is_resolved(result.conclusion)

    def test_tool_output_is_truncated(self) -> None:
        tools = {"logs": (lambda a: "x" * 50_000, "logs")}

        result = investigate("x", tools, _scripted({"tool_calls": [_call("logs")]}))

        assert len(result.steps[0].output) <= 4000


class TestConclusion:
    def test_fields_are_parsed(self) -> None:
        parsed = parse_conclusion(
            "CAUSE: redis was stopped\nEVIDENCE: containers showed redis exited\n"
            "ACTION: restarted redis\nRESOLVED: yes"
        )

        assert parsed["cause"] == "redis was stopped"
        assert parsed["action"] == "restarted redis"
        assert parsed["resolved"] == "yes"

    def test_absent_fields_are_empty_not_missing(self) -> None:
        # So a caller cannot read a stale value from a previous investigation.
        parsed = parse_conclusion("CAUSE: something")

        assert parsed["action"] == ""
        assert parsed["resolved"] == ""

    def test_unresolved_is_the_default_reading(self) -> None:
        # Anything ambiguous must not be read as "fixed" — that is the failure
        # that leaves a real outage unattended.
        for text in ("", "CAUSE: x", "RESOLVED: no", "RESOLVED: unclear", "garbage"):
            assert not is_resolved(text)


class TestEvidence:
    def test_evidence_records_what_ran(self) -> None:
        tools = {"containers": (lambda a: "app: exited", "containers"),
                 "logs": (lambda a: "OOM killed", "logs")}
        chat = _scripted(
            {"tool_calls": [_call("containers")]},
            {"tool_calls": [_call("logs", "app", "c2")]},
        )

        result = investigate("app down", tools, chat)

        assert "$ containers" in result.evidence
        assert "$ logs app" in result.evidence
        assert "OOM killed" in result.evidence

    def test_an_empty_investigation_says_so(self) -> None:
        # Rather than an empty string that reads like "nothing was wrong".
        assert Investigation("t", "c").evidence == "(no tools were run)"


class TestExhaustion:
    def test_it_states_what_it_found_instead_of_discarding_it(self) -> None:
        """The first live run repaired the fault on its last step and then
        reported UNKNOWN, because hitting the budget threw away everything it
        had learned."""
        calls = {"n": 0}

        def chat(_messages, schemas):
            calls["n"] += 1
            if schemas:  # still allowed tools
                return {"tool_calls": [_call("containers")]}
            return {"content": "CAUSE: app container stopped\nEVIDENCE: containers\n"
                               "ACTION: restarted it\nRESOLVED: yes"}

        result = investigate("x", {"containers": (lambda a: "exited", "c")}, chat, max_steps=2)

        assert result.exhausted
        assert "app container stopped" in result.conclusion
        assert is_resolved(result.conclusion)

    def test_the_final_ask_offers_no_tools(self) -> None:
        # Otherwise it keeps investigating past the budget it just hit.
        seen_schemas = []

        def chat(_messages, schemas):
            seen_schemas.append(schemas)
            if schemas:
                return {"tool_calls": [_call("containers")]}
            return {"content": "CAUSE: x\nRESOLVED: no"}

        investigate("x", {"containers": (lambda a: "out", "c")}, chat, max_steps=1)

        assert seen_schemas[-1] == []

    def test_a_silent_model_still_yields_a_report(self) -> None:
        def chat(_messages, schemas):
            if schemas:
                return {"tool_calls": [_call("containers")]}
            return {"content": ""}

        result = investigate("x", {"containers": (lambda a: "out", "c")}, chat, max_steps=1)

        assert "ran out of steps" in result.conclusion
        assert not is_resolved(result.conclusion)
