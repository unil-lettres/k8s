#!/usr/bin/env bash
#
# check-pvc-usage.sh — read-only PVC quota/usage report
#
# For every PVC in the project namespaces:
#   QUOTA : storage requested in the PVC spec (== CephFS subvolume quota)
#   USED  : actual bytes in use, measured with `df -B1` inside a running
#           pod that mounts the PVC
#
# Dependencies:
#   - kubectl   (in $PATH, configured with a valid kubeconfig; the script
#               shows the current context and asks for confirmation before
#               running anything against the cluster)
#   - python3   (stdlib only: JSON parsing of kubectl output and
#               Kubernetes quantity -> bytes conversion)
#   - awk, mktemp, tail, tr, wc   (standard on macOS and Linux)
#
# Usage: ./_scripts/check-pvc-usage.sh
#
set -u
K="kubectl"

# --- Check dependencies and confirm the kubectl context -------------------
for dep in kubectl python3 awk mktemp tail tr wc; do
  command -v "$dep" >/dev/null 2>&1 || { echo "ERROR: dependency '$dep' not found in PATH" >&2; exit 1; }
done

CTX=$("$K" config current-context 2>/dev/null) || { echo "ERROR: could not determine the current kubectl context" >&2; exit 1; }

echo "Current kubectl context: $CTX"
echo "This script is READ-ONLY (kubectl get + kubectl exec df), but it will"
echo "run against the cluster above. Make sure the context is the right one."
printf 'Continue? [y/N] '
read -r ans
case "$ans" in
  y|Y|yes|YES) ;;
  *) echo "Aborted (context not confirmed)." >&2; exit 1 ;;
esac

# List covered namespaces
NS_LIST="catima elett impact palett training uplett vlett wlett"

# Status becomes "warning" when usage is at or above this percentage
WARN_PCT=70

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- Collect PVCs + where they are mounted (per namespace) ---------------
: > "$tmp/volumes.tsv"
for ns in $NS_LIST; do
  "$K" -n "$ns" get persistentvolumeclaim,pod -o json > "$tmp/$ns.json" 2>/dev/null || continue
  python3 - "$ns" "$tmp" <<'PYEOF'
import json, sys
ns, tmp = sys.argv[1], sys.argv[2]
d = json.load(open(f"{tmp}/{ns}.json"))
pvcs = {i['metadata']['name']: i for i in d['items']
        if i['kind'] == 'PersistentVolumeClaim'}
pods = [i for i in d['items'] if i['kind'] == 'Pod']
# map pvc name -> (pod, container, mountPath) using running pods
mounts = {}
for p in pods:
    if p['status'].get('phase') != 'Running':
        continue
    vols = {v['name']: v.get('persistentVolumeClaim', {}).get('claimName')
            for v in p['spec'].get('volumes', [])}
    for c in p['spec'].get('containers', []):
        for m in c.get('volumeMounts', []):
            pvc = vols.get(m['name'])
            if pvc in pvcs and pvc not in mounts:
                mounts[pvc] = (p['metadata']['name'], c['name'], m['mountPath'])
with open(f"{tmp}/volumes.tsv", 'a') as out:
    for name in sorted(pvcs):
        pod, cont, mp = mounts.get(name, ('', '', ''))
        req = pvcs[name]['spec'].get('resources', {}).get('requests', {}).get('storage', '')
        out.write(f"{ns}\t{name}\t{req}\t{pod}\t{cont}\t{mp}\n")
PYEOF
done

# --- helpers -----------------------------------------------------------------
qty_to_bytes() {
  python3 -c '
import sys
q = sys.argv[1].strip()
if not q:
    print(0); sys.exit()
n, u = q[:-2], q[-2:]
mult = {"Ki":1024,"Mi":1024**2,"Gi":1024**3,"Ti":1024**4,
        "K":1000,"M":1000**2,"G":1000**3,"T":1000**4}.get(u, 1)
print(int(float(n) * mult))
' "$1"
}
gb() { awk -v b="${1:-0}" 'BEGIN{printf "%.2f", b/1073741824}'; }

# --- Measure usage ---------------------------------------------------------
printf "%-12s %-48s %10s %10s %8s  %s\n" "NAMESPACE" "PVC" "QUOTA(GB)" "USED(GB)" "USE%" "STATUS"
printf '%s\n' "----------------------------------------------------------------------------------------------------------------------------------"
tot_req=0
tot_used=0
n_ok=0
n_nomount=0
while IFS=$'\t' read -r ns pvc req pod cont mpath; do
  req_b=$(qty_to_bytes "$req")
  if [ -n "$pod" ]; then
    line=$("$K" -n "$ns" exec "$pod" -c "$cont" -- df -B1 "$mpath" 2>/dev/null | tail -n 1)
    # first two pure-numeric fields of df -B1 output = size, used
    # (works with both util-linux and busybox df; BSD/macOS awk compatible)
    vals=$(echo "$line" | awk '{n=0; for(i=1;i<=NF;i++){ if($i ~ /^[0-9]+$/ && n<2){ v[n]=$i; n++ } } if(n>=2){ print v[0], v[1] }}')
    if [ -n "$vals" ]; then
      size_b=$(echo "$vals" | awk '{print $1}')
      used_b=$(echo "$vals" | awk '{print $2}')
      if [ "${size_b:-0}" -gt $((req_b + req_b / 100)) ] 2>/dev/null; then
        # no subvolume quota: df shows the full filesystem, usage% is meaningless
        printf "%-12s %-48s %10s %10s %8s  %s\n" \
          "$ns" "$pvc" "$(gb "$req_b")" "-" "-" "quota not set (df shows full filesystem)"
        n_nomount=$((n_nomount + 1))
        tot_req=$((tot_req + req_b))
        continue
      fi
      # usage % -> status: "warning" when >= WARN_PCT
      pct=$(awk -v u="$used_b" -v s="$req_b" 'BEGIN{ if(s>0) printf "%.1f", u*100/s; else printf "0.0" }')
      if [ "$(awk -v p="$pct" -v t="$WARN_PCT" 'BEGIN{ print (p>=t)?1:0 }')" -eq 1 ]; then
        status="warning (used ${pct}% >= ${WARN_PCT}%)"
      else
        status="ok"
      fi
      tot_req=$((tot_req + req_b))
      tot_used=$((tot_used + used_b))
      n_ok=$((n_ok + 1))
      printf "%-12s %-48s %10s %10s %8s  %s\n" \
        "$ns" "$pvc" "$(gb "$req_b")" "$(gb "$used_b")" "${pct}%" \
        "$status"
      continue
    fi
    # pod exists but df measurement failed
    n_nomount=$((n_nomount + 1))
    tot_req=$((tot_req + req_b))
    printf "%-12s %-48s %10s %10s %8s  %s\n" \
      "$ns" "$pvc" "$(gb "$req_b")" "-" "-" "measurement failed (no df in container?)"
    continue
  fi
  n_nomount=$((n_nomount + 1))
  tot_req=$((tot_req + req_b))
  printf "%-12s %-48s %10s %10s %8s  %s\n" \
    "$ns" "$pvc" "$(gb "$req_b")" "-" "-" "no running pod (usage unknown)"
done < "$tmp/volumes.tsv"

# --- Aggregated usage ------------------------------------------------------
echo
printf '%s\n' "----------------------------------------------------------------------------------------------------------------------------------"
printf "AGGREGATED (%s namespaces):  total quota = %s GB   total used = %s GB   [%s volumes measured, %s without running pod]\n" \
  "$(echo $NS_LIST | wc -w | tr -d ' ')" "$(gb "$tot_req")" "$(gb "$tot_used")" "$n_ok" "$n_nomount"
