# Instala ou atualiza o Lemon Chat sem abrir janela.
# Uso: irm https://raw.githubusercontent.com/waldyrlimaverde/lemon-chat-releases/main/update.ps1 | iex
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\lemon_labs\lemon_chat\agent'
$Repo = 'waldyrlimaverde/lemon-chat-releases'
$ZipName = 'LemonChat-win.zip'
$TaskName = 'LemonChat'
$UpdateTaskName = 'LemonChatUpdate'
$UpdateScriptUrl = 'https://raw.githubusercontent.com/waldyrlimaverde/lemon-chat-releases/main/update.ps1'
$LogFile = Join-Path $Root 'logs\update.log'

function Write-UpdateLog([string]$Message) {
  New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function ConvertTo-VersionParts([string]$Version) {
  $parts = @()
  foreach ($chunk in ([string]$Version -split '\.')) {
    $digits = [regex]::Match($chunk, '^\d+').Value
    if (-not $digits) { break }
    $parts += [int]$digits
  }
  return $parts
}

function Test-IsNewer([string]$Latest, [string]$Current) {
  if ([string]::IsNullOrWhiteSpace($Latest)) { return $false }
  if ([string]::IsNullOrWhiteSpace($Current)) { return $true }
  $left = ConvertTo-VersionParts $Latest
  $right = ConvertTo-VersionParts $Current
  $len = [Math]::Max($left.Count, $right.Count)
  for ($i = 0; $i -lt $len; $i++) {
    $a = 0
    $b = 0
    if ($i -lt $left.Count) { $a = $left[$i] }
    if ($i -lt $right.Count) { $b = $right[$i] }
    if ($a -gt $b) { return $true }
    if ($a -lt $b) { return $false }
  }
  return $false
}

function Get-LocalVersion {
  $file = Join-Path $Root 'VERSION'
  if (-not (Test-Path $file)) { return '' }
  return (Get-Content -Path $file -Raw -Encoding UTF8).Trim()
}

function Get-AgentRelease {
  $headers = @{
    'User-Agent' = 'LemonChat'
    'Accept'     = 'application/vnd.github+json'
  }
  $releases = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases?per_page=30"
  $best = $null
  $bestVersion = ''
  foreach ($release in @($releases)) {
    $tag = [string]$release.tag_name
    if ($tag -notlike 'agent-v*') { continue }
    $version = $tag -replace '^agent-v', ''
    if (-not $best -or (Test-IsNewer $version $bestVersion)) {
      $best = $release
      $bestVersion = $version
    }
  }
  if (-not $best) { throw 'Nenhum release agent-v encontrado no GitHub.' }
  return $best
}

function Invoke-NativeQuiet {
  param(
    [Parameter(Mandatory = $true)][string]$File,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgumentList
  )
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $File @ArgumentList *> $null
    return $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previous
  }
}

function Stop-PidTree($ProcId) {
  if (-not $ProcId) { return }
  Invoke-NativeQuiet taskkill.exe /PID $ProcId /T /F | Out-Null
}

function Test-LemonLockProcess {
  param(
    [int]$ProcessId,
    [int]$SelfPid,
    [string]$Name,
    [string]$ExecutablePath,
    [string]$CommandLine,
    [string]$AppDir
  )
  if ($ProcessId -le 0 -or $ProcessId -eq $SelfPid) { return $false }
  $prefix = ''
  if (-not [string]::IsNullOrWhiteSpace($AppDir)) {
    $prefix = $AppDir.TrimEnd('\') + '\'
  }
  $exe = [string]$ExecutablePath
  $cmd = [string]$CommandLine
  # A bandeja (sem --worker) e os processos do Chromium mapeiam locales\pt-BR.pak.
  if ($prefix) {
    if ($exe.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($cmd.IndexOf($prefix, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
  }
  if ($Name -eq 'Lemon Chat.exe' -and [string]::IsNullOrWhiteSpace($exe)) { return $true }
  if ($cmd -like '*run-agent.ps1*') { return $true }
  return $false
}

function Get-LemonLockProcesses {
  $appDir = Join-Path $Root 'app'
  return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    Test-LemonLockProcess -ProcessId $_.ProcessId -SelfPid $PID -Name $_.Name -ExecutablePath $_.ExecutablePath -CommandLine $_.CommandLine -AppDir $appDir
  } | Sort-Object { if ([string]$_.CommandLine -like '*run-agent.ps1*') { 0 } else { 1 } }, ProcessId)
}

function Stop-LemonChat {
  Invoke-NativeQuiet schtasks.exe /End /TN $TaskName | Out-Null
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $targets = @(Get-LemonLockProcesses)
    if ($targets.Count -eq 0) { break }
    foreach ($proc in $targets) { Stop-PidTree ([int]$proc.ProcessId) }
    Start-Sleep -Milliseconds 400
  }
  foreach ($name in @('watchdog.pid', 'worker.pid')) {
    Remove-Item (Join-Path $Root $name) -Force -ErrorAction SilentlyContinue
  }
  $left = @(Get-LemonLockProcesses)
  if ($left.Count -gt 0) {
    $ids = ($left | ForEach-Object { '{0}:{1}' -f $_.ProcessId, $_.Name }) -join ', '
    throw "Nao foi possivel encerrar o Lemon Chat ($ids). Feche a bandeja e tente de novo."
  }
}

function Remove-DirectoryRetry {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$Attempts = 8,
    [int]$DelayMilliseconds = 1000,
    [scriptblock]$BeforeRetry
  )
  if (-not (Test-Path -LiteralPath $Path)) { return }
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    try {
      Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.Attributes = 'Normal' } catch {}
      }
      Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
      return
    } catch {
      if ($attempt -ge $Attempts) { throw }
      if ($BeforeRetry) { & $BeforeRetry }
      Start-Sleep -Milliseconds $DelayMilliseconds
    }
  }
}

function Remove-InstalledApp {
  $appDir = Join-Path $Root 'app'
  if (-not (Test-Path -LiteralPath $appDir)) { return }
  Stop-LemonChat
  Remove-DirectoryRetry -Path $appDir -BeforeRetry { Stop-LemonChat }
}

function Ensure-Root {
  New-Item -ItemType Directory -Force -Path $Root, (Join-Path $Root 'session'), (Join-Path $Root 'logs'), (Join-Path $Root 'scripts') | Out-Null
  & icacls.exe $Root /grant "${env:USERNAME}:(OI)(CI)M" | Out-Null
}

function Register-LemonChatTasks {
  $runScript = Join-Path $Root 'scripts\run-agent.ps1'
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runScript`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

  $updateArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"irm $UpdateScriptUrl | iex`""
  $updateAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $updateArgs
  $updateTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(20) -RepetitionInterval (New-TimeSpan -Hours 6) -RepetitionDuration (New-TimeSpan -Days 9999)
  $updateSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
  Register-ScheduledTask -TaskName $UpdateTaskName -Action $updateAction -Trigger $updateTrigger -Settings $updateSettings -Force | Out-Null
}

function Install-DesktopShortcut([string]$ExePath) {
  $desktop = [Environment]::GetFolderPath('Desktop')
  $shortcut = Join-Path $desktop 'Lemon Chat.lnk'
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($shortcut)
  $link.TargetPath = $ExePath
  $link.WorkingDirectory = Split-Path $ExePath
  $link.WindowStyle = 7
  $link.Description = 'Lemon Chat'
  $link.IconLocation = "$ExePath,0"
  $link.Save()
}

function Install-Release([string]$ZipUrl, [string]$Version) {
  $tmp = Join-Path $env:TEMP ("lemon-chat-" + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    $zip = Join-Path $tmp 'agent.zip'
    Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing
    $extract = Join-Path $tmp 'extract'
    Expand-Archive -Path $zip -DestinationPath $extract -Force
    Remove-InstalledApp
    $appDir = Join-Path $Root 'app'
    New-Item -ItemType Directory -Force -Path $appDir | Out-Null
    Get-ChildItem -Path $extract | Where-Object { $_.Name -notin @('scripts', 'VERSION', 'Instalar Lemon Chat.cmd') } | ForEach-Object {
      Copy-Item -Path $_.FullName -Destination $appDir -Recurse -Force
    }
    $scriptsDir = Join-Path $Root 'scripts'
    New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
    $bundledScripts = Join-Path $extract 'scripts'
    if (Test-Path $bundledScripts) {
      Copy-Item -Path (Join-Path $bundledScripts '*') -Destination $scriptsDir -Force
    }
    Set-Content -Path (Join-Path $Root 'VERSION') -Value $Version -Encoding ascii
    $exe = Join-Path $appDir 'Lemon Chat.exe'
    if (-not (Test-Path $exe)) { throw 'O pacote nao contem Lemon Chat.exe' }
    Register-LemonChatTasks
    Install-DesktopShortcut $exe
  } finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# install-local.ps1 importa as funcoes com dot-source. irm | iex segue para a instalacao.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
  Ensure-Root
  $release = Get-AgentRelease
  $remote = ([string]$release.tag_name) -replace '^agent-v', ''
  $local = Get-LocalVersion
  $exe = Join-Path $Root 'app\Lemon Chat.exe'
  if (-not (Test-IsNewer $remote $local) -and (Test-Path $exe)) {
    Register-LemonChatTasks
    Install-DesktopShortcut $exe
    Write-UpdateLog "Lemon Chat $local ja esta atualizado."
    return
  }
  $asset = @($release.assets) | Where-Object { $_.name -eq $ZipName } | Select-Object -First 1
  if (-not $asset) { throw "Release $($release.tag_name) sem $ZipName" }
  Write-UpdateLog "Atualizando $local -> $remote"
  Install-Release $asset.browser_download_url $remote
  Invoke-NativeQuiet schtasks.exe /Run /TN $TaskName | Out-Null
  Write-UpdateLog "Lemon Chat $remote instalado."
} catch {
  Write-UpdateLog ("Falha: {0}" -f $_.Exception.Message)
  if (Test-Path (Join-Path $Root 'app\Lemon Chat.exe')) {
    Invoke-NativeQuiet schtasks.exe /Run /TN $TaskName | Out-Null
  }
  throw
}
