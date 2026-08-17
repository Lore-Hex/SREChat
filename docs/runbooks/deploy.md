# Runbook — Deploying to the three regions

There is **no common access path**. Each cloud is reached a different way, the
checkout lives in a different place, and one of them silently truncates large
payloads. Everything below was learned by breaking it.

## Reaching a region

| region | host | how | checkout | unix user |
|---|---|---|---|---|
| 0 | `sre0.trustedrouter.com` (GCP) | `gcloud compute ssh roach-gcp --zone us-central1-a --tunnel-through-iap` | `/home/roach/RoachChat` | `roach` |
| 1 | `sre1.trustedrouter.com` (AWS) | `ssh -i <aws-key>.pem admin@sre1.trustedrouter.com` | `/home/admin/RoachChat` | `admin` |
| 2 | `sre2.trustedrouter.com` (Azure) | `az vm run-command invoke -g roach-rg -n roach-azure --command-id RunShellScript --scripts @script.sh` | `/home/roach/RoachChat` | `roach` |

Notes that cost time to discover:

- **Region 0 has no public SSH.** Port 22 times out; IAP tunnelling is the way
  in. Use the `tr-ops-local` service account
  (`CLOUDSDK_CORE_ACCOUNT=tr-ops-local@quill-cloud-proxy.iam.gserviceaccount.com`),
  never a personal login.
- **Region 1's user is `admin`, not `roach` or `ubuntu`,** and the checkout is
  under `/home/admin`. There is **no SSM** — the instance has no IAM instance
  profile, so `describe-instance-information` returns nothing.
- **Region 2 has no SSH rule in its NSG.** `sshd` is listening but firewalled;
  the Azure control plane is the only route. Scripts go in with `--scripts @file`.
- The directories are still named `RoachChat` from before the rename. Don't
  hardcode any of this — **discover the checkout**:

```bash
for c in /home/roach/RoachChat /home/admin/RoachChat /home/ubuntu/RoachChat; do
  [ -d "$c/deploy" ] && ROOT="$c" && break
done
OWNER="$(stat -c '%U' "$ROOT")"
```

## Deploying source

Ship a tarball, extract, rebuild the image, restart the agent, verify.

```bash
tar czf /tmp/src.tgz lib config agent          # whole directories — see pitfalls
base64 -i /tmp/src.tgz | tr -d '\n' > /tmp/src.b64
# ...transfer by whichever path the region uses...
tar xzf /tmp/src.tgz -C "$ROOT" lib config agent
chown -R "$OWNER:$OWNER" "$ROOT"/{lib,config,agent}
find "$ROOT" -name '._*' -delete               # macOS tar leaves AppleDouble files
cd "$ROOT/deploy"
docker compose -f docker-compose.prod.yml build app     # BUILD, then up
docker compose -f docker-compose.prod.yml up -d app     # names the service on purpose
systemctl restart sre-agent
```

## Pitfalls, each of which shipped a silent no-op

**`--force-recreate` reuses the existing image.** A code change looks deployed
while the previous build goes on serving. You must `build app` first. This is the
single most common way a deploy lies.

**A hand-picked file list is an undeclared dependency.** Shipping
`endpoint.ex` — which calls `RedisPersistence.ping/0` — without
`redis_persistence.ex` left region 0 answering **503 for three minutes**. It
passed locally, and it passed on region 2, which already had the missing file
from an earlier deploy. Ship whole directories.

**`az vm run-command` silently caps script size.** The identical script worked at
65 KB of base64 and produced **empty output** at 590 KB; the region kept serving
the old build and reported nothing. Keep Azure payloads to the subtree that
changed (well under ~256 KB), and never treat empty output as success.

**Never `sed -i` a file that is a Docker FILE bind mount.** `sed -i` writes a new
inode and the container goes on reading the orphaned old one — a config change
that looks applied and is not. Truncate-write instead:

```bash
t=$(mktemp); sed 's/old/new/' Caddyfile > "$t"; cat "$t" > Caddyfile; rm -f "$t"
```

**Caddy fronts the app with an explicit allowlist.** A route the app serves is
invisible from the internet until it is listed in the `Caddyfile`. Insert before
the catch-all `reverse_proxy /`, not after a named sibling that may not exist on
that region. Then `caddy reload`, falling back to `docker restart deploy-caddy-1`.

**Caddy does not log to stdout here.** `docker logs deploy-caddy-1` is empty, so
you cannot use access logs to confirm an inbound request arrived. Verify at the
app layer (`docker logs deploy-app-1`, which logs non-2xx with status) or by
asserting the effect.

**A set-but-empty env var is truthy in Elixir.** `SRE_AGENT_UID=` in a `.env`
stores `""`, so `Application.get_env(...) || default` keeps the empty string and
addresses every signal to nobody. Config accessors run values through
`presence/1`; keep it that way.

**`up -d app` names the service deliberately.** A bare `up -d` recreates redis
too — see below.

## Verifying a deploy

The rule: **assert the new behaviour is live**, never that a deploy reported
success. Both silent failures above were caught only this way, and only because
all three regions were compared in a single command — a per-region check hides
the one region that quietly kept the old build.

A good probe can only pass on the new code, and comes with a negative control:

```bash
for r in 0 1 2; do
  printf "sre%s: health=%s auth=%s noauth=%s\n" "$r" \
    "$(curl -sS --max-time 20 https://sre$r.trustedrouter.com/health)" \
    "$(curl -sS -o /dev/null -w '%{http_code}' -X POST https://sre$r.trustedrouter.com/hooks/probe \
        -H "Authorization: Bearer $SRE_WEBHOOK_SECRET" -H 'content-type: application/json' -d '{}')" \
    "$(curl -sS -o /dev/null -w '%{http_code}' -X POST https://sre$r.trustedrouter.com/hooks/probe \
        -H 'content-type: application/json' -d '{}')"
done
# want: health=ok auth=200 noauth=403, on every row
```

Deploying restarts the app, so expect ~20s of Caddy 502s and a `region N is not
serving` alert from the other two agents. That is the watchdog working. A
full-power region may open a self-investigation and correctly name your own
deploy as the cause.

## Redis persistence, per region

| region | `appendonly` | volume | durable? |
|---|---|---|---|
| 0 (GCP) | `no` | anonymous | **no — loses the oplog on recreate** |
| 1 (AWS) | `yes` | named | yes |
| 2 (Azure) | `yes` | named `redis-data` | yes |

The repo's `docker-compose.prod.yml` carries the fix (`--appendonly yes
--appendfsync everysec` plus a named `redis-data` volume), and it is deliberately
**not** applied to region 0: the cutover recreates redis against an empty named
volume, so region 0's local history goes down. That is a migration to run on
purpose while watching — recovery is a peer resync, which is proven — not a side
effect of an unrelated deploy. Until then region 0 carries a latent landmine,
because the next `up -d` that recreates redis wipes it unattended anyway.

This is why deploys to regions 0 and 1 extract only `lib config agent` and patch
the one needed env var into the existing compose file, rather than replacing it.

## Secrets

`deploy/.env` supplies `${...}` substitution to compose. Add a var to **both**
`.env` and the app service's `environment:` block — the compose block is what
actually passes it into the container.

`SRE_WEBHOOK_SECRET` is shared across the three regions so one sender can fail
over between them. It is a low-value secret whose only power is posting a chat
message, rotatable by changing one env var and redeploying.

**Host SSH keys must never be committed.** `.gitignore` covers `*.pem` and
`.roach-*`; a key with no extension slipped past the first pattern once, into a
public repo. If it happens again, treat the key as compromised and rotate it —
removing it from the tree does not remove it from history, clones, or forks.
