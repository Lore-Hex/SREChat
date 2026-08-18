#!/usr/bin/env bash
#
# Chaos drill against region 2 (Azure), driven ENTIRELY from this machine.
#
# The in-repo drill stages itself on the target box, and the agent there has a
# shell — it once read drill.py and named the fault straight out of the file,
# which scores the agent's reading comprehension rather than its diagnosis.
# Nothing here is written to the box: only the inject/verify/restore commands
# themselves ever land, and the scoring happens locally.
#
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
RG=roach-rg
VM=roach-azure

# The fault catalogue lives HERE, not on the target and not in a side file: a
# scheduled run starts with nothing staged, and anything staged on the box is
# something the agent can read. `--fault <name>` forces one; otherwise pick at
# random, which is what a drill is for.
read -r -d '' FAULTS <<'JSON' || true
{
 "app-container-stopped": {
   "cause": "the app container was stopped",
   "inject": "sudo docker stop deploy-app-1",
   "restore": "sudo docker start deploy-app-1",
   "broken": "! sudo docker ps --format '{{.Names}}' | grep -q deploy-app-1",
   "kw": "app container stopped down exited"},
 "disk-nearly-full": {
   "cause": "a large file filled the disk",
   "inject": "free=$(df --output=avail -m / | tail -1); sudo fallocate -l $((free * 92 / 100))M /var/log/srechat-audit.log.1",
   "restore": "sudo rm -f /var/log/srechat-audit.log.1",
   "broken": "test -f /var/log/srechat-audit.log.1",
   "kw": "disk space full storage"},
 "caddy-stopped": {
   "cause": "the caddy reverse proxy was stopped",
   "inject": "sudo docker stop deploy-caddy-1",
   "restore": "sudo docker start deploy-caddy-1",
   "broken": "! sudo docker ps --format '{{.Names}}' | grep -q deploy-caddy-1",
   "kw": "caddy proxy tls stopped down"},
 "replication-blackholed": {
   "cause": "outbound replication to peers was blocked by a firewall rule",
   "inject": "sudo iptables -I OUTPUT -p udp --dport 51820 -j DROP",
   "restore": "sudo iptables -D OUTPUT -p udp --dport 51820 -j DROP || true",
   "broken": "sudo iptables -C OUTPUT -p udp --dport 51820 -j DROP",
   "kw": "replication peer network firewall wireguard converge"}
}
JSON

SEL=$(printf '%s' "$FAULTS" | WANT="${1:-}" /usr/bin/python3 -c "
import json,os,random,sys
f=json.load(sys.stdin); want=os.environ.get('WANT','')
name = want if want in f else random.choice(sorted(f))
d=f[name]
print(name); print(d['cause']); print(d['inject']); print(d['restore']); print(d['broken']); print(d['kw'])
")
FAULT=$(printf '%s' "$SEL" | sed -n 1p)
CAUSE=$(printf '%s' "$SEL" | sed -n 2p)
INJECT=$(printf '%s' "$SEL" | sed -n 3p)
RESTORE=$(printf '%s' "$SEL" | sed -n 4p)
BROKEN=$(printf '%s' "$SEL" | sed -n 5p)
KW=$(printf '%s' "$SEL" | sed -n 6p)
[ -n "$FAULT" ] || { echo "FAIL: could not select a fault"; exit 1; }

# az wraps the script's output in "Enable succeeded:", "[stdout]" and "[stderr]"
# markers. Strip them and return only what the script printed — piping this
# through `tail -1` returns the trailing marker, which is how the last run
# recorded an empty clock and an empty fault check while the inject itself had
# actually happened.
run() {
  timeout 300 az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
    --scripts "$1" --query "value[0].message" -o tsv 2>&1 \
    | sed -e 's/^Enable succeeded: *//' -e '/^\[stdout\]$/d' -e '/^\[stderr\]$/d' \
    | sed -e '/^[[:space:]]*$/d'
}

# Restore on EVERY exit path — a drill that leaves the fault in place because it
# timed out is an outage, not a test.
restored=0
restore_now() {
  [ "$restored" = 1 ] && return
  restored=1
  echo "== RESTORE =="
  run "$RESTORE" | tail -2
  run "printf 'fault still present: '; if $BROKEN; then echo YES; else echo no; fi
       printf 'disk: '; df -h / | tail -1 | awk '{print \$5}'
       printf 'containers: '; sudo docker ps --format '{{.Names}}' | tr '\n' ' '
       printf '\nhealth: '; curl -sS --max-time 10 http://localhost:4000/health" | tail -5
}
trap restore_now EXIT INT TERM

echo "== DRILL: $FAULT on region 2 (Azure) =="
SINCE=$(run "date -u '+%Y-%m-%d %H:%M:%S'" | tr -d '\r' | tail -1)
echo "clock on box (UTC): $SINCE"

echo "== INJECT =="
run "$INJECT" | tail -2
sleep 5
echo -n "fault verified present: "
run "if $BROKEN; then echo YES; else echo NO-FAULT-DID-NOT-LAND; fi" | tail -1
run "printf 'disk now: '; df -h / | tail -1 | awk '{print \$5}'" | tail -1

# Poll the agent's own journal. Detection, then a conclusion line.
detected=""; concluded=""; action=""
for round in $(seq 1 4); do
  sleep 70
  # No tail: the whole journal since injection. `tail -60` dropped the earliest
  # lines, so on a run where the agent detected the fault in 43 seconds the
  # "investigating:" line had already scrolled away and detection scored NO —
  # the scoreboard contradicting the log it was reading.
  LOG=$(run "sudo journalctl -u sre-agent --since '$SINCE' --no-pager 2>/dev/null \
             | grep -vE 'sudo\[|pam_unix' | grep -iE 'ALERT|investigat|self-repair|cause=|resolved'")
  echo "--- round $round ---"
  echo "$LOG" | grep -iE "ALERT|investigating|self-repair|signal |resolved|cause=" | tail -4

  [ -z "$detected" ] && echo "$LOG" | grep -qiE "ALERT ->|investigating:" && detected="round $round"
  if [ -z "$concluded" ]; then
    C=$(echo "$LOG" | grep -oE "cause=[^|]*" | tail -1)
    [ -n "$C" ] && concluded="$C"
  fi
  [ -n "$concluded" ] && break
done

echo
echo "======== SCORE: $FAULT ========"
echo "injected fault : $CAUSE"
echo "detected       : ${detected:-NO}"
echo "concluded      : ${concluded:-NO CONCLUSION WITHIN WINDOW}"
# Keyword match on the CONCLUSION only — matching the whole journal once matched
# the agent's own shell commands and scored a false pass.
hit=no
for w in $KW; do
  echo "$concluded" | grep -qi -- "$w" && hit="yes (matched '$w')" && break
done
echo "diagnosis match: $hit"
# A diagnosis that came from reading the drill's own files is a lookup, not a
# diagnosis. Report it rather than counting it as a pass.
if echo "$LOG" | grep -qiE "drill\.py|srechat-drills|chaos/drill"; then
  echo "ANSWER KEY READ : YES — the agent grepped the drill's own files."
  echo "                  Diagnosis is NOT credited. Keep the harness and its"
  echo "                  journal off the target, and stop naming artifacts"
  echo "                  after the test."
else
  echo "answer key read : no"
fi
echo "==============================="
