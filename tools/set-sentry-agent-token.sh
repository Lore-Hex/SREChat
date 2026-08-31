#!/usr/bin/env bash
#
# Give the agents read access to Sentry so their cloud-error sweep can pull
# unresolved issues.
#
# Get the value from:
#   Sentry -> Settings -> Custom Integrations -> SREChat Agent (GCP)
#   -> the token table -> "New Token" (the token is shown ONCE)
#
# Usage: tools/set-sentry-agent-token.sh
#        (prompts; input is hidden and never appears in argv, history, or `ps`)
#
set -euo pipefail

read -rsp "Sentry auth token (hidden): " TOKEN; echo
[ -n "${TOKEN}" ] || { echo "empty; nothing changed" >&2; exit 1; }

: "${CLOUDSDK_CORE_ACCOUNT:=tr-ops-local@quill-cloud-proxy.iam.gserviceaccount.com}"
export CLOUDSDK_CORE_ACCOUNT
AWS_KEY="${AWS_KEY:-$HOME/claude/SREChat/.roach-aws-key.pem}"

# Written to the file the agent unit sources, on every region. Region 0 is the
# one with the TrustedRouter grants, but all three sweep, so all three get it.
remote_cmd='
set -eu
F=/etc/srechat/notify.env
sudo touch "$F"; sudo chmod 600 "$F"
# sudo: the staged file is root-owned mode 600 and the SSH user is not root.
# Without it this dies with "Permission denied" AFTER the token has been typed,
# which wastes the one time Sentry ever shows it.
T="$(sudo cat /root/.sentry_agent_token)"; sudo rm -f /root/.sentry_agent_token
t=$(mktemp)
sudo grep -v -E "^(SENTRY_AUTH_TOKEN|SENTRY_ORG|SENTRY_PROJECT|SENTRY_HOST)=" "$F" > "$t" || true
{ cat "$t"; printf "SENTRY_AUTH_TOKEN=%s\nSENTRY_ORG=lore-hex-corp\nSENTRY_PROJECT=quill-router\nSENTRY_HOST=https://de.sentry.io\n" "$T"; } | sudo tee "$F" >/dev/null
rm -f "$t"; unset T
sudo systemctl restart sre-agent; sleep 5
printf "  agent: %s  sentry vars: %s\n" "$(systemctl is-active sre-agent)" "$(sudo grep -c "^SENTRY_" "$F")"
'

echo "==> region 0 (GCP)"
printf '%s' "$TOKEN" | gcloud compute ssh roach-gcp --zone us-central1-a --tunnel-through-iap --quiet \
  --command 'sudo install -m 600 /dev/stdin /root/.sentry_agent_token'
gcloud compute ssh roach-gcp --zone us-central1-a --tunnel-through-iap --quiet --command "$remote_cmd"

echo "==> region 1 (AWS)"
printf '%s' "$TOKEN" | ssh -i "$AWS_KEY" -o StrictHostKeyChecking=no admin@sre1.trustedrouter.com \
  'sudo install -m 600 /dev/stdin /root/.sentry_agent_token'
ssh -i "$AWS_KEY" -o StrictHostKeyChecking=no admin@sre1.trustedrouter.com "$remote_cmd"

echo "==> region 2 (Azure) — no SSH; staged through the control plane"
printf '%s' "$TOKEN" | base64 | tr -d '\n' > /tmp/.sentry_b64
az vm run-command invoke -g roach-rg -n roach-azure --command-id RunShellScript \
  --scripts "echo '$(cat /tmp/.sentry_b64)' | base64 -d | sudo install -m 600 /dev/stdin /root/.sentry_agent_token" \
  --query "value[0].message" -o tsv >/dev/null
rm -f /tmp/.sentry_b64
az vm run-command invoke -g roach-rg -n roach-azure --command-id RunShellScript \
  --scripts "$remote_cmd" --query "value[0].message" -o tsv | sed -e 's/^Enable succeeded: *//' -e '/^\[std/d'
unset TOKEN

cat <<'DONE'

==> installed. Verify the sweep now reads Sentry (it currently logs it as
    "unavailable"):

      gcloud compute ssh roach-gcp --zone us-central1-a --tunnel-through-iap \
        --command 'sudo journalctl -u sre-agent --since "15 min ago" --no-pager | grep -i sweep'
DONE
