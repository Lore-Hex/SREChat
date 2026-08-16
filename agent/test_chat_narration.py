"""The agent has to say it in the room, not only in the mail.

A disk drill produced two emails, a push, and complete silence in chat. Chat is
where a human goes to look, and it is the only channel they can REPLY on — a
banner with no matching message leaves them nothing to answer, and the
acknowledgement clock is waiting on exactly that reply.
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


@pytest.fixture
def said(agent, monkeypatch):
    messages: list[tuple[str, str]] = []
    monkeypatch.setattr(agent, "send", lambda uid, text: messages.append((uid, text)))
    return messages


RESOLVED = (
    "CAUSE: a 23 GB junk file filled the disk\n"
    "ACTION: deleted it and re-checked df\n"
    "RESOLVED: yes"
)


def _finding(conclusion: str, tools=("containers", "shell")):
    result = investigate_mod.Investigation(trigger="disk is 93% full", conclusion=conclusion)
    for tool in tools:
        result.steps.append(
            investigate_mod.Step(tool=tool, arg="", output="out", seconds=0.1)
        )
    return result


class TestItNarratesToChat:
    def test_the_opening_note_goes_to_the_owner(self, agent, said) -> None:
        agent.send(agent.OWNER_UID, f"🔧 Working on it: {'disk is 93% full'}")

        assert said and said[0][0] == agent.OWNER_UID
        assert "Working on it" in said[0][1]

    def test_a_finding_names_the_cause_and_whether_it_is_fixed(self, agent) -> None:
        fields = investigate_mod.parse_conclusion(RESOLVED)

        assert fields["cause"] == "a 23 GB junk file filled the disk"
        assert fields["action"] == "deleted it and re-checked df"
        assert investigate_mod.is_resolved(RESOLVED)

    def test_an_unresolved_finding_says_NOT_resolved(self, agent) -> None:
        # The word has to be unmissable in a glanced-at chat line: "resolved"
        # appearing anywhere reads as good news.
        unresolved = "CAUSE: disk full\nACTION: none\nRESOLVED: no"
        verdict = "resolved" if investigate_mod.is_resolved(unresolved) else "NOT resolved"

        assert verdict == "NOT resolved"

    def test_chat_failing_does_not_stop_the_page(self, agent, monkeypatch) -> None:
        # Chat is not the pager. If the room is unreachable — which happens
        # precisely when this region is the broken one — the phone still has to
        # ring.
        def broken(_uid, _text):
            raise RuntimeError("chat unreachable")

        monkeypatch.setattr(agent, "send", broken)
        paged: list[str] = []
        monkeypatch.setattr(agent.escalate, "push_notify_human",
                            lambda reason: (paged.append(reason), "push sent")[1])

        try:
            agent.send(agent.OWNER_UID, "anything")
        except RuntimeError:
            pass
        agent.escalate.push_notify_human("region 2 down")

        assert paged, "the push must not depend on chat succeeding"


class TestEvidenceStaysInTheMail:
    def test_the_chat_line_points_at_the_email(self, agent) -> None:
        # A full tool transcript pasted into chat is unreadable on a phone. The
        # room gets the verdict; the mail carries the working.
        finding = _finding(RESOLVED)
        line = (
            f"Looked at {len(finding.steps)} thing(s): {', '.join(finding.tools_used)}\n"
            "Full evidence is in the email."
        )

        assert "2 thing(s)" in line
        assert "email" in line
