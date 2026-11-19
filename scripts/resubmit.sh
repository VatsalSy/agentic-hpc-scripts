#!/usr/bin/env bash
# resubmit.sh - bounded resubmission of a package whose latest job failed.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/resubmit.sh [--dry-run] PACKAGE_DIR

Resubmits JOB_SCRIPT from the existing REMOTE_DIR (no new file transfer) when, and
only when, the cluster reports the latest recorded job as FAILED, TIMEOUT or
NODE_FAIL and fewer than MAX_RESUBMITS resubmissions have been used since the last
fresh submit. Completed, pending, running, cancelled, out-of-memory and unknown jobs
are never resubmitted. Each attempt is recorded in state/jobs.log.

The job script must be safe to run again in the same directory (resume from
checkpoints or skip finished work).

The host, directory and script recorded with the job are used, not the current
config.env, so editing config.env for another package cannot redirect an old job.
As in submit.sh, a PENDING line is written before sbatch; if the outcome is unclear the
package stays blocked until `scripts/poll.sh --reconcile JOBID|none PACKAGE_DIR`.

Exit 0 = resubmitted, 3 = refused on purpose, 4 = submission unresolved (needs a
human), 2 = usage or configuration error.

  --dry-run   check the local state, then print what would run; contact nothing
EOF
}

DRY_RUN=0
PACKAGE=""
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY_RUN=1 ;;
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
(( DRY_RUN )) || acquire_lock

refuse_if_unresolved 3
record=$(latest_record "$PKG")
[ -n "$record" ] || refuse "no job recorded for this package; use scripts/submit.sh first"
job=$(printf '%s\n' "$record" | cut -f3)
bind_record "$record"
used=$(resubmit_count "$PKG")
if (( used >= MAX_RESUBMITS )); then
  refuse "resubmit budget used up ($used of $MAX_RESUBMITS); investigate the failure instead"
fi
attempt=$(( used + 1 ))

if (( DRY_RUN )); then
  show "check job $job: $(ssh_display "$(status_cmd "$job")")"
  show "only if its state is FAILED, TIMEOUT or NODE_FAIL (attempt $attempt of $MAX_RESUBMITS):"
  show "$(ssh_display "$(sbatch_cmd)")"
  show "(PENDING is appended to $STATE_FILE before sbatch, RESUBMIT and the new job ID after it)"
  exit 0
fi

query_status "$job"
case $STATE_RAW in
  FAILED|TIMEOUT|NODE_FAIL) ;;
  *) refuse "job $job is $STATE_RAW; only FAILED, TIMEOUT or NODE_FAIL are resubmitted" ;;
esac

[ -n "$(final_state "$job" "$PKG" "$HPC_HOST")" ] \
  || state_append FINAL "$job" "$STATE_RAW" "$PKG" bind || die "could not write $STATE_FILE"
record_pending "$attempt"
remote_sbatch
record_submitted RESUBMIT "$attempt"
echo "resubmitted as job $NEW_JOB (attempt $attempt of $MAX_RESUBMITS; job $job was $STATE_RAW)"
