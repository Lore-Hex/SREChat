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
  # Ask for ONE LINE PER QUESTION, filtered on the box.
  #
  # Fetching the whole journal and grepping it here does not work: az
  # run-command truncates its output and keeps the TAIL, so as the journal grows
  # the EARLIEST lines silently vanish — and detection is the earliest line
  # there is. That is how a run whose log plainly showed "investigating:" at
  # +43s scored `detected: NO`, twice: I removed my own `tail -60` and Azure
  # quietly applied its own.
  #
  # Small, targeted queries cannot be truncated into a wrong answer.
  DET=$(run "sudo journalctl -u sre-agent --since '$SINCE' --no-pager 2>/dev/null \
             | grep -m1 -oE 'investigating:.*|ALERT ->.*' | cut -c1-140")
  # Require a NON-EMPTY cause. A run that logged `cause='' action='' resolved=''`
  # satisfied the old grep, so the drill broke out of its poll loop on the first
  # round and scored "no diagnosis" against an agent that was still working.
  CON=$(run "sudo journalctl -u sre-agent --since '$SINCE' --no-pager 2>/dev/null \
             | grep -oE \"cause='[^']+'.*\" | tail -1 | cut -c1-600")
  KEY=$(run "sudo journalctl -u sre-agent --since '$SINCE' --no-pager 2>/dev/null \
             | grep -c -E 'drill\.py|srechat-drills|chaos/drill' || true")

  echo "--- round $round ---"
  [ -n "$DET" ] && echo "  detect : $DET"
  [ -n "$CON" ] && echo "  cause  : $(printf '%s' "$CON" | cut -c1-120)"

  [ -z "$detected" ] && [ -n "$DET" ] && detected="round $round"
  [ -z "$concluded" ] && [ -n "$CON" ] && concluded="$CON"
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
# Three states, not two. The agent keeps REFERENCING the drill files out of
# habit — `tail -20 ~/.srechat-drills.jsonl 2>/dev/null` — long after they were
# deleted. Counting that as "read the answer key" condemns a diagnosis that was
# actually earned from waagent logs. What matters is whether anything was there
# to read, so check existence at scoring time.
PRESENT=$(run "ls /home/*/.srechat-drills.jsonl /home/*/RoachChat/tools/chaos 2>/dev/null | wc -l" | tr -d ' \n')
if [ "${KEY:-0}" != "0" ] && [ "${PRESENT:-0}" != "0" ]; then
  echo "ANSWER KEY READ : YES — the drill's own files are on the target AND the"
  echo "                  agent read them. Diagnosis is NOT credited. Remove them:"
  echo "                  the harness and its journal do not belong on the box."
elif [ "${KEY:-0}" != "0" ]; then
  echo "answer key read : no (referenced, but the files are absent — nothing to read)"
else
  echo "answer key read : no"
fi
echo "==============================="
