# agentic-hpc-scripts

A small, readable set of Bash scripts for running a prepared SLURM job on an HPC
cluster over SSH, with status polling and a bounded number of automatic resubmissions.

The idea is agent-assisted HPC done sanely:

1. **You** prepare the job package locally: inputs, a job script, nothing secret.
2. **You** read and approve these scripts, and set up your own SSH alias and keys.
3. **You** give an agent (if you use one) permission to run *only these scripts*, not a
   general shell on the cluster, ideally pinned to the package directories you approved
   (see Safety notes); `poll.sh --reconcile` stays with you.
4. Submitting, polling and a limited amount of resubmission can then run while you
   sleep. Auto-polling is optional: you can equally run `poll.sh` by hand.

These scripts are meant to be read before use; they are short on purpose.

They accompany the talk *Agents for computational research*; the setup guide is at
<https://comphy-lab.org/agents-in-research/>. `minimal/submit-and-poll.sh` is the
slide version; `scripts/` is the full version it summarises.

## Layout

| Path | Purpose |
| --- | --- |
| `config.example.env` | Template for your own `config.env` (git-ignored) |
| `scripts/submit.sh` | Copy the package to the cluster, `sbatch` it, record the job ID |
| `scripts/poll.sh` | One-line status for the recorded job; optional `--watch` loop; `--reconcile` for an unresolved submission |
| `scripts/resubmit.sh` | Bounded resubmission after FAILED, TIMEOUT or NODE_FAIL |
| `scripts/lib.sh` | Shared helpers (config parsing, state file, remote calls) |
| `minimal/` | A teaching version (13 lines of code) that fits on a slide |
| `example/job.sbatch` | Generic job template with placeholder values |
| `tests/run.sh` | Offline tests using fake `ssh`, `rsync`, `sbatch`, `squeue`, `sacct` |
| `state/jobs.log` | Local job history, created on first submit (git-ignored) |

## Quick start

```bash
# 1. One-time: define an SSH alias in ~/.ssh/config (HostName, User, IdentityFile) and
#    check that `ssh <alias> true` works without a password prompt.

# 2. Configure.
cp config.example.env config.env
$EDITOR config.env                 # HPC_HOST, REMOTE_DIR, JOB_SCRIPT, limits

# 3. Prepare a package directory containing your job script. example/ is a template:
#    fill in its placeholders and your site's account/partition lines first.

# 4. Look before you leap.
scripts/submit.sh --dry-run example

# 5. Submit, then check on it.
scripts/submit.sh example
scripts/poll.sh example            # one status line, see exit codes below
scripts/poll.sh --watch example    # optional: wait until it ends (bounded)

# 6. If it failed or timed out, resubmit (bounded by MAX_RESUBMITS).
scripts/resubmit.sh --dry-run example
scripts/resubmit.sh example
```

## Configuration

`config.env` holds plain `KEY=VALUE` lines. It is parsed, never executed, and every
value is checked against a conservative character set before any remote call.

| Key | Default | Meaning |
| --- | --- | --- |
| `HPC_HOST` | (required) | SSH alias from your `~/.ssh/config`; one hop only |
| `REMOTE_DIR` | (required) | Directory on the cluster for this package (use one per package) |
| `JOB_SCRIPT` | (required) | Job script, relative to the package's top level |
| `MAX_RESUBMITS` | 2 | Resubmissions allowed per fresh submit (hard cap 10; 0 disables) |
| `POLL_INTERVAL` | 300 | Seconds between checks in `--watch` (minimum 60) |
| `MAX_POLL_HOURS` | 24 | `--watch` gives up after this long (0 = check once) |

## What the scripts do

**`submit.sh [--dry-run] PACKAGE_DIR`** copies the package with `rsync --checksum` (no `--delete`,
`.git/` excluded), runs `sbatch --parsable` in `REMOTE_DIR`, and appends the job ID to
`state/jobs.log`. It refuses (exit 3) while the log shows an unfinished job for the same
package, so there are never two live jobs for one package. A job counts as finished once
`poll.sh` has seen it end and recorded that; if you cancelled it by hand, run `poll.sh`
once, then submit.

Before `sbatch` runs, `submit.sh` writes a `PENDING` line to the log (package, attempt
number, time, host, directory, script). The `SUBMIT` line with the job ID completes it.
If anything goes wrong in between (the reply is lost, `ssh` exits non-zero, the reply is
not a job ID, or the log cannot be written), the scheduler may have accepted a job that
the log does not know about. The script then exits 4 with `UNRESOLVED` and the package
stays blocked: `submit.sh` and `resubmit.sh` refuse (exit 3) and `poll.sh` exits 4 until
you reconcile it (see below). Nothing is ever resubmitted on a guess.

**`poll.sh [--watch] PACKAGE_DIR`** asks the cluster about the latest recorded job
(`squeue` while it is queued or running, then `sacct`) and prints one line such as
`2026-01-01T12:00:00Z job=1000 state=RUNNING status=running`.

| Exit | Meaning |
| --- | --- |
| 0 | completed |
| 10 | pending or running |
| 20 | failed, timed out, cancelled (also out of memory, node failure) |
| 30 | unknown: job not visible, the SSH connection failed, `squeue`/`sacct` itself failed, or a job array's rows disagree (`MIXED`) |
| 4 | unresolved submission: a job may exist that is not in the log |
| 2 | usage or configuration error |

A dropped connection or a failing `squeue`/`sacct` is reported as 30, never as a failure
or as a finished job, so it can never trigger a resubmission. Only a clean answer counts:
`squeue` listing the job, or `squeue` saying the job id is unknown (SLURM forgets old
jobs) followed by a state from `sacct`.

**`resubmit.sh [--dry-run] PACKAGE_DIR`** asks the cluster again (it does not trust old
state) and resubmits the existing remote copy only if the job is `FAILED`, `TIMEOUT` or
`NODE_FAIL` *and* fewer than `MAX_RESUBMITS` resubmissions have been used since the last
fresh submit. Completed, pending, running, cancelled, out-of-memory and unknown jobs are
never resubmitted. Exit 3 means it refused on purpose. Your job script must be safe to
run again in the same directory (resume from checkpoints or skip finished work).

Each job record stores the host, directory and script it was submitted with. `poll.sh`
and `resubmit.sh` use those stored values, not the current `config.env`, so after you
edit `config.env` for another package an old failed job is still resubmitted from its own
directory with its own script (a note says when the two differ). Values read back from
the log pass the same character checks as `config.env` before any remote call.

### Reconciling an unresolved submission

When a script exits 4 (or later refuses with `UNRESOLVED`), it prints where to look. By hand:

1. On the cluster, find out whether a job was created from that directory and script at
   or after the time shown: `squeue -u "$USER"` and
   `sacct -X -S <time> -o JobID,JobName,Submit,State`.
2. Tell the log what you found:

```bash
scripts/poll.sh --reconcile 12345 PACKAGE_DIR    # a job exists: record it as the submission
scripts/poll.sh --reconcile none  PACKAGE_DIR    # no job was created: unblock the package
```

`--reconcile JOBID` records the job exactly as a normal `SUBMIT` or `RESUBMIT` (so the
resubmit count is right) and `poll.sh` follows it from then on. If, against expectation,
two jobs exist, cancel the extra one yourself; the scripts never run `scancel`.
`--reconcile` contacts nothing: it only writes `state/jobs.log`.

`--dry-run` on `submit.sh` and `resubmit.sh` prints the commands without running them.
`submit.sh --dry-run` contacts nothing and writes nothing. `resubmit.sh --dry-run` checks
the local state (job exists, budget left) but does not ask the cluster.

### State file

`state/jobs.log` is append-only and tab-separated: UTC time, event, job ID, detail,
absolute package path, and for `PENDING`, `SUBMIT`, `RESUBMIT` and `FINAL` also host,
remote directory and job script. A job counts as finished only when a `FINAL` line matches
its job ID, package and host and comes after that package's latest submission, because job
IDs repeat across clusters and are reused over time. A `JOBID;cluster` reply from `sbatch`
(a multi-cluster site) is treated as unresolved: these scripts support single-cluster sites.

| Event | Job ID | Detail |
| --- | --- | --- |
| `PENDING` | `-` | attempt number (0 = fresh submit), written before `sbatch` runs |
| `SUBMIT` | the job | `0` |
| `RESUBMIT` | the job | attempt number |
| `FINAL` | the job | final SLURM state |
| `RECONCILED` | `-` | `none`: a human confirmed no job was created |

A `PENDING` line with no later `SUBMIT`, `RESUBMIT` or `RECONCILED` for the same package
is the unresolved marker. The log is the only memory the scripts have, so keep it with
your package, and read it with `cat` if you want to know what happened.

## Safety notes

- One SSH alias, no `ProxyJump` or multi-hop logic, and `BatchMode=yes`: if keys are not
  set up, ssh fails instead of asking for a password. No passwords or keys appear in any file.
- Nothing is installed or changed on the cluster beyond the files in `REMOTE_DIR`, and
  the scripts never cancel (`scancel`) or delete anything.
- Config values (and the values stored in the log) are validated (no spaces, quotes, `;`,
  `..`, or leading dashes) because they are placed in remote shell commands.
- An interrupted submission is never guessed at: it blocks the package until a human
  reconciles it, so a retry cannot create a duplicate live job.
- Resubmission is bounded and conservative. Anything that is not clearly a failure waits
  for a human.
- Site-specific settings (account, partition, modules) belong in your job script, not here.
  Respect your cluster's usage policy; if it forbids unattended automation, use these
  scripts by hand.
- Giving an agent permission to run these scripts is a decision about what it may do on
  the cluster. `submit.sh` submits whatever package directory it is given, so keep
  packages somewhere only you write to and check what is in them before allowing it.
  `poll.sh --reconcile` is the human step after an unresolved submission: keep it for
  yourself rather than allowing it to the agent.
- Give each package its own `REMOTE_DIR`; two packages pointing at the same directory
  would overwrite each other's inputs.
- Jobs are looked up by numeric ID on one cluster. Multi-cluster replies (`ID;cluster`)
  are refused, and `--reconcile` will not adopt a bare ID for such an attempt. These
  scripts are not designed for multi-cluster sites: if a reply was lost there, settle it
  by hand on the cluster. Job arrays and heterogeneous jobs whose accounting rows disagree are
  reported as `MIXED` (exit 30) and left for a human.
- `ConnectTimeout` bounds the SSH connection, not a scheduler command that hangs after
  connecting. If `squeue` or `sacct` hangs at your site, stop the script and check by hand.
- The state log is append-only plain text. If its last line is ever incomplete (for
  example after a full disk), the scripts refuse to write until you repair it.

## Tests and shellcheck

```bash
bash tests/run.sh                  # offline; fake commands, nothing leaves your machine
shellcheck -x scripts/*.sh minimal/submit-and-poll.sh tests/run.sh tests/stubs/* example/job.sbatch
```

The tests put fake `ssh`, `rsync`, `sbatch`, `squeue`, `sacct` and `sleep` first on
`PATH` and cover: recording a submit, refusing a duplicate, every poll exit code,
bounded `--watch`, bounded resubmission, refusal of completed and running jobs,
`--dry-run`, config validation, interrupted submissions (lost reply, unreadable reply,
failed log write) and `--reconcile`, the recorded host/directory/script, failing
`squeue`/`sacct`, and the minimal example including its argument checks. They need
Bash 3.2 or newer.

## Status

A teaching and demonstration tool, not a workflow manager. Read it, adapt it, and
test it on a small job before trusting it with a long one.

## Licence

MIT; see [LICENSE](LICENSE).
