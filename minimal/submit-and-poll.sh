#!/usr/bin/env bash
# submit-and-poll.sh - teaching example: submit one SLURM job over SSH, then wait for it.
# Usage: ./submit-and-poll.sh SSH_ALIAS REMOTE_DIR JOB_SCRIPT
#   SSH_ALIAS   a Host entry you defined in ~/.ssh/config (keys or agent, no passwords)
#   REMOTE_DIR  directory on the cluster that already holds your prepared package
# shellcheck disable=SC2029  # the variables are meant to expand here, before ssh sends the command
set -euo pipefail
[ $# -eq 3 ] || { echo "usage: $0 SSH_ALIAS REMOTE_DIR JOB_SCRIPT" >&2; exit 2; }; host=$1; dir=$2; script=$3

# 0. The three arguments are pasted into remote commands, so allow only plain characters.
name='^[A-Za-z0-9][A-Za-z0-9._-]*$'; path='^[A-Za-z0-9._/][A-Za-z0-9._/-]*$'
[[ $host =~ $name && $script =~ $name && $dir =~ $path && $dir$script != *..* ]] \
  || { echo "refused: unsafe argument" >&2; exit 2; }

# 1. Submit from inside the package directory; --parsable makes sbatch print only the job ID.
id=$(ssh "$host" "cd '$dir' && sbatch --parsable '$script'")
[[ $id =~ ^[0-9]+$ ]] || { echo "refused: sbatch did not return a job ID" >&2; exit 1; }
echo "submitted job $id"

# 2. Poll. squeue lists the job only while it is pending or running.
for _ in $(seq 288); do                      # give up after 288 x 5 min = 24 h
  [ -n "$(ssh "$host" "squeue -h -j $id")" ] || break
  sleep 300
done

# 3. Ask the accounting database how the job ended (COMPLETED, FAILED, TIMEOUT, ...).
ssh "$host" "sacct -n -X -j $id -o JobID,State,Elapsed"
