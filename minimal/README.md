# Minimal example

`submit-and-poll.sh` is a **teaching example**, short enough to read on one slide:
check the arguments, ssh to an alias, `sbatch`, then poll with `sleep`, then ask `sacct`
how it ended.

```bash
./submit-and-poll.sh my-cluster runs/my-run job.sbatch
```

The three arguments are pasted into remote commands, so the script first refuses (exit 2,
before any ssh call) anything but plain characters: letters, digits, `.`, `_` and `-` for
the alias and the script name, plus `/` for the directory, no `..`, and no leading dash
on the alias or the script. It also refuses (exit 1) an `sbatch` reply that is not a bare
job ID before using it in the polling commands. (A site whose `--parsable` output adds
`;cluster` is refused too, as in the full scripts, which support single-cluster sites only.)

It deliberately leaves out everything the scripts in [`../scripts`](../scripts) add:

- no record of what was submitted, so nothing stops you from submitting twice, and a
  submission whose reply is lost is invisible (the full scripts write a `PENDING` record
  first and block the package until you reconcile it);
- no resubmission, and no distinction between a failed job and a failed connection
  (a dropped ssh call looks like "the job has left the queue");
- no copying of the package: it must already be on the cluster.

Use it to understand the moving parts; use the full scripts for anything you leave
running unattended.
