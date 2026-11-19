#!/usr/bin/env bash
# lib.sh - helpers shared by submit.sh, poll.sh and resubmit.sh. Source it; do not run it.
#
# Everything these scripts do to the cluster goes through `remote` (one ssh alias, key or
# agent authentication only) and rsync. Local state is one append-only, tab-separated file:
#
#   <UTC time> <TAB> <EVENT> <TAB> <job id> <TAB> <detail> <TAB> <absolute package path>
#   [<TAB> <HPC_HOST> <TAB> <REMOTE_DIR> <TAB> <JOB_SCRIPT>]     (last three: PENDING/SUBMIT/RESUBMIT/FINAL)
#
#   PENDING    job = -        detail = attempt n   written BEFORE sbatch runs (0 = fresh submit)
#   SUBMIT     detail = 0          a first submission (resets the resubmit count)
#   RESUBMIT   detail = attempt n  a bounded resubmission after a failure
#   FINAL      detail = SLURM state  recorded once poll/resubmit has seen the job end
#   RECONCILED job = -        detail = none        a human confirmed that no job was created
#
# A job counts as "unfinished" until a FINAL line exists for the same job ID, package and
# host (job IDs are only unique within one cluster). A PENDING line that is
# not followed by SUBMIT, RESUBMIT or RECONCILED for the same package is an UNRESOLVED
# submission: sbatch may have accepted a job that was never recorded, so submit.sh and
# resubmit.sh refuse until `poll.sh --reconcile JOBID|none PACKAGE_DIR` settles it.
# The host, directory and script are stored with each job, and poll/resubmit use those
# stored values, so a later edit of config.env cannot redirect an old job.
#
# Exit codes shared by the three scripts: 2 = usage/configuration error,
# 3 = refused on purpose (duplicate job, ineligible job, budget used up, unresolved
# submission), 4 = a submission is UNRESOLVED and needs a human.
# poll.sh adds 0/10/20/30, see its --help.

# Variables such as NEW_JOB, STATE_RAW and STATE_CLASS are set here and read by the
# scripts that source this file, which is why shellcheck sees them as unused in isolation.
# shellcheck disable=SC2034

LC_ALL=C
export LC_ALL

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
STATE_DIR="$ROOT_DIR/state"
STATE_FILE="$STATE_DIR/jobs.log"
LOCK_DIR="$STATE_DIR/.lock"

die()    { printf 'error: %s\n' "$1" >&2; exit 2; }
refuse() { printf 'refused: %s\n' "$1" >&2; exit 3; }
now()    { date -u +%Y-%m-%dT%H:%M:%SZ; }
show()   { printf '[dry-run] %s\n' "$1"; }

need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# ---------------------------------------------------------------- configuration

# Reads config.env as data (never sourced), allows only the known keys, then validates
# every value against a conservative character set. Because HPC_HOST, REMOTE_DIR and
# JOB_SCRIPT cannot contain quotes, spaces, semicolons or a leading dash, they are safe
# to place inside the single-quoted remote commands below.
load_config() {
  local file="$ROOT_DIR/config.env" line key val
  HPC_HOST="" REMOTE_DIR="" JOB_SCRIPT=""
  MAX_RESUBMITS=2 POLL_INTERVAL=300 MAX_POLL_HOURS=24

  [ -f "$file" ] || die "missing $file (copy config.example.env to config.env and edit it)"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    case $line in ''|'#'*) continue ;; esac
    case $line in *=*) ;; *) die "config.env: expected KEY=VALUE, got: $line" ;; esac
    key=${line%%=*}
    val=${line#*=}
    val=${val%"${val##*[![:space:]]}"}
    case $val in
      \"*\") val=${val#\"}; val=${val%\"} ;;
      \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    case $key in
      HPC_HOST|REMOTE_DIR|JOB_SCRIPT|MAX_RESUBMITS|POLL_INTERVAL|MAX_POLL_HOURS)
        printf -v "$key" '%s' "$val" ;;
      *) die "config.env: unknown key '$key'" ;;
    esac
  done < "$file"

  check_binding "$HPC_HOST" "$REMOTE_DIR" "$JOB_SCRIPT"
  [[ $MAX_RESUBMITS =~ ^(0|[1-9][0-9]*)$ ]] || die "MAX_RESUBMITS must be a whole number"
  (( MAX_RESUBMITS <= 10 )) || die "MAX_RESUBMITS above 10 is refused; fix the job instead"
  [[ $POLL_INTERVAL =~ ^[1-9][0-9]*$ ]] || die "POLL_INTERVAL must be a whole number of seconds"
  (( POLL_INTERVAL >= 60 )) || die "POLL_INTERVAL below 60 seconds is refused (be gentle on the scheduler)"
  [[ $MAX_POLL_HOURS =~ ^(0|[1-9][0-9]*)$ ]] || die "MAX_POLL_HOURS must be a whole number (0 = check once)"
}

# check_binding HOST DIR SCRIPT: the allowlists for the three values that end up inside
# remote commands. Used for config.env and again for every value read back from the log.
check_binding() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "HPC_HOST must be an SSH alias: letters, digits, . _ - (no leading dash)"
  [[ $2 =~ ^[A-Za-z0-9/][A-Za-z0-9._/+-]*$ && $2 != "/" ]] \
    || die "REMOTE_DIR must use only letters, digits and . _ / + - and must not be '/'"
  [[ $3 =~ ^[A-Za-z0-9_][A-Za-z0-9._/+-]*$ ]] \
    || die "JOB_SCRIPT must be a relative path using only letters, digits and . _ / + -"
  case $2$3 in *..*) die "REMOTE_DIR and JOB_SCRIPT must not contain '..'" ;; esac
  case /$2/ in */./*|//) die "REMOTE_DIR must not contain '.' segments or name the root" ;; esac
}

# ---------------------------------------------------------------- package

# Sets PKG to the absolute path of the package directory.
resolve_package() {
  [ -n "${1-}" ] || die "missing PACKAGE_DIR (try --help)"
  [ -d "$1" ] || die "not a directory: $1"
  PKG=$(cd "$1" && pwd -P && echo x) || die "cannot enter $1"
  PKG=${PKG%$'\n'x}
  case $PKG in *$'\t'*|*$'\n'*) die "package path must not contain tabs or newlines" ;; esac
}

# ---------------------------------------------------------------- remote access

# One ssh alias. BatchMode makes ssh fail instead of asking for a password.
# Keep these options in sync with RSYNC_SSH and ssh_display.
remote() { ssh -o BatchMode=yes -o ConnectTimeout=20 "$HPC_HOST" "$1"; }
RSYNC_SSH="ssh -o BatchMode=yes -o ConnectTimeout=20"
ssh_display() { printf 'ssh -o BatchMode=yes -o ConnectTimeout=20 %s %q' "$HPC_HOST" "$1"; }

sbatch_cmd() { printf "cd '%s' && sbatch --parsable '%s'" "$REMOTE_DIR" "$JOB_SCRIPT"; }

# squeue lists the job while it is queued or running; sacct covers the finished job.
# The remote side prints "<squeue states> / -- / <sacct states>", or QUERY_FAILED <tool>
# when squeue or sacct itself failed. The only squeue failure read as "not in the queue"
# is "Invalid job id" (SLURM's answer for a job it has already forgotten); any other
# failure, such as an unreachable controller, must never look like a finished job.
# A non-zero ssh status means the connection itself failed.
status_cmd() {
  printf "q=\$(squeue -h -j %s -o %%T 2>&1) || case \$q in *'Invalid job id'*) q= ;; *) echo QUERY_FAILED squeue; exit 0 ;; esac; a=\$(sacct -n -X -P -j %s -o State 2>&1) || { echo QUERY_FAILED sacct; exit 0; }; echo \"\$q\"; echo '--'; echo \"\$a\"; exit 0" "$1" "$1"
}

# unresolved_text REASON TIME HOST DIR SCRIPT: the message and the manual step.
unresolved_text() {
  cat >&2 <<EOF
UNRESOLVED: $1
  sbatch may have accepted a job for $PKG that this log does not know about.
  submit.sh and resubmit.sh refuse for this package until you settle it by hand:
    1. on $3, look for a job started from $4/$5 at or after $2
       (squeue -u "\$USER"; sacct -X -S <that time> -o JobID,JobName,Submit,State)
    2. record what you found:  scripts/poll.sh --reconcile JOBID PACKAGE_DIR
       or, if there is no such job:  scripts/poll.sh --reconcile none PACKAGE_DIR
EOF
}

# unresolved_exit CODE REASON: for a failure after PENDING was written (uses PENDING_AT
# and the current HPC_HOST/REMOTE_DIR/JOB_SCRIPT, so it needs nothing from the log).
unresolved_exit() {
  unresolved_text "$2" "$PENDING_AT" "$HPC_HOST" "$REMOTE_DIR" "$JOB_SCRIPT"
  exit "$1"
}

# refuse_if_unresolved CODE: stop while a PENDING record for $PKG has no outcome yet.
refuse_if_unresolved() {
  local line at att host dir script
  line=$(pending_line "$PKG")
  [ -n "$line" ] || return 0
  IFS=$'\t' read -r at _ _ att _ host dir script <<< "$line" || true
  unresolved_text "an earlier submission attempt for this package (attempt $att) has no recorded outcome" \
    "$at" "$host" "$dir" "$script"
  exit "$1"
}

# record_pending ATTEMPT: written before sbatch, so no later failure can lose the attempt.
record_pending() {
  PENDING_AT=$(now)
  state_append PENDING - "$1" "$PKG" bind \
    || die "could not write $STATE_FILE; nothing was submitted"
  sync 2>/dev/null || true   # flush it to disk before sbatch can create a job
}

# record_submitted EVENT ATTEMPT: completes the PENDING record with the new job ID.
record_submitted() {
  state_append "$1" "$NEW_JOB" "$2" "$PKG" bind \
    || unresolved_exit 4 "job $NEW_JOB was accepted by $HPC_HOST but could not be written to $STATE_FILE (the job ID is $NEW_JOB)"
}

# Runs sbatch in REMOTE_DIR and sets NEW_JOB. The caller has already run record_pending.
# Every failure from here on is ambiguous: sbatch may have run and only the reply been
# lost, so it ends as UNRESOLVED instead of a plain error.
remote_sbatch() {
  local out rc=0
  out=$(remote "$(sbatch_cmd)") || rc=$?
  [ "$rc" -eq 0 ] || unresolved_exit 4 "ssh or sbatch on $HPC_HOST exited with status $rc; no job ID was received"
  out=$(printf '%s\n' "$out" | tail -n 1)
  # "ID;cluster" means a multi-cluster site; the numeric ID alone would not identify the
  # job there, so stop rather than track the wrong one (the job may exist: UNRESOLVED).
  if [[ $out == *";"* ]]; then
    state_append MULTICLUSTER - - "$PKG" || true
    unresolved_exit 4 "sbatch named a cluster ($(printf '%s' "${out#*;}" | tr -cd '[:alnum:]._-' | cut -c1-30)); these scripts support single-cluster sites only"
  fi
  [[ $out =~ ^[0-9]+$ ]] \
    || unresolved_exit 4 "no job ID in the sbatch reply: $(printf '%s' "$out" | tr -cd '[:print:]' | cut -c1-60)"
  NEW_JOB=$out
}

# Sets STATE_RAW (a SLURM state name, or UNKNOWN/UNREACHABLE/QUERY_FAILED) and STATE_CLASS
# (pending, running, completed, failed or unknown).
query_status() {
  local out rc=0 live done_state
  [[ $1 =~ ^[0-9]+$ ]] || die "not a job ID: $1"
  out=$(remote "$(status_cmd "$1")") || rc=$?
  if [ "$rc" -ne 0 ]; then
    STATE_RAW=UNREACHABLE
    STATE_CLASS=unknown
    return 0
  fi
  if printf '%s\n' "$out" | awk '$1 == "QUERY_FAILED" {f = 1} END {exit !f}'; then
    STATE_RAW=QUERY_FAILED
    STATE_CLASS=unknown
    return 0
  fi
  live=$(printf '%s\n' "$out" | awk '$0 == "--" {exit} NF {print $1; exit}')
  done_state=$(printf '%s\n' "$out" | awk 'f && NF {print $1} $0 == "--" {f = 1}' | sort -u)
  # More than one distinct final state (a job array or heterogeneous job) is not guessed at.
  case $done_state in *$'\n'*) done_state=MIXED ;; esac
  STATE_RAW=${live:-${done_state:-UNKNOWN}}
  case $STATE_RAW in
    PENDING|CONFIGURING|REQUEUED|REQUEUE_HOLD|REQUEUE_FED|SUSPENDED|RESIZING)
      STATE_CLASS=pending ;;
    RUNNING|COMPLETING|SIGNALING)
      STATE_CLASS=running ;;
    COMPLETED)
      STATE_CLASS=completed ;;
    FAILED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|BOOT_FAIL|DEADLINE|CANCELLED|PREEMPTED|REVOKED)
      STATE_CLASS=failed ;;
    *)
      STATE_CLASS=unknown ;;
  esac
}

# ---------------------------------------------------------------- local state

# state_append EVENT JOB DETAIL PACKAGE [bind]
# With "bind" the current HPC_HOST, REMOTE_DIR and JOB_SCRIPT are stored on the same line.
state_append() {
  local extra=""
  mkdir -p "$STATE_DIR"
  [ "${5-}" != bind ] || extra=$(printf '\t%s\t%s\t%s' "$HPC_HOST" "$REMOTE_DIR" "$JOB_SCRIPT")
  # A truncated last line (for example after a full disk) would swallow this record.
  if [ -s "$STATE_FILE" ] && [ "$(tail -c 1 "$STATE_FILE" | od -An -tx1 | tr -d ' \n')" != 0a ]; then
    echo "error: the last line of $STATE_FILE is incomplete; repair it by hand" >&2
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s%s\n' "$(now)" "$1" "$2" "$3" "$4" "$extra" >> "$STATE_FILE"
}

# latest_record PACKAGE -> the newest SUBMIT/RESUBMIT line for that package (or nothing)
latest_record() {
  [ -f "$STATE_FILE" ] || return 0
  AWK_PKG="$1" awk -F '\t' '
    ($2 == "SUBMIT" || $2 == "RESUBMIT") && $5 == ENVIRON["AWK_PKG"] {l = $0}
    END {if (l != "") print l}' "$STATE_FILE"
}

# latest_job PACKAGE -> id of the newest SUBMIT/RESUBMIT for that package (or nothing)
latest_job() { latest_record "$1" | cut -f3; }

# pending_line PACKAGE -> the PENDING line that has no outcome yet (or nothing)
pending_line() {
  [ -f "$STATE_FILE" ] || return 0
  AWK_PKG="$1" awk -F '\t' '
    $5 != ENVIRON["AWK_PKG"] {next}
    $2 == "PENDING" {l = $0}
    $2 == "SUBMIT" || $2 == "RESUBMIT" || $2 == "RECONCILED" {l = ""}
    END {if (l != "") print l}' "$STATE_FILE"
}

# multicluster_attempt PACKAGE -> succeeds if the unresolved attempt named a cluster
multicluster_attempt() {
  [ -f "$STATE_FILE" ] || return 1
  AWK_PKG="$1" awk -F '\t' '
    $5 != ENVIRON["AWK_PKG"] {next}
    $2 == "PENDING" {m = 0}
    $2 == "MULTICLUSTER" {m = 1}
    END {exit !m}' "$STATE_FILE"
}

# bind_record LINE: take HPC_HOST, REMOTE_DIR and JOB_SCRIPT from columns 6-8 of a log line,
# so a job is followed and resubmitted where it was submitted, whatever config.env says now.
bind_record() {
  local h="" d="" s=""
  IFS=$'\t' read -r _ _ _ _ _ h d s <<< "$1" || true
  [ -n "$s" ] || die "the log has no host/directory/script for this job; check $STATE_FILE by hand"
  check_binding "$h" "$d" "$s"
  if [ "$h|$d|$s" != "$HPC_HOST|$REMOTE_DIR|$JOB_SCRIPT" ]; then
    printf 'note: config.env differs from the recorded submission; using %s %s %s\n' "$h" "$d" "$s" >&2
  fi
  HPC_HOST=$h REMOTE_DIR=$d JOB_SCRIPT=$s
}

# final_state JOB PACKAGE HOST -> the FINAL state recorded for that job of that package on
# that host since the package's latest SUBMIT/RESUBMIT (or nothing). Job IDs repeat across
# clusters and are reused over time, so only a FINAL for the current submission counts.
final_state() {
  [ -f "$STATE_FILE" ] || return 0
  AWK_JOB="$1" AWK_PKG="$2" AWK_HOST="$3" awk -F '\t' '
    $5 != ENVIRON["AWK_PKG"] {next}
    $2 == "SUBMIT" || $2 == "RESUBMIT" {s = ""}
    $2 == "FINAL" && $3 == ENVIRON["AWK_JOB"] && $6 == ENVIRON["AWK_HOST"] {s = $4}
    END {if (s != "") print s}' "$STATE_FILE"
}

# resubmit_count PACKAGE -> RESUBMIT lines since the package was last submitted fresh
resubmit_count() {
  if [ ! -f "$STATE_FILE" ]; then echo 0; return 0; fi
  AWK_PKG="$1" awk -F '\t' '
    $5 != ENVIRON["AWK_PKG"] {next}
    $2 == "SUBMIT"   {n = 0}
    $2 == "RESUBMIT" {n++}
    END {print n + 0}' "$STATE_FILE"
}

# A mkdir lock keeps two submit/resubmit runs from racing on the same state file.
acquire_lock() {
  mkdir -p "$STATE_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null \
    || die "another submit/resubmit is running, or crashed and left $LOCK_DIR behind (remove that directory only if no such process exists)"
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
}
