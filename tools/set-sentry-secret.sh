#!/usr/bin/env bash
#
# Configure Sentry webhook signature verification on region 0.
#
# Sentry HMACs every webhook body with its internal integration's client secret
# and sends it as `sentry-hook-signature`. Giving that secret to the region lets
# it verify deliveries with nothing configured on Sentry's side — no shared token
# pasted into Sentry's UI, and the digest covers the payload rather than merely
# proving who sent it.
#
# Get the value from:
#   Sentry -> Settings -> Custom Integrations -> SREChat Agent (GCP) -> Credentials
# Sentry shows the client secret only briefly. If it reads "hidden", press
# "Rotate client secret" — nothing else consumes it, so rotating is safe — and
# copy the value it reveals.
#
# Usage:  tools/set-sentry-secret.sh
#         (prompts; input is hidden and never appears in argv, shell history,
#          `ps`, or this script's output)
#
set -euo pipefail

ZONE="${ZONE:-us-central1-a}"
INSTANCE="${INSTANCE:-roach-gcp}"
: "${CLOUDSDK_CORE_ACCOUNT:=tr-ops-local@quill-cloud-proxy.iam.gserviceaccount.com}"
export CLOUDSDK_CORE_ACCOUNT

read -rsp "Sentry client secret (hidden): " SECRET
echo
[ -n "${SECRET}" ] || { echo "empty; nothing changed" >&2; exit 1; }

echo "==> writing the secret to ${INSTANCE} (via stdin, not the command line)"
# Piped through stdin on purpose. Interpolating it into --command would expose it
# in `ps` on this machine and on the VM.
printf '%s' "${SECRET}" | gcloud compute ssh "${INSTANCE}" --zone "${ZONE}" \
  --tunnel-through-iap --quiet \
  --command 'sudo install -m 600 /dev/stdin /root/.sentry_client_secret'
unset SECRET

echo "==> configuring and restarting the app"
gcloud compute ssh "${INSTANCE}" --zone "${ZONE}" --tunnel-through-iap --quiet --command '
set -eu
cd /home/roach/RoachChat/deploy
SEC="$(sudo cat /root/.sentry_client_secret)"
sudo rm -f /root/.sentry_client_secret

# Truncate-write, never rename: a rename orphans anything holding the path open.
t=$(mktemp)
if grep -q "^SRE_SENTRY_CLIENT_SECRET=" .env; then
  sudo sed "s|^SRE_SENTRY_CLIENT_SECRET=.*|SRE_SENTRY_CLIENT_SECRET=${SEC}|" .env > "$t"
else
  { sudo cat .env; printf "SRE_SENTRY_CLIENT_SECRET=%s\n" "${SEC}"; } > "$t"
fi
sudo cp "$t" .env && rm -f "$t"
unset SEC

sudo docker compose -f docker-compose.prod.yml up -d app >/dev/null 2>&1
sleep 18
printf "health: "; curl -sS --max-time 10 http://localhost:4000/health; echo

# An unsigned request must still be refused. If this ever returns 200 the
# endpoint has stopped authenticating, which is worse than not being wired.
printf "unsigned request (want 403): "
curl -sS -o /dev/null -w "%{http_code}\n" --max-time 10 -X POST \
  http://localhost:4000/hooks/sentry -H "content-type: application/json" -d "{}"
'

cat <<'DONE'

==> configured. To prove it end to end, trigger a real alert (Sentry's
    "Send Test Notification" button only exercises the email action and will
    NOT test this path), then check the agent picked it up:

      gcloud compute ssh roach-gcp --zone us-central1-a --tunnel-through-iap \
        --command 'sudo journalctl -u sre-agent --since "10 min ago" --no-pager \
                   | grep -i "signal "'
DONE
