$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repo

& npm.cmd run collect
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& npm.cmd run build
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Only publish the generated static site. config.json and state/ remain ignored.
& git add --force dist
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& git diff --cached --quiet
if ($LASTEXITCODE -eq 0) {
  Write-Output 'No dashboard data changes.'
  exit 0
}

& git commit -m 'Update dashboard data'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& git push origin main
exit $LASTEXITCODE
