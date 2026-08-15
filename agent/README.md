# SREAgent — a monitoring agent on every master, backed by TrustedRouter

`sre_agent.py` is a small, dependency-free Python agent that joins SREChat as an
ordinary user and answers operational questions about the deployment. Run one on
each of the three cloud masters and you get an agent per cloud that you can DM
from the web or iOS client — each one watching the mesh from a different vantage
point, each thinking with a different model, and **each falling back to
`trustedrouter/auto`** so it never goes brain-dead when one provider has weather.

Because it talks to SREChat over the same public REST + WebSocket API a human
client uses, it keeps working during a network partition exactly the way a human
client does, and it can run on the master VM or anywhere else with network
access.

## What each agent can do

| Region | Cloud | Default model |
|---|---|---|
| 0 | GCP us-central1 | **Kimi K3** (`moonshotai/kimi-k3`) |
| 1 | AWS us-east-1 | **GLM 5.2-Fast** (`z-ai/glm-5.2-fast`) |
| 2 | Azure austriaeast | **DeepSeek 0731** (`deepseek/deepseek-v4-flash-0731`) |

**Every agent is read-only by default** — safe to DM. It reports on all three
regions (health, replication/convergence) and inspects its own VM's containers,
logs, and WireGuard mesh, but changes nothing. Chat content is treated as
**untrusted input**: the tool allowlist is enforced in code and keyword-routed,
so no message — however it's phrased — can make the agent do more than look.

If you want an agent that can also restart region 0's own containers, it's a
one-line opt-in — see [Enabling actions](#enabling-actions-optional) below.
It only ever takes effect on region 0 (GCP); AWS and Azure stay pure monitors so
those clouds remain independent failure domains.

## Prerequisites

- Python 3.9+ (standard library only — nothing to `pip install`).
- A **TrustedRouter API key** (`sk-tr-…`) with credit. Get one at
  <https://trustedrouter.com>. TrustedRouter fronts every provider with retries,
  regional failover, and alias-domain failover, which is where the agents' ~5
  nines of "always has a brain" comes from.
- To use the GCP/restart tools on region 0, run that agent **on the GCP master**
  (it shells out to `gcloud` and `sudo docker`). The read-only agents need
  neither and can run anywhere.

## Check it out and run one agent per region

On each master (or any host), clone the repo and launch the agent for that
region. The launcher picks the host, per-region model, and read-only vs
actionable automatically:

```bash
git clone https://github.com/Lore-Hex/SREChat.git
cd SREChat/agent
export TR_API_KEY=sk-tr-...            # or drop it in ~/.tr_key

# on the GCP master (region 0) — Kimi K3, actionable:
./run-agent.sh 0

# on the AWS master (region 1) — GLM 5.2-Fast, read-only:
./run-agent.sh 1

# on the Azure master (region 2) — DeepSeek 0731, read-only:
./run-agent.sh 2
```

Override the model per region if you like: `./run-agent.sh 1 moonshotai/kimi-k3`,
or set `TR_MODEL=trustedrouter/auto` to let TrustedRouter pick from the start.

### Run it as a service (survives reboots)

```bash
sudo TR_API_KEY=sk-tr-... SRE_REGION=0 \
  bash -c 'envsubst < deploy/sre-agent.service.tmpl > /etc/systemd/system/sre-agent.service'
sudo systemctl daemon-reload && sudo systemctl enable --now sre-agent
journalctl -u sre-agent -f          # watch it
```

See [`deploy/sre-agent.service.tmpl`](../deploy/sre-agent.service.tmpl).

## Chat with it

From the web client (`https://sreN.trustedrouter.com/app`) or the iOS app, sign
in as yourself and set **talk to** = `sre-agent-0` (GCP), `sre-agent-1` (AWS), or
`sre-agent-2` (Azure). Then ask, in plain English:

- *is everything healthy?* → probes all three regions
- *are the regions converging?* → writes a probe in every region and checks it replicates
- *show me the app logs* / *containers* / *wireguard*

`help` lists what the agent you're talking to can do.

## Enabling actions (optional)

By default every agent is read-only. To let the **region 0 (GCP)** agent also
read GCP and restart its own containers, opt in with one env var:

```bash
SRE_ALLOW_ACTIONS=true ./run-agent.sh 0
```

Then it will answer *show the GCP instances / DNS* and *restart the app*.

Which regions may act is configuration, not a hardcoded index:

```bash
SRE_ALLOW_ACTIONS=true          # the master switch — nothing acts without it
SRE_ACTIONABLE_REGIONS=0        # GCP reads, region-0 restart, TR triage
SRE_FULL_POWER_REGIONS=2        # an unrestricted shell on THIS VM
```

**These two grants are different and must not be conflated.** `FULL_POWER` is
root on the agent's own box. `ACTIONABLE` is authority over *other* systems —
including `tr_rollback`, which moves TrustedRouter production traffic. Granting
both to the chaos-target region hands it the ability to roll back the product;
`test_authority.py` asserts a full-power agent holds none of the tools that
reach elsewhere.

**Keep at least one region out of both sets.** AWS is a pure monitor on purpose:
an agent that can break every failure domain deletes the property the
architecture exists to provide.

The full-power shell has no command blocklist, deliberately — the point of the
grant is repairing faults nobody anticipated, and a blocklist only rules out the
repairs whoever wrote it imagined while implying the grant is bounded. What
bounds it is *where* it is enabled: a region with no production traffic that
rebuilds from `deploy/provision.sh`. Every command is logged to
`~/.srechat-shell-audit.log` before it runs.

The startup line names the mode and lists the tools, so you can read from the
logs exactly what a rollout granted:

```
starting as sre-agent-2 on the Azure ... master (region 2, full-power(shell)) ...
```

Design rationale, escalation policy, and drill rules:
**[../docs/sre-agent-design.md](../docs/sre-agent-design.md)**

## Configuration (environment variables)

| Var | Default | Meaning |
|---|---|---|
| `TR_API_KEY` | — | TrustedRouter API key (required for the LLM; without it the agent still runs tools) |
| `TR_MODEL` | `trustedrouter/cheap` | primary model; **always** falls back to `trustedrouter/auto` |
| `SRE_HOST` | `sre0.trustedrouter.com` | which master's API to talk to (region is inferred from `sreN`) |
| `SRE_REGION_INDEX` | inferred from host | force the region |
| `SRE_ALLOW_ACTIONS` | `false` (read-only) | master switch; nothing below has any effect without it |
| `SRE_ACTIONABLE_REGIONS` | `0` | regions granted GCP reads, region-0 restart, TR triage |
| `SRE_FULL_POWER_REGIONS` | *(none)* | regions granted an unrestricted shell on their own VM |
| `SRE_ACK_TIMEOUT` | `600` | seconds of chat silence on an unresolved incident before it calls you |
| `SRE_FLAP_WINDOW` | `900` | rolling window for flap detection |
| `SRE_FLAPS_TO_REPORT` | `3` | state changes in that window before it reports FLAPPING instead of each transition |
| `SRE_AGENT_UID` | `sre-agent-<region>` | the agent's chat identity |
| `SRE_DEPLOY_DIR` | auto (`~/SREChat` or `~/RoachChat`) | deploy dir the region-0 restart tool drives |
| `SRE_POLL_SECONDS` | `3` | chat poll interval |
