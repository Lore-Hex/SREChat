#!/usr/bin/env bash
# Run an SREAgent for one region with a sensible per-region default model.
#
#   ./run-agent.sh <0|1|2> [model]
#
# Region 0 = GCP (Kimi K3, actionable), 1 = AWS (GLM 5.2-Fast, read-only),
# 2 = Azure (DeepSeek 0731, read-only). Every agent falls back to
# trustedrouter/auto inside the LLM call, so a single provider outage never
# leaves it without a brain. TR_API_KEY comes from the env or ~/.tr_key.
set -euo pipefail

region="${1:-}"
model="${2:-}"
case "$region" in
  0) host="sre0.trustedrouter.com"; default_model="moonshotai/kimi-k3" ;;
  1) host="sre1.trustedrouter.com"; default_model="z-ai/glm-5.2-fast" ;;
  2) host="sre2.trustedrouter.com"; default_model="deepseek/deepseek-v4-flash-0731" ;;
  *) echo "usage: $0 <0|1|2> [model]" >&2; exit 2 ;;
esac

here="$(cd "$(dirname "$0")" && pwd)"
export SRE_HOST="$host"
export TR_MODEL="${model:-$default_model}"
export TR_API_KEY="${TR_API_KEY:-$(cat "$HOME/.tr_key" 2>/dev/null | tr -d '\n\r ' || true)}"

# APNs push credentials, if this host has them. Kept outside the repo so the
# signing key is never a git object, and optional so a host without it still
# runs the agent — it just cannot page a closed phone (see agent/apns.py).
# -r, not -f: under `set -e` a file that exists but cannot be read aborts the
# script, which turns a permissions mistake on an OPTIONAL credential into a
# crash-looping agent — i.e. the monitoring dies of the thing it was supposed
# to make better. Unreadable is treated exactly like absent.
if [ -r /etc/srechat/apns.env ]; then
  set -a
  # shellcheck disable=SC1091
  . /etc/srechat/apns.env
  set +a
else
  echo "note: no readable /etc/srechat/apns.env — running without APNs push" >&2
fi

if [ -z "${TR_API_KEY:-}" ]; then
  echo "warning: no TR_API_KEY (env or ~/.tr_key) — the agent will run tools but not the LLM" >&2
fi

exec python3 "$here/sre_agent.py"
