#!/usr/bin/env bash
# submit.sh - copy a prepared package to the cluster and submit it with sbatch.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/submit.sh [--dry-run] PACKAGE_DIR

Copies PACKAGE_DIR to REMOTE_DIR on HPC_HOST (rsync over ssh, no --delete, .git/
excluded), runs `sbatch --parsable JOB_SCRIPT` there, and appends the job ID to
state/jobs.log. A PENDING line is written before sbatch runs, so a lost reply or a
failed write cannot hide a job: the package then stays blocked (exit 4 now, exit 3
later) until `scripts/poll.sh --reconcile JOBID|none PACKAGE_DIR` settles it.

Refuses (exit 3) if the log shows a job for this package that has no recorded final
state; run scripts/poll.sh first. Settings come from config.env.

  --dry-run   print the commands that would run; execute nothing, write nothing
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
need rsync
need awk
load_config
resolve_package "$PACKAGE"
[ -f "$PKG/$JOB_SCRIPT" ] || die "JOB_SCRIPT '$JOB_SCRIPT' not found in $PKG"
(( DRY_RUN )) || acquire_lock

refuse_if_unresolved 3
prev_line=$(latest_record "$PKG")
prev=$(printf '%s' "$prev_line" | cut -f3)
prev_host=$(printf '%s' "$prev_line" | cut -f6)
if [ -n "$prev" ] && [ -z "$(final_state "$prev" "$PKG" "$prev_host")" ]; then
  refuse "job $prev for this package has no recorded final state. Check it with scripts/poll.sh; a new submit is allowed once poll has recorded it as finished."
fi

if (( DRY_RUN )); then
  show "$(ssh_display "mkdir -p '$REMOTE_DIR'")"
  show "$(printf 'rsync -a --checksum --exclude=.git/ -e %q %q %q' "$RSYNC_SSH" "$PKG/" "$HPC_HOST:$REMOTE_DIR/")"
  show "$(ssh_display "$(sbatch_cmd)")"
  show "(PENDING is appended to $STATE_FILE before sbatch, SUBMIT and the job ID after it)"
  exit 0
fi

remote "mkdir -p '$REMOTE_DIR'" || die "could not create $REMOTE_DIR on $HPC_HOST"
rsync -a --checksum --exclude='.git/' -e "$RSYNC_SSH" "$PKG/" "$HPC_HOST:$REMOTE_DIR/" \
  || die "rsync failed; nothing was submitted"
record_pending 0
remote_sbatch
record_submitted SUBMIT 0
echo "submitted job $NEW_JOB on $HPC_HOST (recorded in state/jobs.log)"
