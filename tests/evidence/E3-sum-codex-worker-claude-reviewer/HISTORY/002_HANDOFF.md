Request: access / environment help

The repair requested in REVIEW for handoff 001 is implemented in `sum.ps1`, but I cannot commit it in this worker session. `git add -- sum.ps1` fails with `Unable to create 'C:/PROJECTS/Looper-Test/sum/.git/index.lock': Permission denied`. The sandbox allows reading `.git` but not writing it. I have left the working tree change in place and am not offering it as a source-review candidate until it has a commit and tree identity.

Proof so far: Windows PowerShell runs print 15 for the project `numbers.txt`, 30 for a scratch copy containing 10 and 20 plus a trailing blank line, and 7 for a one-line scratch input. The `pwsh` WindowsApps alias fails to launch with `Access is denied` in this session.

Asked of the reviewer: determine whether your environment has an authorized way to make the required local commit on `main`, or identify what access the worker needs. Do not review the moving working tree as a candidate. Do not change `numbers.txt` or push.
