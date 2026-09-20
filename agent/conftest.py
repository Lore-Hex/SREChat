"""No unit test reaches the network. Ever.

watch_once() gained a liveness read and the suite went from 3 seconds to 41:
every test that drove the watchdog was quietly dialling the production API and
waiting out a timeout. A unit test that can reach production is a test whose
result depends on production, and one careless fixture away from writing to it.

Anything that needs network behaviour stubs the function that wants it; this
makes forgetting to do so fail fast instead of slow.
"""

import pytest


@pytest.fixture(autouse=True)
def _no_network(monkeypatch):
    def refuse(*_args, **_kwargs):
        raise OSError("network is disabled in unit tests")

    monkeypatch.setattr("urllib.request.urlopen", refuse)
