"""The after-action email.

A page is a sentence. This is what a human needs an hour later to check the
agent's work rather than take it on trust — which matters most exactly when the
agent says it fixed something.
"""

from __future__ import annotations

import importlib
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import investigate as investigate_mod  # noqa: E402


@pytest.fixture
def agent():
    os.environ["SRE_HOST"] = "sre2.trustedrouter.com"
    sys.modules.pop("sre_agent", None)
    module = importlib.import_module("sre_agent")
    yield module
    sys.modules.pop("sre_agent", None)


def _finding(conclusion: str, steps=()) -> investigate_mod.Investigation:
    result = investigate_mod.Investigation(trigger="region 2 failing health", conclusion=conclusion)
    for tool, output in steps:
        result.steps.append(investigate_mod.Step(tool=tool, arg="", output=output, seconds=0.2))
    return result


RESOLVED = (
    "CAUSE: the redis container was stopped\n"
    "EVIDENCE: containers showed redis exited\n"
    "ACTION: restarted redis and re-checked\n"
    "RESOLVED: yes"
)


class TestSubject:
    def test_the_subject_names_the_cause_and_the_outcome(self, agent) -> None:
        # Scanning a phone at 3am, the subject has to carry the whole story.
        subject = agent.incident_report(_finding(RESOLVED)).splitlines()[0]

        assert "redis container was stopped" in subject
        assert "resolved" in subject
        assert "Azure" in subject

    def test_an_unresolved_incident_says_so_loudly(self, agent) -> None:
        subject = agent.incident_report(
            _finding("CAUSE: disk full\nACTION: none\nRESOLVED: no")
        ).splitlines()[0]

        assert "NOT resolved" in subject

    def test_a_missing_conclusion_does_not_read_as_success(self, agent) -> None:
        # An empty verdict must never render as "resolved" — that is the
        # failure that leaves a real outage unattended.
        subject = agent.incident_report(_finding("")).splitlines()[0]

        assert "NOT resolved" in subject
        assert "unknown cause" in subject


class TestBody:
    def test_it_states_cause_action_and_resolution(self, agent) -> None:
        body = agent.incident_report(_finding(RESOLVED))

        assert "Cause:" in body and "the redis container was stopped" in body
        assert "Action:" in body and "restarted redis" in body
        assert "Resolved:" in body

    def test_it_carries_the_full_evidence_not_a_summary(self, agent) -> None:
        # A conclusion without its working is exactly what an agent should not
        # be believed on.
        body = agent.incident_report(
            _finding(RESOLVED, steps=[("containers", "redis: exited (0)"),
                                      ("shell", "docker start deploy-redis-1")])
        )

        assert "redis: exited (0)" in body
        assert "docker start deploy-redis-1" in body
        assert "$ containers" in body

    def test_it_links_somewhere_you_can_check(self, agent) -> None:
        body = agent.incident_report(_finding(RESOLVED))

        assert "https://sre2.trustedrouter.com/health" in body
        assert "/app/" in body

    def test_no_url_has_anything_after_it_on_the_line(self, agent) -> None:
        # Mail clients autolink to end-of-token, so a trailing comma lands
        # inside the href and the link 404s. A link in an incident report that
        # does not open reads as "the region is gone".
        for line in agent.incident_report(_finding(RESOLVED)).splitlines():
            if "https://" in line:
                url = line.split("https://", 1)[1]
                assert not url.endswith(","), line
                assert " " not in url.strip(), f"more than one url on a line: {line}"

    def test_urls_are_not_indented(self, agent) -> None:
        # Leading whitespace stops some clients linking at all.
        body = agent.incident_report(_finding(RESOLVED))
        for line in body.splitlines():
            if "https://" in line:
                assert line == line.lstrip(), repr(line)
        # Every region, so a reader can see whether this was one region or the
        # fleet without going to look it up.
        for region in agent.REGIONS:
            assert region["host"] in body

    def test_it_names_which_agent_reported(self, agent) -> None:
        # Three agents watch the same fleet; a report that does not say which
        # one spoke cannot be traced back to a machine to inspect.
        body = agent.incident_report(_finding(RESOLVED))

        assert agent.AGENT_UID in body

    def test_it_records_how_much_looking_was_done(self, agent) -> None:
        body = agent.incident_report(
            _finding(RESOLVED, steps=[("containers", "x"), ("logs", "y"), ("shell", "z")])
        )

        assert "3 calls" in body
        assert "containers, logs, shell" in body

    def test_an_investigation_with_no_tools_says_so(self, agent) -> None:
        # Rather than an empty evidence block that reads like nothing was wrong.
        body = agent.incident_report(_finding(RESOLVED))

        assert "(no tools were run)" in body
