<#
.SYNOPSIS
    Runs the full chatapp AWS setup (00-account-bootstrap.sh through 10-grafana-ecs.sh) in order.

.DESCRIPTION
    This is a thin orchestrator, not a reimplementation: every AWS resource this project needs
    (VPC, IAM, ECR, Secrets Manager, S3, ECS cluster, ALB, task defs, services, ElastiCache,
    CloudWatch, Grafana) is already created and idempotently maintained by the numbered bash
    scripts in this directory. This script just runs them, in dependency order, via Git Bash -
    it does not duplicate their logic in PowerShell, so there's no risk of it drifting from what's
    actually running in production.

    Every one of those bash scripts is safe to re-run (each checks whether its resources already
    exist before creating them), so running this end-to-end against an account that already has
    everything provisioned is a no-op verification pass, not a rebuild.

    See README.md in this directory for the two Windows-specific gotchas this script also
    guards against: stray AWS_* environment variables that silently outrank the `default`
    profile, and MSYS2 path-mangling of leading-`/` CLI arguments (both are also handled inside
    each individual .sh script, as defense in depth).

.PARAMETER From
    Resume from the script whose filename starts with this prefix (e.g. "07" or "09b"), skipping
    everything before it. Useful after fixing a failure partway through.

.PARAMETER Only
    Run only the script(s) whose filename starts with this prefix, instead of the full sequence.

.PARAMETER DryRun
    Print the resolved script list and verify AWS identity, but don't execute anything.

.PARAMETER Force
    Skip the interactive "this touches real AWS resources, continue?" confirmation.

.EXAMPLE
    ./setup-all.ps1 -DryRun
    Preview what would run and confirm you're pointed at the right AWS account first.

.EXAMPLE
    ./setup-all.ps1
    Run the full setup, in order, with a confirmation prompt.

.EXAMPLE
    ./setup-all.ps1 -From 08
    Resume from 08-ecs-services.sh after an earlier failure was fixed.

.EXAMPLE
    ./setup-all.ps1 -Only 10
    Re-run just 10-grafana-ecs.sh.
#>

[CmdletBinding()]
param(
    [string]$From,
    [string]$Only,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Dependency order per README.md - do not reorder without checking each script's "Requires:" header.
$AllScripts = @(
    "00-account-bootstrap.sh",
    "01-vpc.sh",
    "02-security-groups.sh",
    "03-ecr.sh",
    "04-secrets.sh",
    "04b-s3-bucket.sh",
    "05-ecs-cluster.sh",
    "06-alb.sh",
    "07-task-defs.sh",
    "08-ecs-services.sh",
    "09-elasticache.sh",
    "09b-redis-deploy.sh",
    "09c-cloudwatch.sh",
    "10-grafana-ecs.sh"
)

$ExpectedAccountId = "788070448326"
$ExpectedUser = "ankitexp"

function Find-GitBash {
    # On a machine with WSL installed, plain `bash.exe` on PATH resolves to a launcher stub
    # under System32 or WindowsApps - not Git Bash - and fails with a confusing
    # "execvpe(/bin/bash) failed" error if no WSL distro is registered. Confirmed on this
    # machine: Git isn't even under Program Files here (it's at C:\DataScience\Software\Git),
    # so hardcoded paths alone aren't reliable either. Instead, derive bash.exe from wherever
    # git.exe actually is (portable across machines/install locations), then fall back to
    # common paths, then to a PATH search that explicitly excludes the known WSL-stub locations.

    $gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($gitCmd) {
        # Git-for-Windows layout: <root>\cmd\git.exe (or <root>\mingw64\bin\git.exe) alongside
        # <root>\bin\bash.exe.
        $root = (Get-Item $gitCmd.Source).Directory.Parent.FullName
        $candidate = Join-Path $root "bin\bash.exe"
        if (Test-Path $candidate) { return $candidate }
    }

    $commonPaths = @(
        "C:\Program Files\Git\bin\bash.exe",
        "C:\Program Files (x86)\Git\bin\bash.exe"
    )
    foreach ($p in $commonPaths) {
        if (Test-Path $p) { return $p }
    }

    # Fall back to PATH, but skip the WSL launcher stubs (System32 and the per-user WindowsApps
    # app-execution-alias) rather than the real thing.
    $onPath = Get-Command bash.exe -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notmatch '\\System32\\' -and $_.Source -notmatch '\\WindowsApps\\' }
    if ($onPath) { return $onPath[0].Source }

    throw "Git Bash (bash.exe) not found on PATH or in the usual install locations. Install Git for Windows: https://git-scm.com/download/win"
}

$Bash = Find-GitBash
Write-Host "Using bash: $Bash" -ForegroundColor DarkGray

# --- Resolve which scripts to run -------------------------------------------------------------

$scripts = $AllScripts

if ($Only) {
    $scripts = $AllScripts | Where-Object { $_ -like "$Only*" }
    if (-not $scripts) {
        Write-Error "No script matches -Only '$Only'. Available: $($AllScripts -join ', ')"
        exit 1
    }
} elseif ($From) {
    $match = $AllScripts | Where-Object { $_ -like "$From*" } | Select-Object -First 1
    if (-not $match) {
        Write-Error "No script matches -From '$From'. Available: $($AllScripts -join ', ')"
        exit 1
    }
    $idx = [array]::IndexOf($AllScripts, $match)
    $scripts = $AllScripts[$idx..($AllScripts.Count - 1)]
}

Write-Host ""
Write-Host "== chatapp AWS setup ==" -ForegroundColor Cyan
Write-Host "Scripts to run ($($scripts.Count)):"
$scripts | ForEach-Object { Write-Host "  - $_" }
Write-Host ""

# --- Verify AWS identity before touching anything stateful -------------------------------------
# Stray AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY env vars on this machine outrank the `default`
# profile with no CLI flag able to override that - see README.md. Unset them inside the bash
# subshell before checking identity, exactly like every script in this directory already does.

Write-Host "== Verifying AWS identity ==" -ForegroundColor Cyan
$identityLines = & $Bash -c "unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; aws sts get-caller-identity" 2>&1
Write-Host ($identityLines -join "`n")

if ($LASTEXITCODE -ne 0) {
    Write-Error "Could not verify AWS identity (aws sts get-caller-identity failed). Is the AWS CLI installed and the 'default' profile configured?"
    exit 1
}
# -match/-notmatch on a multi-line array does element-wise filtering, not a single boolean -
# join into one string first so this is a real true/false check.
$identityText = $identityLines -join "`n"
if ($identityText -notmatch [regex]::Escape($ExpectedAccountId) -or $identityText -notmatch $ExpectedUser) {
    Write-Error "Unexpected AWS identity. Expected account $ExpectedAccountId, user $ExpectedUser. Refusing to run provisioning scripts against the wrong account. Output above."
    exit 1
}
Write-Host "Identity OK: account $ExpectedAccountId, user $ExpectedUser." -ForegroundColor Green
Write-Host ""

if ($DryRun) {
    Write-Host "-DryRun set: nothing executed." -ForegroundColor Yellow
    exit 0
}

if (-not $Force) {
    $confirmation = Read-Host "This will create/update real AWS resources (billed) in account $ExpectedAccountId. Continue? [y/N]"
    if ($confirmation -notmatch '^[Yy]') {
        Write-Host "Aborted."
        exit 0
    }
}

# --- Run each script in order -------------------------------------------------------------------

foreach ($script in $scripts) {
    $scriptPath = Join-Path $PSScriptRoot $script
    if (-not (Test-Path $scriptPath)) {
        Write-Error "Script not found: $scriptPath"
        exit 1
    }

    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host "== Running $script" -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor Cyan

    & $Bash $scriptPath
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        Write-Host ""
        Write-Error "$script failed (exit code $exitCode)."
        Write-Host "Fix the error, then resume with:  ./setup-all.ps1 -From $script -Force" -ForegroundColor Yellow
        exit $exitCode
    }
}

Write-Host ""
Write-Host "All $($scripts.Count) scripts completed successfully." -ForegroundColor Green
