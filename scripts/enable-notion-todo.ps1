[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DataSourceId
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $repo 'config.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Config file was not found: $configPath"
}

$secureToken = Read-Host 'Paste the Notion integration token' -AsSecureString
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
try {
    $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    if (-not $token) {
        throw 'The Notion integration token is empty.'
    }
    [Environment]::SetEnvironmentVariable('NOTION_API_KEY', $token, 'User')
} finally {
    if ($pointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
    $token = $null
}

[Environment]::SetEnvironmentVariable(
    'NOTION_DATA_SOURCE_ID',
    $DataSourceId.Trim(),
    'User'
)

$config = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath | ConvertFrom-Json
if (-not $config.todo) {
    throw 'config.todo is missing. Update the project before enabling Notion.'
}
$config.todo.provider = 'notion'
$json = $config | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText(
    $configPath,
    $json + [Environment]::NewLine,
    (New-Object Text.UTF8Encoding($false))
)

Write-Output 'Notion todo is enabled for future dashboard updates.'
Write-Output 'Restart the scheduled task or sign out and back in so it receives the new user environment variables.'
