#!/usr/bin/env bash
# poll.sh - report the status of the latest recorded job for a package.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/poll.sh [--watch] PACKAGE_DIR
       scripts/poll.sh --reconcile JOBID|none PACKAGE_DIR

Asks the cluster (squeue, then sacct) about the latest job recorded for PACKAGE_DIR
and prints one status line. When the job has ended, the final state is recorded once
in state/jobs.log, which is what allows a later submit. The host, directory and script
recorded with the job are used, not the current config.env.

Exit codes:
   0  completed
  10  pending or running
  20  failed, timed out, cancelled (or out of memory, node failure, ...)
  30  unknown (job not visible, the ssh connection failed, squeue/sacct failed, or
      the accounting rows of a job array disagree: MIXED)
   4  unresolved submission: sbatch may have accepted a job that was not recorded
   2  usage or configuration error

  --watch   keep polling every POLL_INTERVAL seconds until the job ends or
            MAX_POLL_HOURS have passed; then exit with the last status code

  --reconcile JOBID|none
            the manual step after exit 4. First look on the cluster (the message
            printed by submit.sh/resubmit.sh says where and since when). Give the job
            ID you found, which is recorded as the submission, or `none` if no job was
            created. Contacts nothing; only writes state/jobs.log.
EOF
}

WATCH=0
PACKAGE=""
RECONCILE=""
while [ $# -gt 0 ]; do
  case $1 in
    --watch) WATCH=1 ;;
    --reconcile) [ $# -ge 2 ] || die "--reconcile needs JOBID or none"; RECONCILE=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) [ -z "$PACKAGE" ] || die "only one PACKAGE_DIR is accepted"; PACKAGE=$1 ;;
  esac
  shift
done

need ssh
need awk
load_config
resolve_package "$PACKAGE"

# Settles an UNRESOLVED submission by hand: the human looked on the cluster and says
# which job (if any) the lost attempt created.
reconcile() {
  local line att event
  [[ $1 =~ ^([0-9]+|none)$ ]] || die "--reconcile takes a numeric JOBID or the word none"
  acquire_lock
  line=$(pending_line "$PKG")
  [ -n "$line" ] || refuse "no unresolved submission is recorded for this package; nothing to reconcile"
  if [ "$1" = none ]; then
    state_append RECONCILED - none "$PKG" || die "could not write $STATE_FILE"
    echo "recorded: no job was created for the unresolved attempt; submit.sh and resubmit.sh are unblocked"
    return 0
  fi
  multicluster_attempt "$PKG" \
    && refuse "that attempt was accepted on a named cluster, which these scripts cannot follow; handle the job by hand, then reconcile with: none"
  IFS=$'\t' read -r _ _ _ att _ <<< "$line" || true
  bind_record "$line"
  event=SUBMIT
  [ "$att" = 0 ] || event=RESUBMIT
  state_append "$event" "$1" "$att" "$PKG" bind || die "could not write $STATE_FILE"
  echo "recorded job $1 as $event (attempt $att); poll.sh now follows it"
}

if [ -n "$RECONCILE" ]; then
  reconcile "$RECONCILE"
  exit 0
fi

refuse_if_unresolved 4
record=$(latest_record "$PKG")
[ -n "$record" ] || die "no job recorded for this package; run scripts/submit.sh first"
JOB=$(printf '%s\n' "$record" | cut -f3)
bind_record "$record"

# Records FINAL for the polled job, under the state lock, and only if the polled submission
# is still the package's latest one: a slow poll must not mark a newer submission (which
# may have reused the same job ID) as finished. If the lock is busy, it records nothing now;
# the next poll will.
record_final() {
  mkdir -p "$STATE_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "note: another run holds the state lock; the final state was not recorded; run poll.sh once more before submitting" >&2
    return 0
  fi
  if [ "$(latest_record "$PKG")" = "$record" ] && [ -z "$(final_state "$JOB" "$PKG" "$HPC_HOST")" ]; then
    state_append FINAL "$JOB" "$STATE_RAW" "$PKG" bind \
      || { rmdir "$LOCK_DIR" 2>/dev/null; die "could not write $STATE_FILE"; }
  fi
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

# One check: prints one status line, records the final state once, returns the exit code.
poll_once() {
  local rc
  query_status "$JOB"
  case $STATE_CLASS in
    completed) rc=0 ;;
    pending|running) rc=10 ;;
    failed) rc=20 ;;
    *) rc=30 ;;
  esac
  printf '%s job=%s state=%s status=%s\n' "$(now)" "$JOB" "$STATE_RAW" "$STATE_CLASS"
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 20 ]; then
    record_final
  fi
  return "$rc"
}

if (( ! WATCH )); then
  rc=0
  poll_once || rc=$?
  exit "$rc"
fi

limit=$(( MAX_POLL_HOURS * 3600 ))
max_sleeps=$(( limit / POLL_INTERVAL ))
start=$SECONDS
sleeps=0
while :; do
  rc=0
  poll_once || rc=$?
  case $rc in 0|20) exit "$rc" ;; esac
  if (( sleeps >= max_sleeps || SECONDS - start + POLL_INTERVAL > limit )); then
    echo "stopped watching: MAX_POLL_HOURS=$MAX_POLL_HOURS reached; job is not finished" >&2
    exit "$rc"
  fi
  sleep "$POLL_INTERVAL"
  sleeps=$(( sleeps + 1 ))
done
