#!/usr/bin/env bash
#
# check-dumps.sh — list the latest database dump files per project
#
# For each project (namespace/statefulset pair in TARGETS), lists the
# $LIMIT most recently modified files in /dumps inside the statefulset
# pod, so you can check whether the scheduled dump jobs are actually
# writing and how fresh the backups are.
#
# Dependencies:
#   - kubectl   (in $PATH, configured with a valid kubeconfig; the script
#               shows the current context and asks for confirmation before
#               running anything against the cluster)
#
# Usage: ./_scripts/check-dumps.sh
set -euo pipefail

# Number of newest dump files to show per project
LIMIT=7

# Projects to check: "<namespace> <statefulset>" per line
TARGETS="
catima catima-postgres
elett snipeit-mysql
impact impact-mysql
palett etherpad-mysql
training training-mysql
uplett kuma-mysql
wlett bookstack-mysql
"

# Ensure all dependencies are available before touching the cluster
for dep in kubectl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "ERROR: dependency '$dep' not found in PATH" >&2; exit 1; }
done

# Confirm the kubectl context before running anything against the cluster
CTX=$(kubectl config current-context 2>/dev/null) || { echo "ERROR: could not determine the current kubectl context" >&2; exit 1; }

echo "Current kubectl context: $CTX"
echo "This script is READ-ONLY (kubectl exec ls), but it will"
echo "run against the cluster above. Make sure the context is the right one."
printf 'Continue? [y/N] '
read -r ans
case "$ans" in
  y|Y|yes|YES) ;;
  *) echo "Aborted (context not confirmed)." >&2; exit 1 ;;
esac
 
# Loop over each target and list the newest dumps in /dumps
echo "$TARGETS" | while read -r ns sts; do
  [ -z "$ns" ] && continue
  echo "=== $ns / $sts ==="
  # -l long listing, -t sort by mtime (newest last), -h human sizes
  kubectl exec "statefulset/$sts" -n "$ns" -- ls -ltrh /dumps | tail -n "$LIMIT"
  echo
done
