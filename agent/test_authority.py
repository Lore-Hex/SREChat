"""Who is allowed to do what, per region.

This is the file that decides whether an agent is a monitor or has root on a
box, so the grants are asserted directly rather than inferred from behaviour.
The module reads its config at import time, so each case re-imports under a
patched environment.
"""

from __future__ import annotations

import importlib
import os
import sys

import pytest


def _agent(**env):
    """Import sre_agent fresh with the given environment."""
    saved = {k: os.environ.get(k) for k in
             ("SRE_REGION_INDEX", "SRE_ALLOW_ACTIONS", "SRE_ACTIONABLE_REGIONS",
              "SRE_FULL_POWER_REGIONS", "SRE_HOST")}
    os.environ.update({k: v for k, v in env.items() if v is not None})
    for key in saved:
        if key not in env:
            os.environ.pop(key, None)
    try:
        sys.modules.pop("sre_agent", None)
        return importlib.import_module("sre_agent")
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        sys.modules.pop("sre_agent", None)


class TestDefaults:
    def test_no_region_acts_without_the_master_switch(self) -> None:
        # SRE_ALLOW_ACTIONS is the one flag that gates everything. Being listed
        # in an actionable set must not be enough on its own.
        agent = _agent(SRE_REGION_INDEX="0", SRE_ACTIONABLE_REGIONS="0,2",
                       SRE_FULL_POWER_REGIONS="2")
        assert not agent.ACTIONABLE
        assert not agent.FULL_POWER

    def test_full_power_is_off_by_default(self) -> None:
        agent = _agent(SRE_REGION_INDEX="2", SRE_ALLOW_ACTIONS="true")
        assert not agent.FULL_POWER
        assert "shell" not in agent.TOOLS


class TestGrants:
    def test_azure_gets_a_shell_when_granted(self) -> None:
        agent = _agent(SRE_REGION_INDEX="2", SRE_ALLOW_ACTIONS="true",
                       SRE_ACTIONABLE_REGIONS="0,2", SRE_FULL_POWER_REGIONS="2")

        assert agent.FULL_POWER
        assert "shell" in agent.TOOLS

    def test_aws_never_gets_one(self) -> None:
        # One region must stay beyond the agent's reach, or an agent that
        # misbehaves takes down every failure domain at once.
        agent = _agent(SRE_REGION_INDEX="1", SRE_ALLOW_ACTIONS="true",
                       SRE_ACTIONABLE_REGIONS="0,2", SRE_FULL_POWER_REGIONS="2")

        assert not agent.FULL_POWER
        assert not agent.ACTIONABLE
        assert "shell" not in agent.TOOLS

    def test_gcp_can_act_but_has_no_shell(self) -> None:
        agent = _agent(SRE_REGION_INDEX="0", SRE_ALLOW_ACTIONS="true",
                       SRE_ACTIONABLE_REGIONS="0,2", SRE_FULL_POWER_REGIONS="2")

        assert agent.ACTIONABLE
        assert not agent.FULL_POWER
        assert "shell" not in agent.TOOLS
        assert "restart" in agent.TOOLS


class TestReportedAuthorityMatchesReality:
    def test_the_regions_table_is_derived_not_asserted(self) -> None:
        # A hardcoded flag here would keep reporting region 2 as read-only long
        # after it was handed a shell, which is exactly the kind of stale claim
        # an operator would act on.
        agent = _agent(SRE_REGION_INDEX="0", SRE_ALLOW_ACTIONS="true",
                       SRE_ACTIONABLE_REGIONS="0,2", SRE_FULL_POWER_REGIONS="2")

        by_index = {r["index"]: r["actionable"] for r in agent.REGIONS}
        assert by_index == {0: True, 1: False, 2: True}

    def test_a_full_power_agent_is_told_it_may_fix_things(self) -> None:
        # An agent whose prompt says it is a read-only monitor will decline to
        # repair anything, however many tools it holds.
        agent = _agent(SRE_REGION_INDEX="2", SRE_ALLOW_ACTIONS="true",
                       SRE_ACTIONABLE_REGIONS="0,2", SRE_FULL_POWER_REGIONS="2")

        assert "FULL AUTHORITY" in agent.SYSTEM_PROMPT
        assert "expected to FIX things" in agent.SYSTEM_PROMPT
        assert "READ-ONLY monitor" not in agent.SYSTEM_PROMPT


class TestInvestigationTools:
    def test_escalation_is_not_an_investigation_tool(self) -> None:
        # The loop decides what broke; whether to wake a human is decided once
        # from the result. A model that can page mid-loop pages on a hypothesis
        # it is about to disprove.
        agent = _agent(SRE_REGION_INDEX="2", SRE_ALLOW_ACTIONS="true",
                       SRE_ACTIONABLE_REGIONS="0,2", SRE_FULL_POWER_REGIONS="2")

        for name in ("call_human", "sms_human", "push_notify_human", "email_human"):
            assert name not in agent.INVESTIGATION_TOOLS

    def test_a_full_power_agent_can_investigate_with_a_shell(self) -> None:
        agent = _agent(SRE_REGION_INDEX="2", SRE_ALLOW_ACTIONS="true",
                       SRE_ACTIONABLE_REGIONS="0,2", SRE_FULL_POWER_REGIONS="2")

        assert "shell" in agent.INVESTIGATION_TOOLS


class TestShellTool:
    @pytest.fixture
    def agent(self):
        return _agent(SRE_REGION_INDEX="2", SRE_ALLOW_ACTIONS="true",
                      SRE_ACTIONABLE_REGIONS="0,2", SRE_FULL_POWER_REGIONS="2")

    def test_it_runs_a_command_and_reports_the_exit_code(self, agent) -> None:
        # "no output" and "failed silently" are different facts.
        assert "[exit 0]" in agent.tool_shell("echo hello")
        assert "hello" in agent.tool_shell("echo hello")
        assert "[exit 3]" in agent.tool_shell("exit 3")

    def test_empty_output_is_stated_rather_than_blank(self, agent) -> None:
        assert "(no output)" in agent.tool_shell("true")

    def test_stderr_is_included(self, agent) -> None:
        # Most diagnostics of interest are written to stderr.
        assert "boom" in agent.tool_shell("echo boom >&2")

    def test_an_empty_command_is_refused(self, agent) -> None:
        assert agent.tool_shell("   ").startswith("usage:")
