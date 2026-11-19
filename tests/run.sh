#!/usr/bin/env bash
# tests/run.sh - offline test runner.
#
# Puts fake ssh, rsync, sbatch, squeue, sacct and sleep (tests/stubs) first on PATH and
# runs the real scripts against them in throw-away sandboxes. The fake "cluster" is a
# directory: each job's states come from $FAKE_ROOT/jobs/<id>, one state per line, one
# line per squeue call. No network, no real ssh, nothing submitted anywhere.
#
# Usage: bash tests/run.sh
set -u

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
PATH="$SRC/tests/stubs:$PATH"
export PATH

WORK=$(mktemp -d "${TMPDIR:-/tmp}/hpc-test.XXXXXX") || exit 1
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
NSANDBOX=0
T=""
out=""
rc=0

ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

check_eq() {   # description expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
check_contains() {   # description text needle
  case $2 in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in: $2)" ;; esac
}
check_not_contains() {   # description text needle
  case $2 in *"$3"*) bad "$1 (found '$3' in: $2)" ;; *) ok "$1" ;; esac
}
check_match() {   # description text glob-pattern
  # shellcheck disable=SC2053
  if [[ $2 == $3 ]]; then ok "$1"; else bad "$1 (got '$2')"; fi
}
check_file()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 (missing $2)"; fi; }
check_nofile() { if [ -e "$2" ]; then bad "$1 (unexpected $2)"; else ok "$1"; fi; }

count_calls() {   # prefix -> number of fake-command calls logged with that prefix
  if [ -f "$FAKE_ROOT/calls.log" ]; then grep -c "^$1" "$FAKE_ROOT/calls.log" || true; else echo 0; fi
}
count_sleeps() {
  if [ -f "$FAKE_ROOT/sleeps.log" ]; then wc -l < "$FAKE_ROOT/sleeps.log" | tr -d ' '; else echo 0; fi
}
count_log() {   # event -> number of lines with that event in state/jobs.log
  if [ -f "$T/repo/state/jobs.log" ]; then awk -F '\t' -v e="$1" '$2 == e {n++} END {print n + 0}' "$T/repo/state/jobs.log"; else echo 0; fi
}

# write_config MAX_RESUBMITS MAX_POLL_HOURS POLL_INTERVAL
write_config() {
  cat > "$T/repo/config.env" <<EOF
# test configuration
HPC_HOST=testhost
REMOTE_DIR=$T/remote/run1
JOB_SCRIPT=job.sbatch
MAX_RESUBMITS=${1:-2}
POLL_INTERVAL=${3:-60}
MAX_POLL_HOURS=${2:-1}
EOF
}

new_sandbox() {
  NSANDBOX=$((NSANDBOX + 1))
  T="$WORK/t$NSANDBOX"
  mkdir -p "$T/repo" "$T/pkg" "$T/fake/jobs"
  cp -R "$SRC/scripts" "$T/repo/scripts"
  printf '#!/bin/bash\n#SBATCH --time=00:01:00\necho hello\n' > "$T/pkg/job.sbatch"
  echo "input" > "$T/pkg/input.txt"
  write_config
  FAKE_ROOT="$T/fake"
  export FAKE_ROOT
}

# run1 SCRIPT ARG / run2 SCRIPT ARG1 ARG2: run a real script, set $out and $rc
run1() { out=$("$T/repo/scripts/$1" "$2" 2>&1) && rc=0 || rc=$?; }
run2() { out=$("$T/repo/scripts/$1" "$2" "$3" 2>&1) && rc=0 || rc=$?; }

# set_states JOB STATE... : fixture for the fake squeue/sacct
set_states() {
  local job=$1
  shift
  : > "$FAKE_ROOT/jobs/$job"
  rm -f "$FAKE_ROOT/jobs/$job.tick"
  while [ $# -gt 0 ]; do echo "$1" >> "$FAKE_ROOT/jobs/$job"; shift; done
}

submitted_sandbox() { new_sandbox; run1 submit.sh "$T/pkg"; }

# ------------------------------------------------------------------ submit

test_submit_records_job() {
  echo "submit records a job"
  submitted_sandbox
  check_eq "exit 0" 0 "$rc"
  check_contains "prints the job id" "$out" "submitted job 1000"
  local line
  line=$(tail -n 1 "$T/repo/state/jobs.log")
  check_match "log line: time, SUBMIT, id, 0, package, host, dir, script" "$line" \
    "20??-??-??T??:??:??Z"$'\t'"SUBMIT"$'\t'"1000"$'\t'"0"$'\t'"$T/pkg"$'\t'"testhost"$'\t'"$T/remote/run1"$'\t'"job.sbatch"
  check_match "the attempt was recorded as PENDING first" "$(head -n 1 "$T/repo/state/jobs.log")" \
    "20??-??-??T??:??:??Z"$'\t'"PENDING"$'\t'"-"$'\t'"0"$'\t'"$T/pkg"$'\t'"testhost"$'\t'"$T/remote/run1"$'\t'"job.sbatch"
  check_file "package copied to the remote dir" "$T/remote/run1/input.txt"
  check_eq "one sbatch call" 1 "$(count_calls sbatch)"
  check_contains "ssh used batch mode" "$(cat "$FAKE_ROOT/calls.log")" "ssh testhost ::"
}

test_submit_refuses_cluster_suffix() {
  echo "an 'id;cluster' reply (multi-cluster site) ends UNRESOLVED instead of tracking a bare id"
  new_sandbox
  : > "$FAKE_ROOT/sbatch_cluster_suffix"
  run1 submit.sh "$T/pkg"
  check_eq "exit 4 (unresolved)" 4 "$rc"
  check_eq "no SUBMIT line" 0 "$(count_log SUBMIT)"
  run1 submit.sh "$T/pkg"
  check_eq "package stays blocked (exit 3)" 3 "$rc"
  check_eq "still one sbatch call" 1 "$(count_calls sbatch)"
}

test_submit_failure_records_nothing() {
  echo "a failed rsync records nothing"
  new_sandbox
  : > "$FAKE_ROOT/rsync_fail"
  run1 submit.sh "$T/pkg"
  check_eq "exit 2" 2 "$rc"
  check_eq "no sbatch call" 0 "$(count_calls sbatch)"
  check_nofile "no state file" "$T/repo/state/jobs.log"
}

test_duplicate_submit_refused() {
  echo "duplicate submit is refused while the job is unfinished"
  submitted_sandbox
  set_states 1000 RUNNING
  run1 submit.sh "$T/pkg"
  check_eq "exit 3" 3 "$rc"
  check_contains "explains why" "$out" "no recorded final state"
  check_eq "still one sbatch call" 1 "$(count_calls sbatch)"
  check_eq "still one SUBMIT line" 1 "$(count_log SUBMIT)"
  run1 poll.sh "$T/pkg"
  check_eq "poll sees RUNNING (exit 10)" 10 "$rc"
  run1 submit.sh "$T/pkg"
  check_eq "still refused after polling a running job" 3 "$rc"
}

test_submit_allowed_after_final() {
  echo "submit is allowed again once poll has recorded the job as finished"
  submitted_sandbox
  set_states 1000 COMPLETED
  run1 poll.sh "$T/pkg"
  check_eq "poll exit 0" 0 "$rc"
  check_eq "one FINAL line" 1 "$(count_log FINAL)"
  run1 poll.sh "$T/pkg"
  check_eq "second poll does not duplicate FINAL" 1 "$(count_log FINAL)"
  run1 submit.sh "$T/pkg"
  check_eq "new submit exit 0" 0 "$rc"
  check_contains "new job id" "$out" "submitted job 1001"
  check_eq "two SUBMIT lines" 2 "$(count_log SUBMIT)"
}

test_submit_input_checks() {
  echo "submit checks its input before touching anything"
  new_sandbox
  rm "$T/pkg/job.sbatch"
  run1 submit.sh "$T/pkg"
  check_eq "missing job script: exit 2" 2 "$rc"
  run1 submit.sh "$T/does-not-exist"
  check_eq "missing package dir: exit 2" 2 "$rc"
  run2 submit.sh --bogus "$T/pkg"
  check_eq "unknown option: exit 2" 2 "$rc"
  check_eq "no remote calls at all" 0 "$(count_calls ssh)"
}

# ------------------------------------------------------------------ config

test_config_validation() {
  echo "config values are validated before any remote call"
  local bad_line
  for bad_line in \
    "REMOTE_DIR=x; echo pwned" \
    "REMOTE_DIR=a b" \
    "REMOTE_DIR=/" \
    "REMOTE_DIR=/." \
    "REMOTE_DIR=runs/./x" \
    "REMOTE_DIR=../escape" \
    "HPC_HOST=-oProxyCommand=true" \
    "HPC_HOST=host;ls" \
    "JOB_SCRIPT=/abs/job.sbatch" \
    "JOB_SCRIPT=\$(id)" \
    "MAX_RESUBMITS=99" \
    "MAX_RESUBMITS=two" \
    "POLL_INTERVAL=5" \
    "MAX_POLL_HOURS=-1" \
    "SURPRISE=1"; do
    new_sandbox
    printf '%s\n' "$bad_line" >> "$T/repo/config.env"
    run1 submit.sh "$T/pkg"
    check_eq "rejects: $bad_line" 2 "$rc"
    check_eq "  no ssh call" 0 "$(count_calls ssh)"
  done
  new_sandbox
  rm "$T/repo/config.env"
  run1 submit.sh "$T/pkg"
  check_eq "missing config.env: exit 2" 2 "$rc"
  check_contains "  points at config.example.env" "$out" "config.example.env"
  new_sandbox
  printf 'HPC_HOST="testhost"  \nJOB_SCRIPT='"'"'job.sbatch'"'"'\n' >> "$T/repo/config.env"
  run2 submit.sh --dry-run "$T/pkg"
  check_eq "quoted values and later lines override earlier ones" 0 "$rc"
}

# ------------------------------------------------------------------ poll

poll_case() {   # raw-state expected-exit expected-status
  submitted_sandbox
  set_states 1000 "$1"
  run1 poll.sh "$T/pkg"
  check_eq "'$1' -> exit $2" "$2" "$rc"
  check_contains "  one status line says status=$3" "$out" "status=$3"
  check_contains "  and names the job" "$out" "job=1000"
}

test_poll_exit_codes() {
  echo "poll exit codes"
  poll_case PENDING 10 pending
  poll_case RUNNING 10 running
  poll_case COMPLETED 0 completed
  poll_case FAILED 20 failed
  poll_case TIMEOUT 20 failed
  poll_case NODE_FAIL 20 failed
  poll_case "CANCELLED by 0" 20 failed
  poll_case SOMETHING_NEW 30 unknown

  submitted_sandbox
  run1 poll.sh "$T/pkg"
  check_eq "job invisible to squeue and sacct -> exit 30" 30 "$rc"
  check_eq "  nothing recorded as final" 0 "$(count_log FINAL)"

  submitted_sandbox
  set_states 1000 COMPLETED
  : > "$FAKE_ROOT/ssh_fail"
  run1 poll.sh "$T/pkg"
  check_eq "ssh connection failure -> exit 30, not 'failed'" 30 "$rc"
  check_contains "  status line says UNREACHABLE" "$out" "UNREACHABLE"
  check_eq "  nothing recorded as final" 0 "$(count_log FINAL)"

  new_sandbox
  run1 poll.sh "$T/pkg"
  check_eq "no job recorded yet -> exit 2" 2 "$rc"
}

test_poll_watch() {
  echo "poll --watch"
  submitted_sandbox
  set_states 1000 PENDING RUNNING COMPLETED
  run2 poll.sh --watch "$T/pkg"
  check_eq "follows PENDING, RUNNING, COMPLETED to exit 0" 0 "$rc"
  check_eq "  three status lines" 3 "$(printf '%s\n' "$out" | grep -c 'job=1000')"
  check_eq "  slept twice" 2 "$(count_sleeps)"
  check_contains "  slept POLL_INTERVAL" "$(cat "$FAKE_ROOT/sleeps.log")" "sleep 60"

  submitted_sandbox
  set_states 1000 RUNNING FAILED
  run2 poll.sh --watch "$T/pkg"
  check_eq "stops at a failure with exit 20" 20 "$rc"

  new_sandbox
  write_config 2 1 1800
  run1 submit.sh "$T/pkg"
  set_states 1000 RUNNING
  run2 poll.sh --watch "$T/pkg"
  check_eq "bounded by MAX_POLL_HOURS: exit 10" 10 "$rc"
  check_eq "  3 polls (hour / 30 min + 1)" 3 "$(count_calls squeue)"
  check_eq "  2 sleeps" 2 "$(count_sleeps)"
  check_contains "  says why it stopped" "$out" "MAX_POLL_HOURS=1 reached"

  new_sandbox
  write_config 2 0 300
  run1 submit.sh "$T/pkg"
  set_states 1000 PENDING
  run2 poll.sh --watch "$T/pkg"
  check_eq "MAX_POLL_HOURS=0 checks once" 10 "$rc"
  check_eq "  no sleep" 0 "$(count_sleeps)"
}

# ------------------------------------------------------------------ resubmit

test_resubmit_is_bounded() {
  echo "resubmit is bounded by MAX_RESUBMITS (2)"
  submitted_sandbox
  set_states 1000 FAILED
  run1 resubmit.sh "$T/pkg"
  check_eq "failed job: exit 0" 0 "$rc"
  check_contains "  says attempt 1 of 2" "$out" "attempt 1 of 2"
  check_eq "  new job recorded as RESUBMIT" 1 "$(count_log RESUBMIT)"
  check_eq "  old job recorded as FINAL FAILED" 1 "$(count_log FINAL)"
  check_contains "  RESUBMIT line has id and attempt" "$(grep RESUBMIT "$T/repo/state/jobs.log")" \
    $'\t'"1001"$'\t'"1"$'\t'"$T/pkg"

  set_states 1001 TIMEOUT
  run1 resubmit.sh "$T/pkg"
  check_eq "timed-out job: exit 0" 0 "$rc"
  check_contains "  says attempt 2 of 2" "$out" "attempt 2 of 2"

  set_states 1002 FAILED
  local ssh_before
  ssh_before=$(count_calls ssh)
  run1 resubmit.sh "$T/pkg"
  check_eq "third resubmit: refused, exit 3" 3 "$rc"
  check_contains "  budget message" "$out" "budget used up (2 of 2)"
  check_eq "  no new sbatch" 3 "$(count_calls sbatch)"
  check_eq "  refused without contacting the cluster" "$ssh_before" "$(count_calls ssh)"

  run1 poll.sh "$T/pkg"
  check_eq "poll follows the newest job" 20 "$rc"
  check_contains "  status line shows job 1002" "$out" "job=1002"

  run1 submit.sh "$T/pkg"
  check_eq "a fresh submit is allowed after a final failure" 0 "$rc"
  set_states 1003 FAILED
  run1 resubmit.sh "$T/pkg"
  check_eq "and resets the resubmit budget" 0 "$rc"
}

test_resubmit_refuses_ineligible() {
  echo "resubmit refuses jobs that should not be resubmitted"
  local state
  for state in COMPLETED RUNNING PENDING "CANCELLED by 0" OUT_OF_MEMORY SOMETHING_NEW; do
    submitted_sandbox
    set_states 1000 "$state"
    run1 resubmit.sh "$T/pkg"
    check_eq "'$state' -> refused (exit 3)" 3 "$rc"
    check_eq "  no second sbatch" 1 "$(count_calls sbatch)"
    check_eq "  no RESUBMIT recorded" 0 "$(count_log RESUBMIT)"
  done

  submitted_sandbox
  run1 resubmit.sh "$T/pkg"
  check_eq "job invisible to the scheduler -> refused" 3 "$rc"

  submitted_sandbox
  set_states 1000 FAILED
  : > "$FAKE_ROOT/ssh_fail"
  run1 resubmit.sh "$T/pkg"
  check_eq "unreachable cluster -> refused, not resubmitted" 3 "$rc"

  new_sandbox
  run1 resubmit.sh "$T/pkg"
  check_eq "never submitted -> refused" 3 "$rc"
  check_eq "  no remote calls" 0 "$(count_calls ssh)"

  new_sandbox
  write_config 0
  run1 submit.sh "$T/pkg"
  set_states 1000 FAILED
  run1 resubmit.sh "$T/pkg"
  check_eq "MAX_RESUBMITS=0 disables resubmission" 3 "$rc"
}

# ------------------------------------------------------------------ dry run

test_dry_run_executes_nothing() {
  echo "--dry-run executes nothing"
  new_sandbox
  run2 submit.sh --dry-run "$T/pkg"
  check_eq "submit --dry-run: exit 0" 0 "$rc"
  check_contains "  prints the sbatch command" "$out" "[dry-run] ssh"
  check_contains "  mentions rsync" "$out" "rsync -a"
  check_contains "  mentions sbatch" "$out" "--parsable"
  check_not_contains "  the shown command is shell-quoted, not double-quoted" "$out" "\"cd '"
  check_nofile "  no fake command was invoked" "$FAKE_ROOT/calls.log"
  check_nofile "  no state file written" "$T/repo/state/jobs.log"
  check_nofile "  no remote directory created" "$T/remote"

  submitted_sandbox
  set_states 1000 FAILED
  local calls_before log_before
  calls_before=$(wc -l < "$FAKE_ROOT/calls.log" | tr -d ' ')
  log_before=$(wc -l < "$T/repo/state/jobs.log" | tr -d ' ')
  run2 resubmit.sh --dry-run "$T/pkg"
  check_eq "resubmit --dry-run: exit 0" 0 "$rc"
  check_contains "  prints the plan" "$out" "[dry-run]"
  check_contains "  says attempt 1 of 2" "$out" "attempt 1 of 2"
  check_eq "  no new fake-command calls" "$calls_before" "$(wc -l < "$FAKE_ROOT/calls.log" | tr -d ' ')"
  check_eq "  state file unchanged" "$log_before" "$(wc -l < "$T/repo/state/jobs.log" | tr -d ' ')"
  check_nofile "  no lock left behind" "$T/repo/state/.lock"

  submitted_sandbox
  run2 submit.sh --dry-run "$T/pkg"
  check_eq "submit --dry-run still reports a duplicate (exit 3)" 3 "$rc"

  submitted_sandbox
  set_states 1000 FAILED
  run1 resubmit.sh "$T/pkg"
  set_states 1001 FAILED
  run1 resubmit.sh "$T/pkg"
  set_states 1002 FAILED
  run2 resubmit.sh --dry-run "$T/pkg"
  check_eq "resubmit --dry-run reports an exhausted budget (exit 3)" 3 "$rc"
}

# ------------------------------------------------------------------ minimal example

test_minimal_example() {
  echo "minimal/submit-and-poll.sh"
  new_sandbox
  mkdir -p "$T/remote/run1"
  cp "$T/pkg/job.sbatch" "$T/remote/run1/job.sbatch"
  set_states 1000 PENDING RUNNING COMPLETED
  out=$(bash "$SRC/minimal/submit-and-poll.sh" testhost "$T/remote/run1" job.sbatch 2>&1) && rc=0 || rc=$?
  check_eq "exit 0" 0 "$rc"
  check_contains "submits" "$out" "submitted job 1000"
  check_contains "reports the final state from sacct" "$out" "COMPLETED"
  check_eq "polled until the job left the queue (slept twice)" 2 "$(count_sleeps)"
  check_contains "sleeps five minutes" "$(cat "$FAKE_ROOT/sleeps.log")" "sleep 300"

  local n
  n=$(grep -v '^[[:space:]]*#' "$SRC/minimal/submit-and-poll.sh" | grep -vc '^[[:space:]]*$')
  if [ "$n" -le 13 ]; then ok "has $n non-comment lines (limit 13)"; else bad "has $n non-comment lines (limit 13)"; fi
}

# run_min HOST DIR SCRIPT: the minimal example as a user would run it
run_min() { out=$(bash "$SRC/minimal/submit-and-poll.sh" "$1" "$2" "$3" 2>&1) && rc=0 || rc=$?; }

test_minimal_rejects_unsafe_arguments() {
  echo "minimal/submit-and-poll.sh refuses unsafe arguments before any ssh call"
  local args dir="$T/remote/run1"
  new_sandbox
  dir="$T/remote/run1"
  mkdir -p "$dir"
  cp "$T/pkg/job.sbatch" "$dir/job.sbatch"
  set_states 1000 COMPLETED
  for args in \
    "testhost|x'; touch $T/pwned; '|job.sbatch" \
    "testhost|$dir|job.sbatch'; touch $T/pwned; '" \
    "testhost; touch $T/pwned|$dir|job.sbatch" \
    "-oProxyCommand=true|$dir|job.sbatch" \
    "testhost|../escape|job.sbatch" \
    "testhost|$dir|../job.sbatch" \
    "testhost|$dir|-x" \
    "testhost|$dir|a b" \
    "testhost|\$(id)|job.sbatch" \
    "testhost||job.sbatch"; do
    IFS='|' read -r h d s <<< "$args"
    run_min "$h" "$d" "$s"
    check_eq "refused (exit 2): $args" 2 "$rc"
    check_eq "  no ssh call" 0 "$(count_calls ssh)"
    check_nofile "  nothing was executed" "$T/pwned"
  done
  run_min testhost "$dir" $'job.sbatch\nsbatch x'
  check_eq "newline in an argument: refused" 2 "$rc"
  check_eq "  no ssh call" 0 "$(count_calls ssh)"
}

test_minimal_rejects_malformed_sbatch_reply() {
  echo "minimal/submit-and-poll.sh does not poll with an unvalidated job id"
  new_sandbox
  mkdir -p "$T/remote/run1"
  cp "$T/pkg/job.sbatch" "$T/remote/run1/job.sbatch"
  set_states 1000 COMPLETED
  : > "$FAKE_ROOT/sbatch_garbage"
  run_min testhost "$T/remote/run1" job.sbatch
  check_eq "refused (exit 1)" 1 "$rc"
  check_contains "  says why" "$out" "did not return a job ID"
  check_eq "  no squeue call" 0 "$(count_calls squeue)"
  check_eq "  no sacct call" 0 "$(count_calls sacct)"
  check_nofile "  the reply was not executed" "$T/pwned"
}

# ------------------------------------------------------------------ interrupted submissions

break_state_file() { printf '%s\n' "$T/repo/state/jobs.log" > "$FAKE_ROOT/sbatch_break_state"; }
restore_state_file() {
  rmdir "$T/repo/state/jobs.log"
  mv "$T/repo/state/jobs.log.bak" "$T/repo/state/jobs.log"
  rm -f "$FAKE_ROOT/sbatch_break_state"
}
run3() { out=$("$T/repo/scripts/$1" "$2" "$3" "$4" 2>&1) && rc=0 || rc=$?; }

assert_blocked() {   # expected number of sbatch calls so far
  run1 submit.sh "$T/pkg"
  check_eq "  retry of submit: refused (exit 3)" 3 "$rc"
  check_contains "  explains the manual step" "$out" "poll.sh --reconcile"
  run1 resubmit.sh "$T/pkg"
  check_eq "  resubmit: refused (exit 3)" 3 "$rc"
  run1 poll.sh "$T/pkg"
  check_eq "  poll: exit 4, unresolved" 4 "$rc"
  check_eq "  no second sbatch call" "$1" "$(count_calls sbatch)"
}

test_lost_ack_blocks_package() {
  echo "a lost sbatch acknowledgement leaves the package blocked"
  new_sandbox
  echo sbatch > "$FAKE_ROOT/ssh_lose_ack"
  run1 submit.sh "$T/pkg"
  check_eq "submit: exit 4" 4 "$rc"
  check_contains "  says UNRESOLVED" "$out" "UNRESOLVED"
  check_contains "  tells where to look" "$out" "testhost"
  check_eq "  the scheduler did accept one job" 1 "$(count_calls sbatch)"
  check_eq "  a PENDING line was written first" 1 "$(count_log PENDING)"
  check_eq "  no SUBMIT line" 0 "$(count_log SUBMIT)"
  check_nofile "  lock released" "$T/repo/state/.lock"
  rm "$FAKE_ROOT/ssh_lose_ack"
  assert_blocked 1
  run2 submit.sh --dry-run "$T/pkg"
  check_eq "  submit --dry-run reports the block too" 3 "$rc"

  echo "a lost acknowledgement on resubmit blocks it and is not forgotten"
  submitted_sandbox
  set_states 1000 FAILED
  echo sbatch > "$FAKE_ROOT/ssh_lose_ack"
  run1 resubmit.sh "$T/pkg"
  check_eq "resubmit: exit 4" 4 "$rc"
  check_eq "  two sbatch calls so far" 2 "$(count_calls sbatch)"
  rm "$FAKE_ROOT/ssh_lose_ack"
  assert_blocked 2
  run3 poll.sh --reconcile 1001 "$T/pkg"
  check_eq "reconcile 1001: exit 0" 0 "$rc"
  check_contains "  recorded as a RESUBMIT of attempt 1" "$(grep RESUBMIT "$T/repo/state/jobs.log")" $'\t'"1001"$'\t'"1"$'\t'
  set_states 1001 FAILED
  run1 resubmit.sh "$T/pkg"
  check_contains "  the reconciled attempt counts: next is attempt 2 of 2" "$out" "attempt 2 of 2"
  set_states 1002 FAILED
  run1 resubmit.sh "$T/pkg"
  check_eq "  and the budget is then used up" 3 "$rc"
}

test_garbled_reply_blocks_package() {
  echo "an unreadable sbatch reply leaves the package blocked"
  new_sandbox
  : > "$FAKE_ROOT/sbatch_garbage"
  run1 submit.sh "$T/pkg"
  check_eq "submit: exit 4" 4 "$rc"
  check_contains "  says UNRESOLVED" "$out" "UNRESOLVED"
  rm "$FAKE_ROOT/sbatch_garbage"
  assert_blocked 1
}

test_local_write_failure_blocks_package() {
  echo "a failed local write after sbatch leaves the package blocked"
  new_sandbox
  break_state_file
  run1 submit.sh "$T/pkg"
  check_eq "submit: exit 4" 4 "$rc"
  check_contains "  says UNRESOLVED" "$out" "UNRESOLVED"
  check_contains "  names the accepted job" "$out" "job 1000 was accepted"
  restore_state_file
  check_eq "  PENDING survived in the log" 1 "$(count_log PENDING)"
  check_eq "  no SUBMIT line" 0 "$(count_log SUBMIT)"
  assert_blocked 1

  submitted_sandbox
  set_states 1000 FAILED
  break_state_file
  run1 resubmit.sh "$T/pkg"
  check_eq "resubmit: exit 4" 4 "$rc"
  check_contains "  names the accepted job" "$out" "job 1001 was accepted"
  restore_state_file
  assert_blocked 2

  new_sandbox
  mkdir -p "$T/repo/state/jobs.log"
  run1 submit.sh "$T/pkg"
  check_eq "an unwritable log stops before anything is submitted (exit 2)" 2 "$rc"
  check_eq "  no sbatch call" 0 "$(count_calls sbatch)"
}

test_reconcile() {
  echo "poll.sh --reconcile settles an unresolved submission"
  new_sandbox
  run3 poll.sh --reconcile none "$T/pkg"
  check_eq "nothing pending: refused (exit 3)" 3 "$rc"

  new_sandbox
  echo sbatch > "$FAKE_ROOT/ssh_lose_ack"
  run1 submit.sh "$T/pkg"
  rm "$FAKE_ROOT/ssh_lose_ack"
  run3 poll.sh --reconcile maybe "$T/pkg"
  check_eq "bad argument: exit 2" 2 "$rc"
  run3 poll.sh --reconcile "1000; id" "$T/pkg"
  check_eq "injection-style argument: exit 2" 2 "$rc"
  check_eq "  still blocked" 1 "$(count_log PENDING)"
  run3 poll.sh --reconcile 1000 "$T/pkg"
  check_eq "reconcile 1000: exit 0" 0 "$rc"
  check_contains "  recorded as a SUBMIT with its binding" "$(grep SUBMIT "$T/repo/state/jobs.log")" \
    $'\t'"1000"$'\t'"0"$'\t'"$T/pkg"$'\t'"testhost"$'\t'"$T/remote/run1"$'\t'"job.sbatch"
  set_states 1000 RUNNING
  run1 poll.sh "$T/pkg"
  check_eq "  poll now follows job 1000" 10 "$rc"
  run1 submit.sh "$T/pkg"
  check_eq "  and a new submit waits for it (exit 3)" 3 "$rc"
  check_eq "  no second sbatch" 1 "$(count_calls sbatch)"

  new_sandbox
  echo sbatch > "$FAKE_ROOT/ssh_lose_ack"
  run1 submit.sh "$T/pkg"
  rm "$FAKE_ROOT/ssh_lose_ack"
  run3 poll.sh --reconcile none "$T/pkg"
  check_eq "reconcile none: exit 0" 0 "$rc"
  check_eq "  RECONCILED line written" 1 "$(count_log RECONCILED)"
  run1 submit.sh "$T/pkg"
  check_eq "  submit is allowed again" 0 "$rc"
  check_contains "  the new job is 1001" "$out" "submitted job 1001"
}

# ------------------------------------------------------------------ recorded binding

test_binding_survives_config_change() {
  echo "resubmit and poll use the host, directory and script recorded with the job"
  new_sandbox
  mkdir -p "$T/pkgB"
  printf '#!/bin/bash\necho B\n' > "$T/pkgB/other.sbatch"
  run1 submit.sh "$T/pkg"
  check_eq "package A submitted (job 1000)" 0 "$rc"
  cat >> "$T/repo/config.env" <<EOF
HPC_HOST=otherhost
REMOTE_DIR=$T/remote/run2
JOB_SCRIPT=other.sbatch
EOF
  run1 submit.sh "$T/pkgB"
  check_contains "package B submitted with the new config (job 1001)" "$out" "submitted job 1001"
  local other_before
  other_before=$(count_calls "ssh otherhost")
  set_states 1000 FAILED
  run1 resubmit.sh "$T/pkg"
  check_eq "resubmit A: exit 0" 0 "$rc"
  check_contains "  mentions that config.env differs" "$out" "config.env differs"
  check_eq "  nothing was sent to B's host" "$other_before" "$(count_calls "ssh otherhost")"
  check_eq "  only B's own submit ran B's script" 1 "$(count_calls "sbatch other.sbatch")"
  check_eq "  A's script ran twice, from A's directory" 2 \
    "$(grep -c "^ssh testhost :: cd '$T/remote/run1' && sbatch --parsable 'job.sbatch'" "$FAKE_ROOT/calls.log")"
  check_contains "  RESUBMIT line carries A's binding" "$(grep RESUBMIT "$T/repo/state/jobs.log")" \
    $'\t'"$T/pkg"$'\t'"testhost"$'\t'"$T/remote/run1"$'\t'"job.sbatch"
  set_states 1002 RUNNING
  local before
  before=$(count_calls "ssh otherhost")
  run1 poll.sh "$T/pkg"
  check_eq "poll A: exit 10" 10 "$rc"
  check_eq "  asked A's host, not the configured one" "$before" "$(count_calls "ssh otherhost")"
  set_states 1001 RUNNING
  run1 poll.sh "$T/pkgB"
  check_eq "poll B: exit 10, asked B's host" 10 "$rc"
  check_eq "  one call to otherhost" $((before + 1)) "$(count_calls "ssh otherhost")"

  echo "a binding read back from the log is validated before any remote call"
  new_sandbox
  mkdir -p "$T/repo/state"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 2026-01-01T00:00:00Z SUBMIT 1000 0 "$T/pkg" \
    testhost "x'; touch $T/pwned; '" job.sbatch >> "$T/repo/state/jobs.log"
  run1 poll.sh "$T/pkg"
  check_eq "poll: exit 2" 2 "$rc"
  run1 resubmit.sh "$T/pkg"
  check_eq "resubmit: exit 2" 2 "$rc"
  check_eq "  no ssh call" 0 "$(count_calls ssh)"
  check_nofile "  nothing executed" "$T/pwned"
}

test_job_id_reused_on_another_cluster() {
  echo "a FINAL record for job 1000 on one cluster does not release job 1000 on another"
  new_sandbox
  mkdir -p "$T/pkgB"
  printf '#!/bin/bash\necho B\n' > "$T/pkgB/other.sbatch"
  run1 submit.sh "$T/pkg"
  check_eq "package A submitted as job 1000" 0 "$rc"
  set_states 1000 COMPLETED
  run1 poll.sh "$T/pkg"
  check_eq "A finished and recorded (exit 0)" 0 "$rc"
  printf 'HPC_HOST=otherhost\nREMOTE_DIR=%s\nJOB_SCRIPT=other.sbatch\n' "$T/remote/run2" >> "$T/repo/config.env"
  echo 1000 > "$FAKE_ROOT/next_jobid"
  run1 submit.sh "$T/pkgB"
  check_contains "package B also got job 1000, on the other cluster" "$out" "submitted job 1000"
  set_states 1000 RUNNING
  run1 submit.sh "$T/pkgB"
  check_eq "submitting B again is refused" 3 "$rc"
  check_eq "  only one sbatch of B's script" 1 "$(count_calls "sbatch other.sbatch")"
}

test_reused_job_id_needs_new_final() {
  echo "an old FINAL for job 1000 does not release a later submission that reused id 1000"
  submitted_sandbox
  set_states 1000 COMPLETED
  run1 poll.sh "$T/pkg"
  check_eq "first job finished (exit 0)" 0 "$rc"
  echo 1000 > "$FAKE_ROOT/next_jobid"
  run1 submit.sh "$T/pkg"
  check_contains "second submission reused id 1000" "$out" "submitted job 1000"
  set_states 1000 RUNNING
  run1 submit.sh "$T/pkg"
  check_eq "a third submit is refused while it runs" 3 "$rc"
  check_eq "  two sbatch calls in total" 2 "$(count_calls sbatch)"
}

test_slow_poll_does_not_release_newer_submission() {
  echo "a poll that started before a newer submission (same reused id) does not record FINAL for it"
  submitted_sandbox
  set_states 1000 COMPLETED
  local log="$T/repo/state/jobs.log" bind
  bind=$(grep $'\tSUBMIT\t' "$log" | cut -f5-8)
  # While this poll is in flight, another poll records FINAL and a new submission reuses 1000.
  printf 'printf "%%s\\tFINAL\\t1000\\tCOMPLETED\\t%%s\\n" 2099-01-01T00:00:00Z "%s" >> "%s"\nprintf "%%s\\tSUBMIT\\t1000\\t0\\t%%s\\n" 2099-01-01T00:00:01Z "%s" >> "%s"\n' \
    "$bind" "$log" "$bind" "$log" > "$FAKE_ROOT/ssh_hook_once"
  run1 poll.sh "$T/pkg"
  check_eq "the slow poll still reports COMPLETED (exit 0)" 0 "$rc"
  check_eq "  but adds no FINAL for the newer submission" 1 "$(count_log FINAL)"
  set_states 1000 RUNNING
  run1 submit.sh "$T/pkg"
  check_eq "a further submit is refused while the newer job runs" 3 "$rc"
}

# ------------------------------------------------------------------ scheduler errors

test_scheduler_errors_are_not_terminal() {
  echo "a failed squeue or sacct is unknown, never a finished job"
  submitted_sandbox
  set_states 1000 NODE_FAIL
  : > "$FAKE_ROOT/squeue_fail"
  run1 poll.sh "$T/pkg"
  check_eq "squeue fails, sacct says NODE_FAIL: exit 30" 30 "$rc"
  check_contains "  status=unknown" "$out" "status=unknown"
  check_eq "  no FINAL line" 0 "$(count_log FINAL)"
  run1 resubmit.sh "$T/pkg"
  check_eq "  resubmit refused (exit 3)" 3 "$rc"
  check_eq "  no second sbatch" 1 "$(count_calls sbatch)"
  check_eq "  still no FINAL line" 0 "$(count_log FINAL)"
  run1 submit.sh "$T/pkg"
  check_eq "  and a plain submit is still refused" 3 "$rc"
  run2 poll.sh --watch "$T/pkg"
  check_eq "  --watch keeps returning 30 (not terminal)" 30 "$rc"
  check_eq "  no FINAL line after watching" 0 "$(count_log FINAL)"

  submitted_sandbox
  set_states 1000 COMPLETED
  : > "$FAKE_ROOT/squeue_fail"
  run1 poll.sh "$T/pkg"
  check_eq "squeue fails, sacct says COMPLETED: exit 30" 30 "$rc"
  check_eq "  no FINAL line" 0 "$(count_log FINAL)"

  submitted_sandbox
  set_states 1000 FAILED
  : > "$FAKE_ROOT/sacct_fail"
  run1 poll.sh "$T/pkg"
  check_eq "job gone from the queue but sacct fails: exit 30" 30 "$rc"
  check_eq "  no FINAL line" 0 "$(count_log FINAL)"
  run1 resubmit.sh "$T/pkg"
  check_eq "  resubmit refused (exit 3)" 3 "$rc"

  submitted_sandbox
  set_states 1000 FAILED
  : > "$FAKE_ROOT/squeue_purged"
  run1 poll.sh "$T/pkg"
  check_eq "SLURM has forgotten the job (Invalid job id) and sacct says FAILED: exit 20" 20 "$rc"
  check_eq "  FINAL recorded" 1 "$(count_log FINAL)"
  run1 resubmit.sh "$T/pkg"
  check_eq "  resubmit works" 0 "$rc"
}

test_review_hardening() {
  echo "hardening: incomplete log line, mixed array states, named-cluster reconcile, minimal argc"
  submitted_sandbox
  set_states 1000 COMPLETED
  run1 poll.sh "$T/pkg"
  printf 'truncated' >> "$T/repo/state/jobs.log"
  run1 submit.sh "$T/pkg"
  check_eq "  submit refuses after an incomplete last log line (exit 2)" 2 "$rc"
  check_contains "  says why" "$out" "incomplete"
  check_eq "  still one sbatch call" 1 "$(count_calls sbatch)"

  submitted_sandbox
  set_states 1000 COMPLETED
  printf 'COMPLETED\nFAILED\n' > "$FAKE_ROOT/jobs/1000.rows"
  run1 poll.sh "$T/pkg"
  check_eq "  disagreeing accounting rows: exit 30" 30 "$rc"
  check_contains "  reported as MIXED" "$out" "state=MIXED"
  check_eq "  nothing recorded as FINAL" 0 "$(count_log FINAL)"

  new_sandbox
  : > "$FAKE_ROOT/sbatch_cluster_suffix"
  run1 submit.sh "$T/pkg"
  check_eq "  named-cluster reply: exit 4" 4 "$rc"
  run2 poll.sh --reconcile 1000 "$T/pkg" || true
  out=$("$T/repo/scripts/poll.sh" --reconcile 1000 "$T/pkg" 2>&1) && rc=0 || rc=$?
  check_eq "  --reconcile refuses a bare id for it (exit 3)" 3 "$rc"
  check_eq "  no SUBMIT line" 0 "$(count_log SUBMIT)"
  out=$("$T/repo/scripts/poll.sh" --reconcile none "$T/pkg" 2>&1) && rc=0 || rc=$?
  check_eq "  --reconcile none still works" 0 "$rc"

  out=$(bash "$SRC/minimal/submit-and-poll.sh" testhost runs/x 2>&1) && rc=0 || rc=$?
  check_eq "  minimal: wrong argument count exits 2" 2 "$rc"
}

test_submit_records_job
test_submit_refuses_cluster_suffix
test_submit_failure_records_nothing
test_duplicate_submit_refused
test_submit_allowed_after_final
test_submit_input_checks
test_config_validation
test_poll_exit_codes
test_poll_watch
test_resubmit_is_bounded
test_resubmit_refuses_ineligible
test_dry_run_executes_nothing
test_minimal_example
test_minimal_rejects_unsafe_arguments
test_minimal_rejects_malformed_sbatch_reply
test_lost_ack_blocks_package
test_garbled_reply_blocks_package
test_local_write_failure_blocks_package
test_reconcile
test_binding_survives_config_change
test_job_id_reused_on_another_cluster
test_reused_job_id_needs_new_final
test_slow_poll_does_not_release_newer_submission
test_scheduler_errors_are_not_terminal
test_review_hardening

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
