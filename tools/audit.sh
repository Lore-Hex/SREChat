#!/usr/bin/env bash
# Dependency-advisory gate with an explicit allowlist.
#
# `mix hex.audit` alone cannot ignore an advisory, so an unfixable-upstream
# finding would block CI forever and invite deleting the step. Instead:
# every advisory ID found must appear in .hex-audit-allow (with a written
# rationale); anything NOT allowlisted fails the build. When upstream ships
# a fixed release, `mix deps.update <pkg>` makes the allowlist entry stale —
# this script fails on stale entries too, so allowances cannot outlive
# the vulnerability they excuse.
set -euo pipefail
cd "$(dirname "$0")/.."

out=$(mix hex.audit 2>&1) && { echo "hex.audit: clean"; exit 0; }

found=$(printf '%s\n' "$out" | grep -oE 'EEF-CVE-[0-9]+-[0-9]+|GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}' | sort -u)
allowed=$(grep -vE '^\s*(#|$)' .hex-audit-allow 2>/dev/null | awk '{print $1}' | sort -u)

unexpected=$(comm -23 <(printf '%s\n' "$found") <(printf '%s\n' "$allowed") || true)
stale=$(comm -13 <(printf '%s\n' "$found") <(printf '%s\n' "$allowed") || true)

if [ -n "$unexpected" ]; then
  echo "UNALLOWLISTED advisories:"
  printf '%s\n' "$unexpected"
  printf '%s\n' "$out" | sed -n '/Advisories:/,$p'
  exit 1
fi

if [ -n "$stale" ]; then
  echo "STALE allowlist entries (advisory no longer reported — remove them):"
  printf '%s\n' "$stale"
  exit 1
fi

echo "hex.audit: only allowlisted advisories present:"
printf '%s\n' "$found"
