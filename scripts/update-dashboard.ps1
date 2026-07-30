[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $repo 'logs'
$logFile = Join-Path $logDir 'update-dashboard.log'
$mutex = $null
$mutexOwned = $false

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Write-Log {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $line | Tee-Object -FilePath $logFile -Append | Write-Host
}

function Resolve-Executable {
    param(
        [string]$Name,
        [string[]]$Candidates
    )
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    throw "Required executable was not found: $Name"
}

function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [switch]$AllowFailure
    )
    Write-Log ('Run: {0} {1}' -f $FilePath, ($Arguments -join ' '))
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    foreach ($line in $output) {
        Write-Log ([string]$line)
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Command failed with exit code ${exitCode}: $FilePath"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\KindleAiQuotaDashboardUpdate')
    try {
        $mutexOwned = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $mutexOwned = $true
    }
    if (-not $mutexOwned) {
        Write-Log 'Another update is already running; skipping this run.'
        exit 0
    }

    $node = Resolve-Executable 'node.exe' @(
        'C:\Program Files\nodejs\node.exe',
        'C:\Program Files (x86)\nodejs\node.exe'
    )
    $npm = Resolve-Executable 'npm.cmd' @(
        'C:\Program Files\nodejs\npm.cmd',
        'C:\Program Files (x86)\nodejs\npm.cmd'
    )
    $git = Resolve-Executable 'git.exe' @(
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files\Git\bin\git.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe'),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd\git.exe')
    )
    $codex = Resolve-Executable 'codex.cmd' @(
        (Join-Path $env:APPDATA 'npm\codex.cmd')
    )

    $toolDirs = @(
        (Split-Path -Parent $node),
        (Split-Path -Parent $npm),
        (Split-Path -Parent $git),
        (Split-Path -Parent $codex)
    )
    $env:PATH = (@($toolDirs) + @($env:PATH -split ';') |
        Where-Object { $_ } |
        Select-Object -Unique) -join ';'

    Set-Location -LiteralPath $repo
    Write-Log 'Starting Kindle AI quota dashboard update.'

    $dirty = Invoke-External $git @('status', '--porcelain', '--untracked-files=no')
    if ($dirty.Output.Count -gt 0) {
        throw 'Tracked files have uncommitted changes. Update stopped to protect local work.'
    }

    Invoke-External $git @('fetch', 'origin', 'main') | Out-Null
    $countsResult = Invoke-External $git @('rev-list', '--left-right', '--count', 'HEAD...origin/main')
    $counts = ([string]$countsResult.Output[-1]).Trim() -split '\s+'
    if ($counts.Count -ge 2 -and [int]$counts[1] -gt 0) {
        Write-Log 'Remote main has new commits; rebasing local commits first.'
        Invoke-External $git @('rebase', 'origin/main') | Out-Null
    }

    Invoke-External $npm @('run', 'collect') | Out-Null
    Invoke-External $npm @('run', 'build') | Out-Null
    Invoke-External $git @('add', '--force', 'dist') | Out-Null

    $diff = Invoke-External $git @('diff', '--cached', '--quiet') -AllowFailure
    if ($diff.ExitCode -eq 1) {
        Invoke-External $git @('commit', '-m', 'Update dashboard data') | Out-Null
    } elseif ($diff.ExitCode -ne 0) {
        throw 'Unable to inspect staged dashboard changes.'
    } else {
        Write-Log 'Collected data is unchanged; no data commit is needed.'
    }

    $pushed = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $push = Invoke-External $git @('push', 'origin', 'HEAD:main') -AllowFailure
        if ($push.ExitCode -eq 0) {
            $pushed = $true
            break
        }
        if ($attempt -lt 3) {
            Write-Log "Push attempt $attempt failed; synchronizing remote main before retry."
            Invoke-External $git @('fetch', 'origin', 'main') | Out-Null
            Invoke-External $git @('rebase', 'origin/main') | Out-Null
        }
    }
    if (-not $pushed) {
        throw 'Push failed after three attempts. See the update log for details.'
    }

    Write-Log 'Update completed and pushed to GitHub.'
    exit 0
} catch {
    Write-Log ('Update failed: ' + $_.Exception.Message)
    exit 1
} finally {
    if ($mutexOwned -and $mutex) {
        try { $mutex.ReleaseMutex() } catch {}
    }
    if ($mutex) {
        $mutex.Dispose()
    }
}
