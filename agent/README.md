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

| Region | Cloud | Default model | Authority |
|---|---|---|---|
| 0 | GCP us-central1 | **Kimi K3** (`moonshotai/kimi-k3`) | reads GCP + restarts region-0 containers |
| 1 | AWS us-east-1 | **GLM 5.2-Fast** (`z-ai/glm-5.2-fast`) | **read-only monitor** |
| 2 | Azure austriaeast | **DeepSeek 0731** (`deepseek/deepseek-v4-flash-0731`) | **read-only monitor** |

Only region 0 (GCP) can act — read GCP and restart its *own* containers. Regions
1 and 2 are **read-only** by design, so AWS and Azure stay independent failure
domains: an agent that could act on all three would erase the very property the
architecture exists to provide. Every agent can still *report* on all three
regions (health, replication/convergence) and inspect its own VM's containers,
logs, and WireGuard mesh.

Chat content is treated as **untrusted input**: the tool allowlist is enforced in
code and keyword-routed, so no message — however it's phrased — can make the
agent exceed the tools its region grants it.

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
- *show the GCP instances / DNS* (region 0 only)
- *restart the app* (region 0 only)

`help` lists what the agent you're talking to can do.

## Configuration (environment variables)

| Var | Default | Meaning |
|---|---|---|
| `TR_API_KEY` | — | TrustedRouter API key (required for the LLM; without it the agent still runs tools) |
| `TR_MODEL` | `trustedrouter/cheap` | primary model; **always** falls back to `trustedrouter/auto` |
| `SRE_HOST` | `sre0.trustedrouter.com` | which master's API to talk to (region is inferred from `sreN`) |
| `SRE_REGION_INDEX` | inferred from host | force the region (0 actionable, 1/2 read-only) |
| `SRE_AGENT_UID` | `sre-agent-<region>` | the agent's chat identity |
| `SRE_DEPLOY_DIR` | auto (`~/SREChat` or `~/RoachChat`) | deploy dir the region-0 restart tool drives |
| `SRE_POLL_SECONDS` | `3` | chat poll interval |
