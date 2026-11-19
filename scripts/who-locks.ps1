#Requires -Version 5.1
<#
  who-locks.ps1 - 定位文件/目录的句柄持有者（Windows，建议管理员）

  用途：出现 EIO / EBUSY / ReplaceFileW Win32 32 / 1175 / 文件正在使用时，
        一条命令找出是谁持有句柄，而不是猜同步盘。

  调用:
    powershell -NoProfile -ExecutionPolicy Bypass -File memory\tools\who-locks.ps1 -Path "D:\work\reports\x.md"
    powershell -NoProfile -ExecutionPolicy Bypass -File memory\tools\who-locks.ps1 -Path "reports" -Json
    powershell -NoProfile -ExecutionPolicy Bypass -File memory\tools\who-locks.ps1 -TargetPid 26160

  参数:
    -Path       文件/目录完整路径，或名称子串（位置 0）
    -TargetPid  只查该 PID 的全部句柄，可再配合 -Path 过滤
    -Json       输出 JSON
    -Reveal     附带持有进程的完整命令行
    -TimeoutSec handle64 超时秒数，默认 120

  退出码:
    0 = 找到持有者
    1 = 没找到（当前无句柄占用，锁不是原因）
    2 = 找不到 handle64.exe
    3 = 参数错误

  已知限制（2026-11-19 实测）:
    handle64 把非 ASCII 字符一律输出成问号，故本脚本把查询串同样归一化后比较。
    中文路径可匹配，但无法区分同目录下只差中文字符的两个文件。
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Path,
  [int]$TargetPid = 0,
  [switch]$Json,
  [switch]$Reveal,
  [int]$TimeoutSec = 120
)

$ErrorActionPreference = 'Stop'

function Write-Usage {
  Write-Output 'USAGE: who-locks.ps1 -Path <文件或目录或名称子串> [-TargetPid <pid>] [-Json] [-Reveal]'
  Write-Output '  exit 0=有持有者 1=无 2=缺 handle64 3=参数错误'
}

function Find-Handle64 {
  $cands = @(
    $env:DSH_HANDLE64,
    'D:\work\tools\handle64.exe',
    'E:\tools\handle64.exe',
    (Join-Path $PSScriptRoot 'handle64.exe')
  )
  foreach ($c in $cands) {
    if ($c -and (Test-Path -LiteralPath $c)) { return (Get-Item -LiteralPath $c).FullName }
  }
  $cmd = Get-Command 'handle64.exe' -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function ConvertTo-HandleName([string]$s) {
  if (-not $s) { return '' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $s.ToCharArray()) {
    if ([int][char]$ch -lt 128) { [void]$sb.Append($ch) } else { [void]$sb.Append('?') }
  }
  return $sb.ToString()
}

if ([string]::IsNullOrWhiteSpace($Path) -and $TargetPid -le 0) {
  Write-Usage
  exit 3
}

$exe = Find-Handle64
if (-not $exe) {
  Write-Output 'ERR: handle64.exe not found. Set $env:DSH_HANDLE64 or put it at D:\work\tools\handle64.exe'
  exit 2
}

if ($Path) {
  if (Test-Path -LiteralPath $Path) { $resolved = (Resolve-Path -LiteralPath $Path).Path }
  else { $resolved = $Path }
} else { $resolved = '' }
$query = ConvertTo-HandleName $resolved

# handle64 的搜索串改用最后一段（leaf）更稳：完整路径含 '?' 时它按通配符处理会漏
$searchArg = $query
if ($resolved) {
  $leaf = Split-Path -Leaf $resolved
  if ($leaf) { $searchArg = ConvertTo-HandleName $leaf }
}
if ([string]::IsNullOrWhiteSpace($searchArg)) { $searchArg = $query }

$tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), ('who-locks-' + [guid]::NewGuid().ToString('N') + '.txt'))
$argList = @('-accepteula', '-nobanner')
if ($TargetPid -gt 0) { $argList += @('-p', ("$TargetPid")) } else { $argList += $searchArg }

$text = ''
try {
  $proc = Start-Process -FilePath $exe -ArgumentList $argList -RedirectStandardOutput $tmp -NoNewWindow -PassThru
  if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    try { $proc.Kill() } catch { }
    Write-Output ('WARN: handle64 timed out after ' + $TimeoutSec + 's')
  }
  if (Test-Path -LiteralPath $tmp) { $text = [IO.File]::ReadAllText($tmp, [Text.Encoding]::GetEncoding(936)) }
} finally {
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

$rx = '^(?<proc>.+?)\s+pid:\s*(?<pid>\d+)\s+type:\s*(?<type>\S+)\s+(?<handle>[0-9A-Fa-f]+):\s*(?<path>.+)$'
$rows = @()
foreach ($line in ([regex]::Split($text, '\r?\n'))) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $m = [regex]::Match($line, $rx)
  if (-not $m.Success) { continue }
  if ($m.Groups['proc'].Value.Trim() -eq 'handle64.exe') { continue }   # 排除扫描器自身
  $rpath = $m.Groups['path'].Value
  if ($query -and $rpath.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
  $rows += [pscustomobject]@{
    Pid     = [int]$m.Groups['pid'].Value
    Process = $m.Groups['proc'].Value.Trim()
    Type    = $m.Groups['type'].Value
    Handle  = $m.Groups['handle'].Value
    Path    = $rpath
  }
}

if ($Reveal -and $rows.Count -gt 0) {
  $seen = @{}
  foreach ($r in $rows) {
    if ($seen.ContainsKey($r.Pid)) { continue }
    $seen[$r.Pid] = $true
    $ci = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $r.Pid) -ErrorAction SilentlyContinue
    $cl = '(exited or access denied)'
    if ($ci -and $ci.CommandLine) { $cl = $ci.CommandLine }
    Write-Output ('CMD ' + $r.Pid + ' ' + $r.Process + ' : ' + $cl)
  }
}

if ($Json) {
  $verdict = 'NOT_LOCKED'
  if ($rows.Count -gt 0) { $verdict = 'LOCKED' }
  [pscustomobject]@{
    query     = $resolved;
    handle64  = $exe;
    targetPid = $TargetPid;
    count     = $rows.Count;
    holders   = $rows;
    verdict   = $verdict
  } | ConvertTo-Json -Depth 4
} else {
  $q = $resolved
  if (-not $q) { $q = '(pid ' + $TargetPid + ')' }
  Write-Output ('QUERY    : ' + $q)
  Write-Output ('HANDLE64 : ' + $exe)
  if ($rows.Count -eq 0) {
    Write-Output 'HOLDERS  : 0'
    Write-Output 'VERDICT  : NOT_LOCKED - 当前无句柄持有者，锁不是原因，去查内容/权限/过滤器驱动'
  } else {
    $dp = ($rows | Select-Object -ExpandProperty Pid -Unique).Count
    Write-Output ('HOLDERS  : ' + $rows.Count + '  (distinct pid: ' + $dp + ')')
    $rows | Format-Table Pid, Process, Type, Handle, Path -AutoSize | Out-String -Width 220
    Write-Output 'VERDICT  : LOCKED - 上列进程持有句柄；先关它再重试，不要反复重放同一命令'
  }
}

if ($rows.Count -gt 0) { exit 0 } else { exit 1 }
