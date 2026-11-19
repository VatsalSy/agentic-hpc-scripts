#!/bin/bash
# Generic SLURM job template. Every value below is a placeholder (deliberately not a
# valid value, so an unedited copy fails loudly instead of running something odd).
#
# Fill in the site-specific parts yourself: the account/project, the partition or
# queue, any QOS, memory rules and software modules differ per cluster. Look them up
# in your site's documentation and add the matching #SBATCH lines, for example
# --account=... and --partition=... .
#
#SBATCH --job-name=REPLACE_ME
#SBATCH --time=HH:MM:SS
#SBATCH --nodes=N
#SBATCH --ntasks=N
#SBATCH --cpus-per-task=N
#SBATCH --mem=REPLACE_ME
#SBATCH --output=slurm-%j.out
#SBATCH --error=slurm-%j.err

set -euo pipefail

# Resubmission runs this script again in the same directory. Make it restart-safe:
# resume from checkpoints or skip work that is already finished.

cd "${SLURM_SUBMIT_DIR:-.}"
echo "job ${SLURM_JOB_ID:-unknown} started on $(hostname) at $(date)"

# module load <the modules your site provides>

# Replace with your real command, for example:
# srun ./my_program input.dat
echo "replace this line with your program" >&2
exit 1
