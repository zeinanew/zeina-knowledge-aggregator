# Fallback equivalent of the Azure Pipelines refresh job (azure-pipelines.yml is now the primary
# daily scheduler - see ARCHITECTURE.md) - runs collect.py, then commits and pushes data/ if
# anything changed. Runs via Task Scheduler's at-logon trigger only (no daily trigger - that would
# race with Azure Pipelines' identical daily cron, which is exactly the two-schedulers-at-once
# problem that used to cause unresolvable data/*.json merge conflicts). The same-day guard below
# means this is a no-op on every normal day where Azure already pushed; it only does real work on
# a day Azure's pipeline itself failed to run. Can also be run manually (Task Scheduler ->
# right-click -> Run) - either way, progress streams to both the console and refresh-local.log, so
# a manual run doesn't look like it's doing nothing while it's actually working (a slow run is
# usually the Gemini API having a rough day - see the log for the actual reason, not a hang).
#
# Needs GEMINI_API_KEY / GROQ_API_KEY set as permanent (User or System) environment variables -
# Task Scheduler doesn't inherit a terminal session's env vars, only ones set that way.

$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$log = Join-Path $repo "refresh-local.log"
"=== $(Get-Date -Format o) ===" | Tee-Object -FilePath $log -Append

# Pull BEFORE collecting, not just after - most of the "merge conflict" incidents on this project
# were never a true same-instant race, just two runs (the 8am scheduled one and a manual one)
# starting from different stale snapshots and each computing their own "new items" diff against
# that stale base. Starting from the latest data means collect.py's own id/title dedup already
# treats whatever the other run added as "not new", so there's nothing left to conflict over.
git pull --rebase --autostash 2>&1 | Tee-Object -FilePath $log -Append

# The at-logon trigger exists to catch a missed 8am run (machine off, or still locked), not to
# re-run on every logon/unlock of the day. If today's refresh already landed - from this machine
# or from the cloud workflows - skip without touching the Gemini/Groq APIs again.
$today = Get-Date -Format yyyy-MM-dd
$lastSubject = git log -1 --pretty=%s
if ($lastSubject -like "Refresh feed $today*") {
    "Already refreshed today ($lastSubject) - skipping." | Tee-Object -FilePath $log -Append
    exit 0
}

python scripts/collect.py 2>&1 | Tee-Object -FilePath $log -Append

git add data
git diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    git commit -m "Refresh feed $(Get-Date -Format yyyy-MM-dd) (local)" 2>&1 | Tee-Object -FilePath $log -Append
    $localCommit = git rev-parse HEAD

    # A real same-instant race is still possible (collect.py itself takes a few minutes) - if the
    # pull below conflicts, resolve data/*.json in favor of this run's just-generated snapshot
    # (a JSON snapshot doesn't line-merge anyway) instead of leaving the repo mid-rebase for a
    # human to fix by hand every time.
    $env:GIT_EDITOR = "true"
    git pull --rebase --autostash 2>&1 | Tee-Object -FilePath $log -Append
    if ($LASTEXITCODE -ne 0) {
        "Pull conflicted - keeping this run's data/ snapshot and continuing the rebase" | Tee-Object -FilePath $log -Append
        git diff --name-only --diff-filter=U | Where-Object { $_ -like "data/*" } | ForEach-Object {
            git checkout $localCommit -- $_
            git add $_
        }
        git rebase --continue 2>&1 | Tee-Object -FilePath $log -Append
    }

    git push 2>&1 | Tee-Object -FilePath $log -Append
    "Committed and pushed new data." | Tee-Object -FilePath $log -Append
} else {
    "No new data to commit." | Tee-Object -FilePath $log -Append
}
