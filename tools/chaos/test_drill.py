"""The drill's own logic.

Injection cannot be tested off the target box, but the parts that decide
whether a run counts as a pass can — and those are where a drill quietly stops
measuring anything.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import drill  # noqa: E402


class TestFaultCatalogue:
    def test_every_fault_can_be_undone(self) -> None:
        # Rule 3. A drill that leaves the region broken is an outage of its own
        # making, so a fault with no restore must not exist at all.
        for fault in drill.FAULTS:
            assert fault.restore.strip(), fault.name

    def test_every_fault_can_be_confirmed_present(self) -> None:
        # Without this the drill cannot tell "the agent missed it" from "the
        # fault never landed" — and the second scores as a pass, which is the
        # most dangerous result a drill can produce.
        for fault in drill.FAULTS:
            assert fault.verify_broken.strip(), fault.name

    def test_faults_have_distinct_names(self) -> None:
        names = [f.name for f in drill.FAULTS]
        assert len(names) == len(set(names))

    def test_every_fault_states_its_ground_truth(self) -> None:
        for fault in drill.FAULTS:
            assert fault.cause.strip()
            assert len(fault.keywords) >= 2, fault.name

    def test_the_disk_fault_is_bounded_by_free_space(self) -> None:
        # Sized as a share of what is free, so it cannot fill a small disk
        # completely and turn a drill into a real outage.
        disk = next(f for f in drill.FAULTS if f.name == "disk-nearly-full")
        assert "avail" in disk.inject
        assert "80 / 100" in disk.inject


class TestDiagnosisScoring:
    def _fault(self, name: str) -> drill.Fault:
        return next(f for f in drill.FAULTS if f.name == name)

    def test_naming_the_fault_scores(self) -> None:
        activity = "[sre-agent] investigating: region 2 down\nself-repair: cause='caddy proxy stopped'"

        assert drill.scored_diagnosis(activity, self._fault("caddy-stopped"))

    def test_noticing_without_naming_does_not_score(self) -> None:
        # "region unhealthy" is detection, not diagnosis. Scoring it as
        # diagnosis would let an agent pass every drill by saying nothing
        # specific at all.
        activity = "[sre-agent] investigating: region 2 is failing its own health check"

        assert not drill.scored_diagnosis(activity, self._fault("caddy-stopped"))

    def test_diagnosing_the_wrong_fault_does_not_score(self) -> None:
        activity = "self-repair: cause='the caddy proxy was stopped'"

        assert not drill.scored_diagnosis(activity, self._fault("disk-nearly-full"))

    def test_scoring_is_case_insensitive(self) -> None:
        activity = "self-repair: cause='The CADDY proxy was STOPPED'"

        assert drill.scored_diagnosis(activity, self._fault("caddy-stopped"))

    def test_keywords_elsewhere_in_the_log_do_not_count(self) -> None:
        # The first live drill scored a pass this way: the agent's own shell
        # commands contained "docker stop" and "deploy-app-1" while its actual
        # conclusion was UNKNOWN. Matching anywhere in the journal measures
        # that the agent typed a word, not that it diagnosed anything.
        activity = (
            "[sre-agent] shell: sudo docker stop deploy-app-1\n"
            "[sre-agent] shell: sudo docker start deploy-app-1\n"
            "[sre-agent] self-repair: cause='UNKNOWN' action='NONE' resolved='no'"
        )

        assert not drill.scored_diagnosis(activity, self._fault("app-container-stopped"))

    def test_an_explicit_unknown_never_scores(self) -> None:
        activity = "self-repair: cause='UNKNOWN' action='NONE'"
        for fault in drill.FAULTS:
            assert not drill.scored_diagnosis(activity, fault)

    def test_the_latest_conclusion_wins(self) -> None:
        # A drill run after an earlier one must not read the older verdict.
        activity = (
            "self-repair: cause='the caddy proxy was stopped'\n"
            "self-repair: cause='the app container was stopped'"
        )

        assert drill.scored_diagnosis(activity, self._fault("app-container-stopped"))
        assert not drill.scored_diagnosis(activity, self._fault("caddy-stopped"))


class TestPassCriteria:
    def test_a_pass_needs_detection_diagnosis_and_a_healthy_end_state(self) -> None:
        result = drill.Result(fault="f", cause="c", injected=True, detected=True,
                              diagnosed=True, repaired_by_agent=True)
        assert result.passed

    def test_detecting_without_diagnosing_fails(self) -> None:
        result = drill.Result(fault="f", cause="c", injected=True, detected=True,
                              diagnosed=False, repaired_by_agent=True)
        assert not result.passed

    def test_a_fault_the_agent_never_saw_fails(self) -> None:
        result = drill.Result(fault="f", cause="c", injected=True, detected=False,
                              diagnosed=False, restored_by_drill=True)
        assert not result.passed

    def test_the_drill_restoring_it_still_counts_as_healthy(self) -> None:
        # The agent found and named it but could not fix it. That is a partial
        # success worth distinguishing from silence, and the record keeps
        # repaired_by_agent=False so it is never read as a self-heal.
        result = drill.Result(fault="f", cause="c", injected=True, detected=True,
                              diagnosed=True, restored_by_drill=True)
        assert result.passed
        assert not result.repaired_by_agent

    def test_notification_is_scored_separately_from_passing(self) -> None:
        # A fault the agent fixed silently is a success for the fleet and an
        # open question for the drill, not a failure.
        result = drill.Result(fault="f", cause="c", injected=True, detected=True,
                              diagnosed=True, repaired_by_agent=True, notified=False)
        assert result.passed
        assert not result.notified
