# hgwt.ps1 - herdr plugin: Mercurial "worktrees" via `hg share`, with git fallthrough.
# PowerShell port of bin/hgwt for Windows. Runs on Windows PowerShell 5.1 and PowerShell 7+.
#
# CLI (hg only; mirrors `herdr worktree`):
#   hgwt list   [--json]
#   hgwt create --bookmark NAME [--base REV] [--path DIR] [--label TEXT] [--no-focus]
#   hgwt open   (--bookmark NAME | --path DIR) [--label TEXT] [--no-focus]
#   hgwt remove [--bookmark NAME | --path DIR] [--force] [--strip]
#   hgwt prune  [--dry-run]             remove closed shares + bookmarks whose work landed
#   hgwt close-group [--prune]          close the repo's workspace and all its shares
#   hgwt info   [--fetch]               full details: bookmark, parent, remote, drafts
#   (all take --cwd DIR or --workspace ID to pick the repo; default: current dir)
#   hgwt setup  [--yes|--uninstall|--status|--dismiss]
#
# Plugin internals:
#   hgwt action new|open|remove|prune|close-group|info|setup   open the matching popup
#   hgwt ui     new|open|remove|prune|close-group|info|setup   interactive popup body
#   hgwt refresh [--all|--event|--workspace ID|--cwd DIR] [--remote auto|force|cache]
#   hgwt startup

$ErrorActionPreference = 'Stop'
$script:Win = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($PSVersionTable.PSObject.Properties['Platform'] -and $PSVersionTable.Platform -eq 'Win32NT')
$script:Self = $MyInvocation.MyCommand.Path
$script:BinDir = Split-Path -Parent $script:Self

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$env:HGPLAIN = '1'
$env:HGENCODING = 'utf-8'
# hg hooks fired by our own hg calls (resolve -l -> post-resolve) must not
# re-trigger a refresh, or each refresh spawns another forever
$env:HGWT_INTERNAL = '1'

# non-ASCII glyphs as char codes, so this file is safe to read as ANSI
$UP = [string][char]0x2191; $DOWN = [string][char]0x2193; $ELL = [string][char]0x2026
$ARROW = [string][char]0x21B3; $TRI = [string][char]0x25B8; $CUR = [string][char]0x25B6; $MID = [string][char]0x00B7
$ESC = [string][char]27

$PLUGIN_ID = if ($env:HERDR_PLUGIN_ID) { $env:HERDR_PLUGIN_ID } else { 'mpzarde.hg-worktree' }
$SOURCE = 'plugin:hg-worktree'

function Get-HomeDir { if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME } }
$HOMEDIR = Get-HomeDir

function Get-HerdrConfigPath {
  if ($env:HERDR_CONFIG_PATH) { return $env:HERDR_CONFIG_PATH }
  if ($script:Win -and $env:APPDATA) { return (Join-Path $env:APPDATA 'herdr\config.toml') }
  $x = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOMEDIR '.config' }
  Join-Path $x 'herdr/config.toml'
}

if (-not $env:HERDR_PLUGIN_CONFIG_DIR) {
  if ($script:Win -and $env:APPDATA) { $env:HERDR_PLUGIN_CONFIG_DIR = Join-Path $env:APPDATA "herdr\plugins\config\$PLUGIN_ID" }
  else {
    $x = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOMEDIR '.config' }
    $env:HERDR_PLUGIN_CONFIG_DIR = Join-Path $x "herdr/plugins/config/$PLUGIN_ID"
  }
}
# config.env: KEY=VALUE lines (same file the bash version reads); real environment wins
$cfgEnv = Join-Path $env:HERDR_PLUGIN_CONFIG_DIR 'config.env'
if (Test-Path -LiteralPath $cfgEnv) {
  foreach ($l in [IO.File]::ReadAllLines($cfgEnv)) {
    if ($l -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*?)\s*$') {
      $v = $Matches[2]
      if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) { $v = $v.Substring(1, $v.Length - 2) }
      if (-not [Environment]::GetEnvironmentVariable($Matches[1])) { [Environment]::SetEnvironmentVariable($Matches[1], $v) }
    }
  }
}
function Env-Or($name, $default) { $v = [Environment]::GetEnvironmentVariable($name); if ($v) { $v } else { $default } }

$WT_ROOT = Env-Or 'HG_WORKTREES_DIR' (Join-Path $HOMEDIR '.herdr/worktrees')
if ($WT_ROOT.StartsWith('~')) { $WT_ROOT = $HOMEDIR + $WT_ROOT.Substring(1) }
$LAYOUT = Env-Or 'HG_WORKTREES_LAYOUT' 'central'                 # central | sibling
$SHARE_BOOKMARKS = Env-Or 'HG_SHARE_BOOKMARKS' '1'
$NEW_KIND = Env-Or 'HG_NEW_BRANCH' 'bookmark'                    # bookmark | branch (named branch)
$COPY_GLOBS = Env-Or 'HGWT_COPY' ''                              # untracked files to copy into new shares
$BM_MAX = Env-Or 'HG_BOOKMARK_MAX' 'auto'                        # sidebar bookmark length: auto | 0 (off) | N
$BM_STRIP = Env-Or 'HG_BOOKMARK_STRIP' ''                        # regex removed from names in the sidebar
$REMOTE_MINUTES = [int](Env-Or 'HG_REMOTE_CHECK_MINUTES' '10')   # 0 disables incoming checks
$REMOTE_TIMEOUT = [int](Env-Or 'HG_REMOTE_TIMEOUT' '20')
$HERDR_TIMEOUT = [int](Env-Or 'HGWT_HERDR_TIMEOUT' '15')
$HG_LOCAL_TIMEOUT = [int](Env-Or 'HGWT_HG_TIMEOUT' '60')
if ($script:Win -and $env:LOCALAPPDATA) { $CACHE = Join-Path $env:LOCALAPPDATA 'herdr-hg' }
else {
  $x = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Path $HOMEDIR '.cache' }
  $CACHE = Join-Path $x 'herdr-hg'
}
$script:BG = $false   # true in unattended runs (events, hg hooks, startup): bound local hg calls too
$script:WarnLog = New-Object System.Collections.ArrayList
$script:WsMapCache = $null

# --- process helpers ------------------------------------------------------------

function Quote-Arg([string]$a) {
  if ([string]::IsNullOrEmpty($a)) { return '""' }
  if ($a -notmatch '[\s"]') { return $a }
  $a = [regex]::Replace($a, '(\\*)"', '$1$1\"')
  $a = [regex]::Replace($a, '(\\+)$', '$1$1')
  '"' + $a + '"'
}

function Resolve-Exe([string]$name) {
  if ([IO.Path]::IsPathRooted($name) -and (Test-Path -LiteralPath $name)) { return $name }
  $c = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { $c.Source } else { $name }
}

function Stop-Tree($p) {
  try {
    if ($script:Win) { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null }
    else { try { $p.Kill($true) } catch { $p.Kill() } }
  } catch { }
}

# Runs a native command with stdin closed. A timeout (seconds) kills the whole process
# tree (killing only hg would orphan the ssh it spawned) and reports code 124.
function Exec([string]$File, [string[]]$ArgList, [int]$Timeout = 0) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $exe = Resolve-Exe $File
  if ($exe -match '\.(cmd|bat)$') {
    $psi.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
    $psi.Arguments = '/c "' + (Quote-Arg $exe) + ' ' + (($ArgList | ForEach-Object { Quote-Arg $_ }) -join ' ') + '"'
  } else {
    $psi.FileName = $exe
    $psi.Arguments = ($ArgList | ForEach-Object { Quote-Arg $_ }) -join ' '
  }
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $psi.StandardOutputEncoding = $utf8
  $psi.StandardErrorEncoding = $utf8
  try { $p = [System.Diagnostics.Process]::Start($psi) }
  catch { return [pscustomobject]@{ Out = ''; Err = "$_"; Code = 127 } }
  $p.StandardInput.Close()
  $so = $p.StandardOutput.ReadToEndAsync()
  $se = $p.StandardError.ReadToEndAsync()
  $code = 0
  if ($Timeout -gt 0) {
    if (-not $p.WaitForExit($Timeout * 1000)) { Stop-Tree $p; [void]$p.WaitForExit(2000); $code = 124 }
  } else { $p.WaitForExit() }
  if ($code -ne 124) { $p.WaitForExit(); $code = $p.ExitCode }
  [void]$so.Wait(3000); [void]$se.Wait(3000)
  [pscustomobject]@{
    Out  = $(if ($so.IsCompleted) { $so.Result } else { '' })
    Err  = $(if ($se.IsCompleted) { $se.Result } else { '' })
    Code = $code
  }
}

$HGEXE = 'hg'
$GITEXE = 'git'
function HgX { $t = if ($script:BG) { $HG_LOCAL_TIMEOUT } else { 0 }; Exec $HGEXE ([string[]]$args) $t }
function Hg { $r = HgX @args; if ($r.Code -eq 0) { $r.Out.TrimEnd("`r", "`n") } else { '' } }   # stdout, '' on failure
function HgOk { (HgX @args).Code -eq 0 }
function HgLines { $s = Hg @args; if ($s) { @($s -split "\r?\n") } else { @() } }
function Git { $r = Exec $GITEXE ([string[]]$args) 0; if ($r.Code -eq 0) { $r.Out.TrimEnd("`r", "`n") } else { '' } }
function Herdr {
  $bin = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { 'herdr' }
  Exec $bin ([string[]]$args) $HERDR_TIMEOUT
}
function HerdrOut { $r = Herdr @args; if ($r.Code -eq 0) { $r.Out } else { '' } }
function HerdrJson { $s = HerdrOut @args; if ($s) { try { $s | ConvertFrom-Json } catch { $null } } else { $null } }

function Die([string]$m) { [Console]::Error.WriteLine("hgwt: $m"); exit 1 }
function Warn([string]$m) { [Console]::Error.WriteLine("hgwt: $m"); [void]$script:WarnLog.Add($m) }

# Raw socket request for methods the CLI doesn't expose (workspace.move).
# Unix socket on Linux/macOS, named pipe on Windows.
function Sock([string]$method, [string]$paramsJson) {
  $path = $env:HERDR_SOCKET_PATH
  if (-not $path) { return }
  $req = '{"id":"hgwt:' + $method + '","method":"' + $method + '","params":' + $paramsJson + "}`n"
  try {
    if ($script:Win) {
      $name = $path -replace '^\\\\[.?]\\pipe\\', ''
      $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $name, [System.IO.Pipes.PipeDirection]::InOut)
      $c.Connect(2000); $stream = $c
    } else {
      $s = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::Unix, [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]::Unspecified)
      $s.Connect((New-Object System.Net.Sockets.UnixDomainSocketEndPoint($path)))
      $stream = New-Object System.Net.Sockets.NetworkStream($s, $true)
    }
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($req)
    $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
    $rd = New-Object System.IO.StreamReader($stream)
    $t = $rd.ReadLineAsync(); [void]$t.Wait(2000)
    $stream.Dispose()
  } catch { }
}

# --- paths --------------------------------------------------------------------------

function Real-Path([string]$p) {   # like `pwd -P`
  if ($script:Win) { return [IO.Path]::GetFullPath($p).TrimEnd('\') -replace '^([A-Za-z]:)$', '$1\' }
  $r = Exec 'sh' @('-c', 'cd "$1" 2>/dev/null && pwd -P', 'sh', $p) 0
  if ($r.Code -eq 0 -and $r.Out.Trim()) { $r.Out.Trim() } else { [IO.Path]::GetFullPath($p) }
}
function NormP([string]$p) {
  $n = ($p -replace '\\', '/').TrimEnd('/')
  if ($script:Win) { $n = $n.ToLowerInvariant() }
  $n
}
function PathEq($a, $b) { (NormP $a) -ceq (NormP $b) }
function PathUnder($child, $parent) {   # child is parent or inside it
  $c = NormP $child; $p = NormP $parent
  ($c -ceq $p) -or $c.StartsWith($p + '/', [StringComparison]::Ordinal)
}
function Tilde([string]$p) {
  if ($p -and (PathUnder $p $HOMEDIR)) { '~' + $p.Substring($HOMEDIR.TrimEnd('\', '/').Length) } else { $p }
}
function Base([string]$p) { Split-Path -Leaf ($p.TrimEnd('\', '/')) }
function ParentDir([string]$p) { Split-Path -Parent ($p.TrimEnd('\', '/')) }
function Ck([string]$s) {
  $h = [System.Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($s))
  -join ($h[0..4] | ForEach-Object { $_.ToString('x2') })
}
function EpochNow { [int64][double]::Parse(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()).ToString()) }
function Read-Lines([string]$f) { if (Test-Path -LiteralPath $f -PathType Leaf) { @([IO.File]::ReadAllLines($f)) } else { @() } }
function Append-Line([string]$f, [string]$line) { [IO.File]::AppendAllText($f, $line + "`n") }
function Write-Lines([string]$f, $lines) {
  $lines = @($lines)
  if ($lines.Count -eq 0) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
  else { [IO.File]::WriteAllText($f, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false))) }
}
function Files-Equal($a, $b) {
  try {
    $x = [IO.File]::ReadAllBytes($a); $y = [IO.File]::ReadAllBytes($b)
    if ($x.Length -ne $y.Length) { return $false }
    for ($i = 0; $i -lt $x.Length; $i++) { if ($x[$i] -ne $y[$i]) { return $false } }
    $true
  } catch { $false }
}

# --- context from herdr --------------------------------------------------------------

$script:Ctx = $null
if ($env:HERDR_PLUGIN_CONTEXT_JSON) { try { $script:Ctx = $env:HERDR_PLUGIN_CONTEXT_JSON | ConvertFrom-Json } catch { } }
function Ctx([string]$prop) { if ($script:Ctx -and $script:Ctx.PSObject.Properties[$prop] -and $script:Ctx.$prop) { [string]$script:Ctx.$prop } else { '' } }

function Current-Cwd {
  $d = Ctx 'focused_pane_cwd'
  if (-not $d) { $d = Ctx 'workspace_cwd' }
  if (-not $d) { $d = $env:HERDR_ACTIVE_PANE_CWD }
  if (-not $d) { $d = (Get-Location).ProviderPath }
  $d
}
function Current-Ws {
  $w = Ctx 'workspace_id'
  if ($w) { return $w }
  foreach ($n in 'HERDR_WORKSPACE_ID', 'HERDR_ACTIVE_WORKSPACE_ID') { $v = [Environment]::GetEnvironmentVariable($n); if ($v) { return $v } }
  ''
}

# --- repo helpers ----------------------------------------------------------------------

function Vcs-Of([string]$d) {   # hg | git | none  (deepest repo root wins if both)
  $hr = Hg --cwd $d root
  $gr = Git -C $d rev-parse --show-toplevel
  if ($hr -and $hr.Length -ge $gr.Length) { 'hg' } elseif ($gr) { 'git' } else { 'none' }
}
function Hg-Root([string]$d) { $r = Hg --cwd $d root; if ($r) { Real-Path $r } else { '' } }
function Wc-Label([string]$r) {   # active bookmark, else the working copy's branch
  $x = HgX -R $r log -r . -T '{activebookmark}'
  if ($x.Code -ne 0) { return '?' }
  $b = $x.Out.Trim()
  if (-not $b) { $b = Hg -R $r branch; if (-not $b) { $b = '?' } }
  $b
}
function Branch-Exists($r, $name) { [bool](Hg -R $r log -r "branch('literal:$name')" -T x) }

function Source-Of-Root([string]$r) {   # source repo of a checkout dir (itself when it isn't a share)
  $sp = Join-Path $r '.hg/sharedpath'
  if (Test-Path -LiteralPath $sp -PathType Leaf) {
    $t = ([IO.File]::ReadAllText($sp)).Trim()
    if (-not [IO.Path]::IsPathRooted($t)) { $t = Join-Path (Join-Path $r '.hg') $t }
    $d = ParentDir ([IO.Path]::GetFullPath($t))
    if (Test-Path -LiteralPath $d) { return (Real-Path $d) }
    return ''
  }
  $r
}
function Hg-Source-Root([string]$d) { $r = Hg-Root $d; if ($r) { Source-Of-Root $r } else { '' } }

function Slug([string]$s) { ([regex]::Replace(([regex]::Replace($s, '[^A-Za-z0-9._-]', '-')), '-+', '-')).Trim('-') }
function Share-Dest($src, $bm) {
  if ($LAYOUT -eq 'sibling') { Join-Path (ParentDir $src) ((Base $src) + '-' + (Slug $bm)) }
  else { Join-Path (Join-Path $WT_ROOT (Base $src)) (Slug $bm) }
}
function Is-Share-Of($d, $src) {
  (-not (PathEq $d $src)) -and (Test-Path -LiteralPath (Join-Path $d '.hg/sharedpath') -PathType Leaf) -and (PathEq (Source-Of-Root $d) $src)
}

# Shares created with --path live outside both layouts; they're listed here.
function Extra-File($src) { Join-Path $src '.hg/herdr-hg-shares' }
function Unrecord-Share($src, $path) {
  $f = Extra-File $src; if (-not (Test-Path -LiteralPath $f)) { return }
  Write-Lines $f @(Read-Lines $f | Where-Object { $_ -cne $path })
}

# every share of $src: @{Path; Label}; both layouts plus --path ones
function Hg-Shares($src) {
  $repo = Base $src
  $cands = New-Object System.Collections.ArrayList
  $a = Join-Path $WT_ROOT $repo
  if (Test-Path -LiteralPath $a) { Get-ChildItem -LiteralPath $a -Directory -Force | ForEach-Object { [void]$cands.Add($_.FullName) } }
  $par = ParentDir $src
  if ($par -and (Test-Path -LiteralPath $par)) {
    Get-ChildItem -LiteralPath $par -Directory -Force | Where-Object { $_.Name.StartsWith("$repo-") } | ForEach-Object { [void]$cands.Add($_.FullName) }
  }
  foreach ($l in (Read-Lines (Extra-File $src))) { if ($l) { [void]$cands.Add($l) } }
  $seen = @{}; $out = New-Object System.Collections.ArrayList
  foreach ($d in $cands) {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
    $d = Real-Path $d
    $k = NormP $d
    if ($seen.ContainsKey($k)) { continue }
    $seen[$k] = 1
    if (-not (Is-Share-Of $d $src)) { continue }
    [void]$out.Add([pscustomobject]@{ Path = $d; Label = (Wc-Label $d) })
  }
  , @($out)
}

function Find-Share($src, $bm) {   # exact bookmark/branch match, then slug path; '' if none
  foreach ($s in (Hg-Shares $src)) { if ($s.Label -ceq $bm) { return $s.Path } }
  $p = Share-Dest $src $bm
  if ((Test-Path -LiteralPath $p -PathType Container) -and (Is-Share-Of (Real-Path $p) $src)) { return (Real-Path $p) }
  ''
}

# --- workspace helpers ---------------------------------------------------------------------

# one entry per workspace (focused pane's cwd, else first pane), in sidebar order
function Ws-Map {
  if ($null -ne $script:WsMapCache) { return , $script:WsMapCache }
  $panes = HerdrJson pane list
  $wss = HerdrJson workspace list
  $out = New-Object System.Collections.ArrayList
  if ($wss -and $wss.result -and $wss.result.workspaces) {
    foreach ($w in @($wss.result.workspaces)) {
      $mine = @()
      if ($panes -and $panes.result -and $panes.result.panes) { $mine = @($panes.result.panes | Where-Object { $_.workspace_id -eq $w.workspace_id }) }
      $f = @($mine | Where-Object { $_.focused })
      $pick = if ($f.Count) { $f[0] } elseif ($mine.Count) { $mine[0] } else { $null }
      [void]$out.Add([pscustomobject]@{ Ws = [string]$w.workspace_id; Cwd = $(if ($pick -and $pick.cwd) { [string]$pick.cwd } else { '' }) })
    }
  }
  $script:WsMapCache = @($out)
  , $script:WsMapCache
}
function Ws-Reset { $script:WsMapCache = $null }
function Ws-Cwd($ws) { foreach ($e in (Ws-Map)) { if ($e.Ws -ceq $ws) { return $e.Cwd } }; '' }
function Ws-Label($ws) { $j = HerdrJson workspace get $ws; if ($j -and $j.result.workspace.label) { [string]$j.result.workspace.label } else { '' } }
function Ws-For-Path($p) { foreach ($e in (Ws-Map)) { if ($e.Cwd -and (PathUnder $e.Cwd $p)) { return $e.Ws } }; '' }

# workspaces belonging to source repo $src: @{Ws; Role; Path} (Role = source|share)
function Group-Members($src) {
  $out = New-Object System.Collections.ArrayList
  foreach ($e in (Ws-Map)) {
    if (-not $e.Cwd -or (Vcs-Of $e.Cwd) -ne 'hg') { continue }
    $r = Hg-Root $e.Cwd
    if (PathEq $r $src) { [void]$out.Add([pscustomobject]@{ Ws = $e.Ws; Role = 'source'; Path = $r }) }
    elseif (Is-Share-Of $r $src) { [void]$out.Add([pscustomobject]@{ Ws = $e.Ws; Role = 'share'; Path = $r }) }
  }
  , @($out)
}

# Keep workspace $ws inside the block that starts at its source's workspace:
# source, then its shares. No-op if already there or the source isn't open.
function Regroup($ws, $src) {
  $members = @(Group-Members $src)
  $parent = ($members | Where-Object { $_.Role -eq 'source' } | Select-Object -First 1)
  if (-not $parent -or $parent.Ws -ceq $ws) { return }
  $j = HerdrJson workspace list
  if (-not $j) { return }
  $ids = @($j.result.workspaces | ForEach-Object { [string]$_.workspace_id })
  $idx = -1; $inBlock = $false
  for ($i = 0; $i -lt $ids.Count; $i++) {
    $id = $ids[$i]
    if ($id -ceq $parent.Ws) { $idx = $i; $inBlock = $true }
    elseif ($inBlock) {
      if (@($members | Where-Object { $_.Ws -ceq $id -and $_.Role -eq 'share' }).Count) {
        if ($id -ceq $ws) { return }   # already grouped
        $idx = $i
      } else { $inBlock = $false }
    }
  }
  if ($idx -lt 0) { return }
  # insert_index means "before the workspace currently at this index"
  Sock 'workspace.move' ('{"workspace_id":"' + $ws + '","insert_index":' + ($idx + 1) + '}')
}

function Is-Generated-Label([string]$l) { $l.StartsWith("$ARROW ") -or $l.Contains(" $TRI ") }

# Sidebar label: "<arrow> bookmark" under an open source workspace, else "repo > bookmark".
function Share-Label($path, $src) {
  $bm = Wc-Label $path
  $hasSource = @(Group-Members $src | Where-Object { $_.Role -eq 'source' }).Count -gt 0
  if ($hasSource) { "$ARROW " + (Short-Name $bm (Name-Budget 2)) }
  else { $repo = Base $src; "$repo $TRI " + (Short-Name $bm (Name-Budget ($repo.Length + 3))) }
}
function Focus-Flag { if ((Env-Or 'HGWT_FOCUS' '1') -eq '1') { '--focus' } else { '--no-focus' } }

# --- core operations ---------------------------------------------------------------------

function Core-Open($path, $src, $label = '') {   # -> workspace id
  $ws = Ws-For-Path $path
  if ($ws) {
    if ((Env-Or 'HGWT_FOCUS' '1') -eq '1') { [void](Herdr workspace focus $ws) }
    if ($label) { [void](Herdr workspace rename $ws $label) }
    return $ws
  }
  if (-not $label) {
    if (PathEq $path $src) { $label = Base $src } else { $label = Share-Label $path $src }
  }
  $j = HerdrJson workspace create --cwd $path --label $label (Focus-Flag)
  Ws-Reset
  $ws = if ($j -and $j.result.workspace.workspace_id) { [string]$j.result.workspace.workspace_id } else { '' }
  if (-not $ws) { Warn 'workspace create failed'; return '' }
  if (PathEq $path $src) { Relabel-All } else { Regroup $ws $src }
  Refresh-Ws $ws $path 'cache'
  Run-Pending-Setup $ws $path $src
  $ws
}

function Bm-Exists($r, $name) { HgOk -R $r log -r "bookmark('$name')" -T x }
function Active-Bm($r) { $x = HgX -R $r log -r . -T '{activebookmark}'; if ($x.Code -eq 0) { $x.Out.Trim() } else { '' } }

# src name base(empty = "." of src, or the existing bookmark/branch) [path] -> path ('' on failure).
# An existing bookmark is checked out, then an existing named branch; otherwise
# a new bookmark (or named branch, HG_NEW_BRANCH=branch) is started at base.
function Core-Create($src, $name, $base = '', $dest = '') {
  if (-not $name) { Warn 'bookmark name required'; return '' }
  if (-not $dest) { $f = Find-Share $src $name; if ($f) { return $f } }
  if ($dest) {
    if (-not [IO.Path]::IsPathRooted($dest)) { $dest = Join-Path (Get-Location).ProviderPath $dest }
    if ((Test-Path -LiteralPath $dest -PathType Container) -and (Is-Share-Of (Real-Path $dest) $src)) { return (Real-Path $dest) }
  } else { $dest = Share-Dest $src $name }
  if (Test-Path -LiteralPath $dest) { Warn "$dest exists and is not a share of $src"; return '' }
  [void](New-Item -ItemType Directory -Force -Path (ParentDir $dest))
  $shareArgs = @('-U'); if ($SHARE_BOOKMARKS -eq '1') { $shareArgs += '-B' }
  $x = HgX --config extensions.share= share -q @shareArgs $src $dest
  if ($x.Code -ne 0) { Warn 'hg share failed'; return '' }
  # shared bookmarks only resolve with the extension loaded; enable it per-share
  [IO.File]::AppendAllText((Join-Path $dest '.hg/hgrc'), "[extensions]`nshare =`n")
  if (-not $base -and (Bm-Exists $src $name)) {
    if (-not (HgOk -R $dest update -q -r $name)) { Warn "update to $name failed"; return '' }
  } elseif (-not $base -and (Branch-Exists $src $name)) {
    if (-not (HgOk -R $dest update -q -r "max(branch('literal:$name') and head())")) { Warn "update to branch $name failed"; return '' }
  } else {
    if (-not $base) { $base = Hg -R $src log -r . -T '{node}' }
    if (-not (HgOk -R $dest update -q -r $base)) { Warn "update failed (share left at $dest)"; return '' }
    if ($NEW_KIND -eq 'branch') {
      if (-not (HgOk -R $dest branch -q $name)) { Warn "hg branch failed (share left at $dest)"; return '' }
    } else {
      if (-not (HgOk -R $dest bookmark $name)) { Warn "bookmark failed (share left at $dest)"; return '' }
      Own-Bm $src $name
    }
  }
  $dest = Real-Path $dest
  $std = Share-Dest $src $name
  $isStd = (Test-Path -LiteralPath $std) -and (PathEq $dest (Real-Path $std))
  if (-not $isStd -and -not (Read-Lines (Extra-File $src) | Where-Object { $_ -ceq $dest })) { Append-Line (Extra-File $src) $dest }
  Bootstrap $src $dest
  $dest
}

# --- new-share bootstrap -------------------------------------------------------------------
# Copy untracked files (HGWT_COPY, .hgwt-copy, .hg/hgwt-copy globs, relative to
# the source root) into a fresh share, never overwriting. Copies are listed in
# the share's .hg/hgwt-copied so removal doesn't count them as unsaved work.

function Copy-Globs($src) {
  $g = New-Object System.Collections.ArrayList
  foreach ($f in ($COPY_GLOBS -split '\s+')) { if ($f) { [void]$g.Add($f) } }
  foreach ($f in @((Join-Path $src '.hgwt-copy'), (Join-Path $src '.hg/hgwt-copy'))) {
    foreach ($l in (Read-Lines $f)) {
      $t = ($l -replace '#.*', '').Trim()
      if ($t) { [void]$g.Add($t) }
    }
  }
  @($g)
}

function Bootstrap($src, $dest) {
  $n = 0
  foreach ($g in (Copy-Globs $src)) {
    if ($g -match '^([/\\]|\.\.([/\\]|$))' -or $g -match '[/\\]\.\.([/\\]|$)') { Warn "skipping copy pattern outside the repo: $g"; continue }
    $pat = Join-Path $src $g
    foreach ($it in @(Get-ChildItem -Path $pat -Force -ErrorAction SilentlyContinue)) {
      $rel = $it.FullName.Substring($src.TrimEnd('\', '/').Length + 1) -replace '\\', '/'
      $to = Join-Path $dest $rel
      if (Test-Path -LiteralPath $to) { continue }
      [void](New-Item -ItemType Directory -Force -Path (ParentDir $to))
      Copy-Item -LiteralPath $it.FullName -Destination $to -Recurse -Force
      Append-Line (Join-Path $dest '.hg/hgwt-copied') $rel
      $n++
    }
  }
  if ($n -gt 0) { Warn "copied $n file(s) from $(Base $src)" }
  # the setup script runs in the new workspace (see Core-Open), so its output is visible there
  foreach ($e in 'hgwt-setup.ps1', 'hgwt-setup.cmd', 'hgwt-setup.bat') {
    if (Test-Path -LiteralPath (Join-Path $src ".hg/$e")) { [IO.File]::WriteAllText((Join-Path $dest '.hg/hgwt-setup-pending'), ''); break }
  }
}

function Setup-Script($src) {
  foreach ($e in 'hgwt-setup.ps1', 'hgwt-setup.cmd', 'hgwt-setup.bat') {
    $p = Join-Path $src ".hg/$e"; if (Test-Path -LiteralPath $p) { return $p }
  }
  ''
}

function Run-Pending-Setup($ws, $path, $src) {
  $f = Join-Path $path '.hg/hgwt-setup-pending'
  if (-not (Test-Path -LiteralPath $f)) { return }
  Remove-Item -LiteralPath $f -Force
  $j = HerdrJson pane list
  $p = ''
  if ($j) { $m = @($j.result.panes | Where-Object { $_.workspace_id -eq $ws }) | Select-Object -First 1; if ($m) { $p = [string]$m.pane_id } }
  if (-not $p) { Warn "no pane to run the setup script of $src in"; return }
  $s = Setup-Script $src
  $cmd = if ($s -like '*.ps1') { "`$env:HGWT_SOURCE='$src'; `$env:HGWT_SHARE='$path'; & '$s'" } else { "set HGWT_SOURCE=$src&& set HGWT_SHARE=$path&& `"$s`"" }
  $r = Herdr pane run $p $cmd
  if ($r.Code -ne 0) { Warn "couldn't start $s" }
}

# Untracked file in a share that is an unchanged copy from bootstrap.
function Copied-Unchanged($share, $src, $file) {
  foreach ($e in (Read-Lines (Join-Path $share '.hg/hgwt-copied'))) {
    if ($file -ceq $e -or $file.StartsWith($e + '/')) { if (Files-Equal (Join-Path $share $file) (Join-Path $src $file)) { return $true } }
  }
  $false
}

function Share-Dirty($r) { @(HgLines -R $r status -mard).Count }
# lines of `hg status` for what removing a checkout would lose (minus unchanged bootstrap copies)
function Unsaved-List($r) {
  $copied = (Read-Lines (Join-Path $r '.hg/hgwt-copied')).Count -gt 0
  $src = Source-Of-Root $r
  foreach ($line in (HgLines -R $r status -mardu)) {
    if ($copied -and $line.StartsWith('? ') -and (Copied-Unchanged $r $src ($line.Substring(2) -replace '\\', '/'))) { continue }
    $line
  }
}
function Share-Unsaved($r) { @(Unsaved-List $r).Count }

# --- bookmark hygiene ----------------------------------------------------------------------
# Bookmarks this plugin created are listed in the source repo's .hg, so cleanup
# only ever deletes what it made (never `main`, or a bookmark you checked out).

function Owned-File($src) { Join-Path $src '.hg/herdr-hg-bookmarks' }
function Owned-Bms($src) { Read-Lines (Owned-File $src) }
function Is-Owned-Bm($src, $bm) { [bool](Owned-Bms $src | Where-Object { $_ -ceq $bm }) }
function Own-Bm($src, $bm) { if (-not (Is-Owned-Bm $src $bm)) { Append-Line (Owned-File $src) $bm } }
function Disown-Bm($src, $bm) {
  $f = Owned-File $src; if (-not (Test-Path -LiteralPath $f)) { return }
  Write-Lines $f @(Read-Lines $f | Where-Object { $_ -cne $bm })
}
function Checkouts($src) { @($src) + @(Hg-Shares $src | ForEach-Object { $_.Path }) }
function Bm-In-Use($src, $bm, $except) {   # active in another checkout?
  foreach ($p in (Checkouts $src)) { if (-not (PathEq $p $except) -and (Active-Bm $p) -ceq $bm) { return $true } }
  $false
}

# Revset of the work only $rev holds: reachable from it but not public, not in
# another bookmark, and not obsolete (rebased/landed elsewhere). Empty = landed.
function Unlanded-Revs($repo, $rev, $own) {
  $others = 'public()'
  foreach ($b in (HgLines -R $repo bookmarks -T '{bookmark}\n')) {
    if (-not $b -or $b -ceq $own) { continue }
    if ($b.Contains("'") -or $b.Contains('\')) { continue }
    $others += " or bookmark('$b')"
  }
  "only($rev, $others) - obsolete()"
}
# -1 when hg can't tell (bad revset, unreadable repo): callers treat that as "not landed".
function Unlanded-Count($repo, $rev, $own) {
  $x = HgX -R $repo log -r (Unlanded-Revs $repo $rev $own) -T x
  if ($x.Code -ne 0) { -1 } else { $x.Out.Length }
}
function Commits-Word([int]$n) { if ($n -ge 0) { "$n commit(s)" } else { 'an unknown number of commits' } }

# Delete bookmark $bm and strip the commits only it holds. Refuses if another
# checkout is on them. hg keeps a backup bundle in the source's .hg/strip-backup.
function Strip-Bm($src, $path, $bm) {
  $set = Unlanded-Revs $path "bookmark('$bm')" $bm
  foreach ($p in (Checkouts $src)) {
    if (PathEq $p $path) { continue }
    # other checkouts may not see the bookmark, so compare by node here
    $x = HgX -R $p log -r . -T '{node}'; if ($x.Code -ne 0) { continue }
    if (Hg -R $path log -r "$($x.Out.Trim()) and descendants($set)" -T x) { Warn "not stripping ${bm}: $(Tilde $p) has those commits checked out"; return $false }
  }
  $roots = @()
  foreach ($n in (HgLines -R $path log -r "roots($set)" -T '{node}\n')) { if ($n) { $roots += @('-r', $n) } }
  if (HgOk -R $path bookmark -q -d $bm) { Disown-Bm $src $bm }
  # from the source repo, so the backup bundle outlives the share
  if ($roots.Count -gt 0 -and -not (HgOk -R $src debugstrip -q @roots)) { Warn 'strip failed'; return $false }
  Warn "stripped $bm (backup in $(Tilde $src)/.hg/strip-backup)"
  $true
}

# returns 0 ok, 1 failed, 3 unsaved work and not forced
function Core-Remove($path, $src, [int]$force = 0, [int]$strip = 0) {
  if (-not (Is-Share-Of $path $src)) { Warn "refusing: $path is not a share of $src"; return 1 }
  if ($force -ne 1 -and (Share-Unsaved $path) -gt 0) { return 3 }
  # Bookmark first: everything below can kill this popup (it may live in $path's workspace).
  $bm = Active-Bm $path
  if ($bm -and (Is-Owned-Bm $src $bm) -and -not (Bm-In-Use $src $bm $path)) {
    $n = Unlanded-Count $path "bookmark('$bm')" $bm
    if ($n -eq 0) {
      if (HgOk -R $path bookmark -q -d $bm) { Disown-Bm $src $bm; Warn "deleted bookmark $bm (landed)" }
    } elseif ($strip -eq 1 -and $n -gt 0) {
      if (-not (Strip-Bm $src $path $bm)) { return 1 }
    } else {
      $hint = if ($n -gt 0) { ' (--strip discards them)' } else { '' }
      Warn "kept bookmark ${bm}: $(Commits-Word $n) not landed$hint"
    }
  }
  $ws = Ws-For-Path $path
  Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
  $rd = Remote-CacheDir $path
  if (Test-Path -LiteralPath $rd) { Remove-Item -LiteralPath $rd -Recurse -Force -ErrorAction SilentlyContinue }
  Unrecord-Share $src $path
  $std = Join-Path $WT_ROOT (Base $src)
  if ((PathEq (ParentDir $path) $std) -and (Test-Path -LiteralPath $std) -and -not (Get-ChildItem -LiteralPath $std -Force)) { Remove-Item -LiteralPath $std -Force -ErrorAction SilentlyContinue }
  if ($ws) { Close-Ws $ws }
  0
}

# Closing the workspace this runs in (popup or pane) kills us and our output,
# so hand what we printed to a notification first.
function Close-Ws($ws) {
  if ($ws -ceq (Current-Ws) -and $script:WarnLog.Count -gt 0) {
    [void](Herdr notification show 'hg worktrees' --body ($script:WarnLog -join "`n"))
    $script:WarnLog.Clear()
  }
  [void](Herdr workspace close $ws)
  Ws-Reset
}

# Shares safe to remove without asking: no unsaved files, nothing unlanded.
function Prune-Candidates($src, [int]$includeOpen) {
  foreach ($s in (Hg-Shares $src)) {
    if ($includeOpen -ne 1 -and (Ws-For-Path $s.Path)) { continue }
    if ((Share-Unsaved $s.Path) -ne 0) { continue }
    if ((Unlanded-Count $s.Path '.' (Active-Bm $s.Path)) -ne 0) { continue }
    $s
  }
}

# Owned bookmarks no checkout uses: @{Bm; State} (State = landed|gone|N unlanded commits)
function Orphan-Bms($src) {
  foreach ($b in (Owned-Bms $src)) {
    if (-not $b) { continue }
    if (-not (Bm-Exists $src $b)) { [pscustomobject]@{ Bm = $b; State = 'gone' }; continue }
    if (Bm-In-Use $src $b '') { continue }
    $n = Unlanded-Count $src "bookmark('$b')" $b
    [pscustomobject]@{ Bm = $b; State = $(if ($n -eq 0) { 'landed' } else { "$n" }) }
  }
}

function Core-Prune($src, [int]$includeOpen, [int]$dry) {
  $n = 0
  if ($dry -ne 1) {   # forget --path shares deleted by hand
    foreach ($p in (Read-Lines (Extra-File $src))) { if ($p -and -not (Test-Path -LiteralPath $p)) { Unrecord-Share $src $p } }
  }
  foreach ($s in @(Prune-Candidates $src $includeOpen)) {
    $n++
    if ($dry -eq 1) { Warn "would remove share $(Tilde $s.Path) ($($s.Label))" }
    else { Warn "removing share $(Tilde $s.Path) ($($s.Label))"; [void](Core-Remove $s.Path $src 0 0) }
  }
  foreach ($o in @(Orphan-Bms $src)) {
    switch ($o.State) {
      'gone' { $n++; if ($dry -ne 1) { Disown-Bm $src $o.Bm } }
      'landed' {
        $n++
        if ($dry -eq 1) { Warn "would delete bookmark $($o.Bm) (landed)" }
        elseif (HgOk -R $src bookmark -q -d $o.Bm) { Disown-Bm $src $o.Bm; Warn "deleted bookmark $($o.Bm) (landed)" }
      }
      default { Warn "keeping bookmark $($o.Bm): $(Commits-Word ([int]$o.State)) not landed (hgwt open --bookmark $($o.Bm) to finish it)" }
    }
  }
  if ($n -eq 0) { Warn 'nothing to clean up' }
}

function Core-Close-Group($src) {   # closes shares, then source, then the one we run in
  $members = @(Group-Members $src); $cur = Current-Ws
  if ($members.Count -eq 0) { Warn "no open workspaces for $src"; return }
  foreach ($m in ($members | Where-Object { $_.Role -eq 'share' -and $_.Ws -cne $cur })) { Close-Ws $m.Ws }
  foreach ($m in ($members | Where-Object { $_.Role -eq 'source' -and $_.Ws -cne $cur })) { Close-Ws $m.Ws }
  # last: closing it ends this process
  if (@($members | Where-Object { $_.Ws -ceq $cur }).Count) { Close-Ws $cur }
}

# Re-label/regroup every open share workspace (after a source opened/closed).
function Relabel-All {
  foreach ($e in @(Ws-Map)) {
    if (-not $e.Cwd -or (Vcs-Of $e.Cwd) -ne 'hg') { continue }
    $r = Hg-Root $e.Cwd; $src = Source-Of-Root $r
    if (-not $src -or (PathEq $src $r)) { continue }
    $cur = Ws-Label $e.Ws
    if (-not (Is-Generated-Label $cur)) { continue }
    $want = Share-Label $r $src
    if ($cur -cne $want) { [void](Herdr workspace rename $e.Ws $want) }
    Regroup $e.Ws $src
  }
}

# --- remote (incoming) cache ----------------------------------------------------------------

function Remote-CacheDir($root) { Join-Path (Join-Path $CACHE 'remote') (Ck $root) }   # per checkout, removed with it
function Remote-File($root, $label) { Join-Path (Remote-CacheDir $root) (Ck $label) }

# cached incoming count for root / label ('' if unknown)
function Remote-Cached($root, $label) {
  $f = Remote-File $root $label
  if (-not (Test-Path -LiteralPath $f)) { return '' }
  $p = ([IO.File]::ReadAllText($f)).Trim() -split '\s+'
  if ($p.Count -ge 2) { $p[1] } else { '' }
}
function Remote-Stale($root, $label) {
  $f = Remote-File $root $label
  if ($REMOTE_MINUTES -le 0) { return $false }
  if (-not (Test-Path -LiteralPath $f)) { return $true }
  $t = [int64](([IO.File]::ReadAllText($f)).Trim() -split '\s+')[0]
  ((EpochNow) - $t) -ge ($REMOTE_MINUTES * 60)
}
function Remote-Fetch($r, $bm) {   # writes cache "epoch count|-"
  $f = Remote-File $r $bm
  [void](New-Item -ItemType Directory -Force -Path (ParentDir $f))
  if (-not (HgOk -R $r paths default)) { [IO.File]::WriteAllText($f, "$(EpochNow) -`n"); return }
  # one check at a time: focus events during a slow (offline) check would each start another
  $lock = "$f.lock"
  if ((Test-Path -LiteralPath $lock) -and ((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalMinutes -gt ($REMOTE_TIMEOUT / 30 + 2)) {
    Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue   # left by a killed refresh
  }
  try { [void](New-Item -ItemType Directory -Path $lock -ErrorAction Stop) } catch { return }
  try {
    $x = Exec $HGEXE @('-R', $r, 'incoming', '-q', '-T', 'x', '--config', 'ui.interactive=false', '-r', $bm) $REMOTE_TIMEOUT
    if ($x.Code -gt 1 -and $x.Code -ne 124) {   # bookmark unknown on remote -> compare named branch instead
      $br = Hg -R $r log -r . -T '{branch}'
      $x = Exec $HGEXE @('-R', $r, 'incoming', '-q', '-T', 'x', '--config', 'ui.interactive=false', '-b', $br) $REMOTE_TIMEOUT
    }
    $n = if ($x.Code -le 1) { [string]$x.Out.Length } else { '-' }
    [IO.File]::WriteAllText($f, "$(EpochNow) $n`n")
  } finally { Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- sidebar tokens ----------------------------------------------------------------------------

# herdr cuts long sidebar text at the end, which loses the part of a bookmark
# that usually tells shares apart (a ticket number). So shorten it ourselves:
# drop HG_BOOKMARK_STRIP, then keep the start and the end around an ellipsis.
function Herdr-Config-Text { $p = Get-HerdrConfigPath; if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllText($p) } else { '' } }
function Sidebar-Cols {
  $m = [regex]::Match((Herdr-Config-Text), '(?m)^\s*sidebar_width\s*=\s*(\d+)')
  if ($m.Success) { [int]$m.Groups[1].Value } else { 26 }
}
function Status-Shares-Row {   # does $hg_status sit on the same sidebar row as $hg_bookmark?
  foreach ($m in [regex]::Matches((Herdr-Config-Text), '\[[^\]\[]*\$hg_bookmark[^\]\[]*\]')) { if ($m.Value.Contains('$hg_status')) { return $true } }
  $false
}
function Name-Budget([int]$used) {   # columns already used on the row -> max name length (0 = no limit)
  if ($BM_MAX -eq 'auto') { $b = (Sidebar-Cols) - 7 - $used; if ($b -lt 5) { $b = 5 }; return $b }
  if ($BM_MAX -match '^\d+$') { return [int]$BM_MAX }
  0
}
function Short-Name([string]$name, [int]$max) {
  $s = $name
  if ($BM_STRIP) { try { $s = [regex]::Replace($s, $BM_STRIP, '') } catch { }; if (-not $s) { $s = $name } }
  if ($max -gt 0 -and $s.Length -gt $max) {
    $head = [int][math]::Floor(($max - 1) * 2 / 5); $tail = $max - 1 - $head
    $s = $s.Substring(0, $head) + $ELL + $s.Substring($s.Length - $tail)
  }
  $s
}

# "!op", "!op:N" or "!N": an interrupted rebase/merge/etc. and/or N unresolved files.
function Blocked-Status($r) {
  $op = ''
  foreach ($kv in 'rebase:rebasestate', 'histedit:histedit-state', 'graft:graftstate', 'unshelve:shelvedstate', 'evolve:evolvestate', 'update:updatestate') {
    $name, $file = $kv -split ':'
    if (Test-Path -LiteralPath (Join-Path $r ".hg/$file")) { $op = $name; break }
  }
  if (-not $op -and (Hg -R $r log -r 'p2()' -T x)) { $op = 'merge' }
  $n = @(HgLines -R $r resolve -l | Where-Object { $_.StartsWith('U ') }).Count
  if ($op -and $n -gt 0) { "!${op}:$n" } elseif ($op) { "!$op" } elseif ($n -gt 0) { "!$n" } else { '' }
}

# One refresh per workspace at a time. Requests that arrive meanwhile (a rebase
# fires txnclose per commit, agents settle in bursts) fold into a single rerun:
# they leave their mode in $lock/again, and the owner loops until the dir can be
# removed (it's empty only when nobody asked during its last pass).
function Refresh-Ws($ws, $cwd = '', $mode = 'cache') {
  if (-not $ws) { return }
  $lockRoot = Join-Path $CACHE 'lock'
  [void](New-Item -ItemType Directory -Force -Path $lockRoot)
  $lock = Join-Path $lockRoot ('refresh-' + (Ck $ws))
  if ((Test-Path -LiteralPath $lock) -and ((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalMinutes -gt ($REMOTE_TIMEOUT / 30 + 2)) {
    Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue   # owner was killed
  }
  $tries = 0
  while ($true) {
    try { [void](New-Item -ItemType Directory -Path $lock -ErrorAction Stop); break } catch { }
    try { Append-Line (Join-Path $lock 'again') $mode; return } catch { }   # fails only if the owner just finished
    $tries++; if ($tries -ge 3) { return }
  }
  try {
    while ($true) {
      try { Refresh-Ws-Now $ws $cwd $mode } catch { }
      try { [IO.Directory]::Delete($lock); break } catch { }
      $again = Join-Path $lock 'again'
      $txt = if (Test-Path -LiteralPath $again) { [IO.File]::ReadAllText($again) } else { '' }
      if ($txt -match 'force') { $mode = 'force' } elseif ($txt -match 'auto') { $mode = 'auto' } else { $mode = 'cache' }
      Remove-Item -LiteralPath $again -Force -ErrorAction SilentlyContinue
      $cwd = ''
    }
  } finally { if (Test-Path -LiteralPath $lock) { Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue } }
}

function Refresh-Ws-Now($ws, $cwd, $mode) {
  if (-not $cwd) { $cwd = Ws-Cwd $ws }
  if (-not $cwd -or (Vcs-Of $cwd) -ne 'hg') {
    [void](Herdr workspace report-metadata $ws --source $SOURCE --clear-token hg_bookmark --clear-token hg_status)
    return
  }
  $r = Hg-Root $cwd
  $bm = Wc-Label $r
  switch ($mode) {
    'force' { Remote-Fetch $r $bm }
    'auto' { if (Remote-Stale $r $bm) { Remote-Fetch $r $bm } }
  }
  $draft = (Hg -R $r log -r 'only(., public())' -T x).Length
  $dirty = Share-Dirty $r
  $inc = Remote-Cached $r $bm
  $status = Blocked-Status $r
  if ($draft -gt 0) { $status = ($status + " $UP$draft").Trim() }
  if ($inc -and $inc -ne '-' -and $inc -ne '0') { $status = ($status + " $DOWN$inc").Trim() }
  if ($dirty -gt 0) { $status = ($status + " *$dirty").Trim() }
  $used = 0
  if ($status -and (Status-Shares-Row)) { $used = $status.Length + 3 }
  $shown = Short-Name $bm (Name-Budget $used)
  if ($status) { [void](Herdr workspace report-metadata $ws --source $SOURCE --token "hg_bookmark=$shown" --token "hg_status=$status") }
  else { [void](Herdr workspace report-metadata $ws --source $SOURCE --token "hg_bookmark=$shown" --clear-token hg_status) }
  # keep generated share labels in sync with the bookmark
  $src = Source-Of-Root $r
  if ($src -and -not (PathEq $src $r)) {
    $cur = Ws-Label $ws
    if (Is-Generated-Label $cur) {
      $want = Share-Label $r $src
      if ($cur -cne $want) { [void](Herdr workspace rename $ws $want) }
    }
  }
}

function Walk-Json($o, [scriptblock]$visit) {
  if ($null -eq $o) { return }
  if ($o -is [string]) { & $visit $o $null; return }
  if ($o -is [System.Collections.IEnumerable]) { foreach ($i in $o) { Walk-Json $i $visit }; return }
  if ($o -is [pscustomobject]) { foreach ($p in $o.PSObject.Properties) { & $visit $p.Value $p.Name; Walk-Json $p.Value $visit } }
}
function Event-Json { if ($env:HERDR_PLUGIN_EVENT_JSON) { try { $env:HERDR_PLUGIN_EVENT_JSON | ConvertFrom-Json } catch { $null } } else { $null } }
function Event-Ws {
  $j = Event-Json; if (-not $j) { return '' }
  $script:found = @{ ws = ''; pane = '' }
  Walk-Json $j { param($v, $name)
    if ($name -eq 'workspace_id' -and -not $script:found.ws -and $v -is [string]) { $script:found.ws = $v }
    if ($name -eq 'pane_id' -and -not $script:found.pane -and $v -is [string]) { $script:found.pane = $v }
  }
  if ($script:found.ws) { $script:found.ws } elseif ($script:found.pane) { $script:found.pane -replace ':.*$', '' } else { '' }
}

function Cmd-Refresh([string[]]$a) {
  $what = if ($a.Count -gt 0) { $a[0] } else { '' }
  $arg = if ($a.Count -gt 1) { $a[1] } else { '' }
  $mode = 'cache'
  foreach ($x in $a) { if ($x -in 'auto', 'force', 'cache') { $mode = $x } }
  switch ($what) {
    '--all' { foreach ($e in @(Ws-Map)) { Refresh-Ws $e.Ws $e.Cwd $mode } }
    '--event' {
      switch ($env:HERDR_PLUGIN_EVENT) {
        { $_ -in 'workspace.closed', 'workspace.created' } {   # a source opening/closing changes share labels
          Ws-Reset; Relabel-All
          if ($env:HERDR_PLUGIN_EVENT -eq 'workspace.created') { Refresh-Ws (Event-Ws) '' 'cache' }
        }
        'pane.agent_status_changed' {
          $script:hit = $false
          Walk-Json (Event-Json) { param($v, $name) if ($v -is [string] -and $v -in 'idle', 'done', 'blocked') { $script:hit = $true } }
          if ($script:hit) { Refresh-Ws (Event-Ws) '' 'cache' }
        }
        default { Refresh-Ws (Event-Ws) '' 'auto' }
      }
    }
    '--workspace' { Refresh-Ws $arg '' $mode }
    '--cwd' {   # from ~/.hgrc hooks; the hg command may target any repo (hg -R, cd), so
                # refresh whichever workspaces have that repo open. pull/push refetch remote.
      if (-not ($env:HERDR_ENV -or $env:HERDR_WORKSPACE_ID)) { return }
      if ($env:HG_TXNNAME -match '^(pull|push|unbundle)') { $mode = 'force' }
      $r = Hg-Root $arg; if (-not $r) { return }
      foreach ($e in @(Ws-Map)) { if ($e.Cwd -and (PathUnder $e.Cwd $r)) { Refresh-Ws $e.Ws $e.Cwd $mode } }
    }
    default { Refresh-Ws (Current-Ws) '' $mode }
  }
}

# --- popup UI -------------------------------------------------------------------------------------

function Say([string]$s = '') { [Console]::Out.WriteLine($s) }
function Pause-Ui([string]$m = "Press enter to close$ELL") { [Console]::Out.Write("`n$m"); [void][Console]::In.ReadLine() }
function Ask([string]$prompt) { [Console]::Out.Write($prompt); $a = [Console]::In.ReadLine(); if ($null -eq $a) { '' } else { $a } }

# Numbered picker over "value`tdisplay" strings; returns the chosen value or $null.
function Pick($lines) {
  $lines = @($lines)
  if ($lines.Count -eq 0) { Say '  (none)'; Pause-Ui; return $null }
  for ($i = 0; $i -lt $lines.Count; $i++) { Say ('  {0,2}) {1}' -f ($i + 1), ($lines[$i] -split "`t", 2)[1]) }
  $c = Ask "`nChoose [1-$($lines.Count), empty to cancel]: "
  if ($c -notmatch '^\d+$') { return $null }
  $n = [int]$c; if ($n -lt 1 -or $n -gt $lines.Count) { return $null }
  ($lines[$n - 1] -split "`t", 2)[0]
}

function Share-Menu($src, [int]$withSource) {
  if ($withSource -eq 1) {
    $open = if (Ws-For-Path $src) { '  [open]' } else { '' }
    "$src`t$(Base $src)  (source)$open"
  }
  foreach ($s in (Hg-Shares $src)) {
    $open = if (Ws-For-Path $s.Path) { '  [open]' } else { '' }
    "$($s.Path)`t$($s.Label)  $(Tilde $s.Path)$open"
  }
}

function Ui-New {
  $cwd = Current-Cwd; $vcs = Vcs-Of $cwd
  if ($vcs -eq 'none') { Say "Not inside an hg or git repository: $cwd"; Pause-Ui; return }
  if ($vcs -eq 'git') {
    Say "git repo: $(Git -C $cwd rev-parse --show-toplevel)"
    $name = Ask 'Branch: '; if (-not $name) { return }
    $base = Ask 'Base ref [HEAD]: '
    $a = @('worktree', 'create', '--cwd', $cwd, '--branch', $name); if ($base) { $a += @('--base', $base) }; $a += '--focus'
    if ((Herdr @a).Code -ne 0) { Pause-Ui "git worktree create failed - enter to close$ELL" }
    return
  }
  $src = Hg-Source-Root $cwd
  Say "hg repo: $(Tilde $src)"
  $name = Ask 'Bookmark: '; if (-not $name) { return }
  $base = ''
  if (Find-Share $src $name) { Say "Share for $name already exists, opening it." }
  elseif (Bm-Exists $src $name) { Say 'Bookmark exists; the share will check it out.' }
  elseif (Branch-Exists $src $name) { Say 'Named branch exists; the share will check out its head.' }
  else {
    $base = Ask 'Base revision [.]: '
    if (-not $base -or $base -eq '.') { $base = Hg -R (Hg-Root $cwd) log -r . -T '{node}' }
  }
  $dest = Core-Create $src $name $base
  if (-not $dest) { Pause-Ui "Failed - enter to close$ELL"; return }
  if (-not (Core-Open $dest $src)) { Pause-Ui "Failed - enter to close$ELL" }
}

function Ui-Open {
  $cwd = Current-Cwd; $vcs = Vcs-Of $cwd
  if ($vcs -eq 'none') { Say "Not inside an hg or git repository: $cwd"; Pause-Ui; return }
  if ($vcs -eq 'git') {
    Say 'git worktrees:'
    $j = HerdrJson worktree list --cwd $cwd
    $rows = @(); if ($j) { $rows = @($j.result.worktrees | ForEach-Object { $b = if ($_.branch) { $_.branch } else { '(detached)' }; "$($_.path)`t$b  $($_.path)" }) }
    $path = Pick $rows; if (-not $path) { return }
    if ((Herdr worktree open --cwd $cwd --path $path --focus).Code -ne 0) { Pause-Ui "open failed$ELL" }
    return
  }
  $src = Hg-Source-Root $cwd
  Say "hg shares of $(Tilde $src):"
  $path = Pick (Share-Menu $src 1); if (-not $path) { return }
  if (-not (Core-Open $path $src)) { Pause-Ui "Failed - enter to close$ELL" }
}

function Ui-Remove {
  $cwd = Current-Cwd; $vcs = Vcs-Of $cwd
  if ($vcs -eq 'none') { Say "Not inside an hg or git repository: $cwd"; Pause-Ui; return }
  if ($vcs -eq 'git') {
    $ans = Ask "Remove git worktree for workspace $(Current-Ws)? [y/N] "; if ($ans -ne 'y') { return }
    if ((Herdr worktree remove --workspace (Current-Ws)).Code -ne 0) { Pause-Ui "remove failed$ELL" }
    return
  }
  $src = Hg-Source-Root $cwd; $r = Hg-Root $cwd
  if (-not (PathEq $r $src)) { $path = $r; Say "Current workspace is a share: $(Tilde $path)" }
  else { Say "hg shares of $(Tilde $src):"; $path = Pick (Share-Menu $src 0); if (-not $path) { return } }
  $force = 0; $strip = 0
  $un = Share-Unsaved $path
  if ($un -gt 0) {
    Unsaved-List $path | ForEach-Object { Say $_ }
    $ans = Ask "`n$un uncommitted/untracked file(s) will be lost. Type ""discard"" to remove anyway: "
    if ($ans -ne 'discard') { return }
    $force = 1
  }
  $bm = Active-Bm $path
  if ($bm -and (Is-Owned-Bm $src $bm) -and -not (Bm-In-Use $src $bm $path)) {
    $n = Unlanded-Count $path "bookmark('$bm')" $bm
    if ($n -eq 0) { Say "Bookmark $bm has landed; it will be deleted too." }
    elseif ($n -lt 0) { Say "Can't tell whether bookmark $bm has landed; it will be kept." }
    else {
      Say "`nOnly bookmark $bm holds these $n commit(s):"
      foreach ($l in (HgLines -R $path log -r (Unlanded-Revs $path "bookmark('$bm')" $bm) -T '  {node|short} {desc|firstline}\n')) { Say $l }
      $ans = Ask "`nEnter keeps the bookmark (reopen it later). Type ""strip"" to delete them: "
      if ($ans -eq 'strip') { $strip = 1 }
    }
  }
  if ($force -eq 0 -and $strip -eq 0) { $ans = Ask "Remove share $(Tilde $path)? [y/N] "; if ($ans -ne 'y') { return } }
  $rc = Core-Remove $path $src 1 $strip
  if ($rc -ne 0) { Pause-Ui "Failed - enter to close$ELL" }
}

# Lines describing what Core-Prune would do (empty when nothing).
function Prune-Preview($src, [int]$includeOpen) {
  foreach ($s in @(Prune-Candidates $src $includeOpen)) { '  remove share   {0} ({1})' -f (Tilde $s.Path), $s.Label }
  foreach ($o in @(Orphan-Bms $src)) {
    switch ($o.State) {
      'landed' { "  delete bookmark $($o.Bm) (landed)" }
      'gone' { }
      default { "  keep bookmark   $($o.Bm) ($(Commits-Word ([int]$o.State)) not landed)" }
    }
  }
}

function Ui-Prune {
  $cwd = Current-Cwd
  if ((Vcs-Of $cwd) -ne 'hg') { Say "Not inside an hg repository: $cwd"; Pause-Ui; return }
  $src = Hg-Source-Root $cwd
  Say "Clean up $(Tilde $src) (closed shares with no unsaved files and nothing unlanded):"
  $preview = @(Prune-Preview $src 0)
  if (-not ($preview | Where-Object { $_ -match '^  (remove|delete)' })) { $preview | ForEach-Object { Say $_ }; Say '  nothing to remove'; Pause-Ui; return }
  $preview | ForEach-Object { Say $_ }
  $ans = Ask "`nGo ahead? [y/N] "; if ($ans -ne 'y') { return }
  Core-Prune $src 0 0; Pause-Ui
}

function Ui-Close-Group {
  $cwd = Current-Cwd
  if ((Vcs-Of $cwd) -ne 'hg') { Say 'Not inside an hg repository (for git use: herdr workspace close --group)'; Pause-Ui; return }
  $src = Hg-Source-Root $cwd; $members = @(Group-Members $src)
  Say "Open workspaces for $(Tilde $src):"
  foreach ($m in $members) { Say ('  {0,-4} {1,-7} {2}' -f $m.Ws, $m.Role, (Tilde $m.Path)) }
  $ans = Ask "`nClose these $($members.Count) workspace(s)? Running processes in them stop; files stay. [y/N] "
  if ($ans -ne 'y') { return }
  # Offer cleanup before closing: closing may take this popup with it.
  $preview = @(Prune-Preview $src 1)
  if ($preview | Where-Object { $_ -match '^  (remove|delete)' }) {
    Say "`nAlso clean up?"; $preview | ForEach-Object { Say $_ }
    $ans = Ask "`nRemove/delete the above? [y/N] "
    if ($ans -eq 'y') { Core-Prune $src 1 0 }
  }
  Core-Close-Group $src
}

# --- details popup / hgwt info ----------------------------------------------------------------------
# Everything the sidebar can't fit. Local only, unless fetch=1 (incoming list).

function Remote-Age($root, $label) {
  $f = Remote-File $root $label; if (-not (Test-Path -LiteralPath $f)) { return '' }
  $t = [int64](([IO.File]::ReadAllText($f)).Trim() -split '\s+')[0]
  "$([int][math]::Floor(((EpochNow) - $t) / 60)) min ago"
}

function Cmd-Info([string]$dir, [int]$fetch = 0) {   # returns the text
  $o = New-Object System.Collections.ArrayList
  function Add-L($s) { [void]$o.Add([string]$s) }
  function Hdr($t) { Add-L ''; Add-L "$ESC[1m$t$ESC[0m" }
  function Kv($k, $v) { if ($v) { Add-L ('  {0,-11} {1}' -f $k, $v) } }
  function MoreLines($lines, [int]$m) {
    $lines = @($lines)
    $lines | Select-Object -First $m | ForEach-Object { Add-L $_ }
    if ($lines.Count -gt $m) { Add-L ("  $ELL and {0} more" -f ($lines.Count - $m)) }
  }
  $r = Hg-Root $dir; $src = Source-Of-Root $r; $bm = Active-Bm $r; $br = Hg -R $r branch
  Add-L "$ESC[1m$(Tilde $r)$ESC[0m"
  if (PathEq $r $src) { Kv 'repo' 'source repo' } else { Kv 'repo' "share of $(Tilde $src)" }
  $x = ''
  if ($bm -and (Is-Owned-Bm $src $bm)) {
    $n = Unlanded-Count $r "bookmark('$bm')" $bm
    if ($n -eq 0) { $x = '  (made by hgwt, landed: removing the share deletes it)' } else { $x = "  (made by hgwt, $(Commits-Word $n) not landed elsewhere)" }
  }
  Kv 'bookmark' ($(if ($bm) { $bm } else { '(none active)' }) + $x)
  $curBr = Hg -R $r log -r . -T '{branch}'
  Kv 'branch' ($br + $(if ($curBr -ne $br) { '  (new, starts with the next commit)' } else { '' }))
  $n = (Hg -R $r heads -T x $br).Length
  if ($n -gt 1) { Kv 'heads' "$n heads on $br (hg heads $br)" }
  Kv 'topic' (Hg -R $r log -r . -T '{topic}')
  $also = (Hg -R $r log -r . -T '{join(bookmarks, " ")}') -split ' ' | Where-Object { $_ -and $_ -cne $bm }
  Kv 'also here' ($also -join ' ')
  $tags = (Hg -R $r log -r . -T '{join(tags, " ")}') -split ' ' | Where-Object { $_ -and $_ -ne 'tip' }
  Kv 'tags' ($tags -join ' ')

  Hdr 'Working copy parent'
  foreach ($l in (HgLines -R $r log -r . -T ('  {rev}:{node|short}  {phase}\n  {desc|firstline}\n  {author|person} ' + $MID + ' {date|age} ' + $MID + ' {date|isodate}\n'))) { Add-L $l }
  foreach ($l in (HgLines -R $r log -r 'p2()' -T '  merging with {rev}:{node|short} {desc|firstline}\n')) { if ($l) { Add-L $l } }
  $x = Hg -R $r log -r 'p1(.)' -T '{rev}:{node|short} {desc|firstline}'
  if ($x) { Add-L "  parent of that: $x" }

  $x = Blocked-Status $r
  if ($x) {
    Hdr "In progress: $x"
    MoreLines (HgLines -R $r resolve -l | ForEach-Object { "  $_" }) 15
    switch -Wildcard ($x) {
      '!rebase*' { Add-L '  hg rebase --continue | --abort' }
      '!histedit*' { Add-L '  hg histedit --continue | --abort' }
      '!graft*' { Add-L '  hg graft --continue | --abort' }
      '!unshelve*' { Add-L '  hg unshelve --continue | --abort' }
      '!merge*' { Add-L '  hg commit to finish, hg update -C . to abandon' }
      '!update*' { Add-L '  hg update to finish the interrupted update' }
    }
  }

  $n = Share-Dirty $r; $u = @(HgLines -R $r status -u).Count
  Hdr ("Changed files (*$n" + $(if ($u -gt 0) { " $MID $u untracked" } else { '' }) + ')')
  if ($n -gt 0 -or $u -gt 0) { MoreLines (HgLines -R $r status -mardu | ForEach-Object { "  $_" }) 15 } else { Add-L '  clean' }

  $n = (Hg -R $r log -r 'only(., public())' -T x).Length
  Hdr "Not pushed ($UP$n draft)"
  if ($n -gt 0) { MoreLines (HgLines -R $r log -r 'reverse(only(., public()))' -T ('  {node|short} {desc|firstline} ' + $MID + ' {date|age}\n') | Where-Object { $_ }) 10 } else { Add-L '  nothing' }

  Hdr 'Remote'
  $paths = @(HgLines -R $r paths)
  if ($paths.Count -eq 0) { Add-L '  no paths configured' }
  else {
    $paths | ForEach-Object { Add-L "  $_" }
    $label = Wc-Label $r; $lst = @()
    if ($fetch -eq 1) {
      Add-L "  checking incoming for $label$ELL"
      Remote-Fetch $r $label
      # remote unreachable: don't wait out two more timeouts just to list nothing
      if ((Remote-Cached $r $label) -ne '-') {
        $tpl = '  {node|short} {desc|firstline} ' + $MID + ' {author|person} ' + $MID + ' {date|age}\n'
        $y = Exec $HGEXE @('-R', $r, 'incoming', '-q', '--config', 'ui.interactive=false', '-r', $label, '-T', $tpl) $REMOTE_TIMEOUT
        $lst = @($y.Out -split "\r?\n" | Where-Object { $_ })
        if ($lst.Count -eq 0) {
          $y = Exec $HGEXE @('-R', $r, 'incoming', '-q', '--config', 'ui.interactive=false', '-b', $br, '-T', $tpl) $REMOTE_TIMEOUT
          $lst = @($y.Out -split "\r?\n" | Where-Object { $_ })
        }
      }
    }
    $inc = Remote-Cached $r $label; $age = Remote-Age $r $label
    if ($inc -eq '') { Add-L '  incoming: not checked yet' }
    elseif ($inc -eq '-') { Add-L "  incoming: couldn't check (auth, network or no such bookmark/branch) $MID $age" }
    else { Add-L "  incoming ($DOWN$inc) for $label $MID checked $age" }
    if ($fetch -eq 1 -and $lst.Count -gt 0) { MoreLines $lst 10 }
  }

  $shelves = @(HgLines -R $r shelve -l)
  if ($shelves.Count -gt 0) { Hdr "Shelves ($($shelves.Count))"; MoreLines ($shelves | ForEach-Object { "  $_" }) 5 }

  $shares = @(Hg-Shares $src)
  if ($shares.Count -gt 0 -or -not (PathEq $r $src)) {
    Hdr "Checkouts of $(Base $src)"
    $rows = @([pscustomobject]@{ Path = $src; Label = (Wc-Label $src) }) + $shares
    foreach ($s in $rows) {
      $mark = if (PathEq $s.Path $r) { $CUR } else { ' ' }
      $open = if (Ws-For-Path $s.Path) { '  [open]' } else { '' }
      Add-L ('  {0} {1,-24} {2}{3}' -f $mark, $s.Label, (Tilde $s.Path), $open)
    }
  }
  , @($o)
}

function Git-Info([string]$dir) {
  $g = Git -C $dir rev-parse --show-toplevel
  $o = @("$ESC[1m$(Tilde $g)$ESC[0m  (git)", '')
  $o += @((Git -C $g status -sb) -split "\r?\n" | Select-Object -First 20 | ForEach-Object { "  $_" })
  $o += ''
  $o += @((Git -C $g log -1 ('--format=  %h %s%n  %an ' + $MID + ' %ar ' + $MID + ' %ci')) -split "\r?\n")
  $o += ''
  $o += @((Git -C $g remote -v) -split "\r?\n" | Where-Object { $_ -match '\(fetch\)\s*$' } | ForEach-Object { "  $_" })
  , $o
}

function Show-Text($lines) {
  $lines = @($lines)
  $rows = 40; try { $rows = [Console]::WindowHeight } catch { }
  Say ''  # fresh line
  try { [Console]::Clear() } catch { }
  if ($lines.Count -gt $rows - 2 -and (Get-Command less -CommandType Application -ErrorAction SilentlyContinue)) {
    $tmp = [IO.Path]::GetTempFileName()
    try { [IO.File]::WriteAllText($tmp, ($lines -join "`n") + "`n"); & less -R -X $tmp } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  } else { $lines | ForEach-Object { Say $_ } }
}

function Ui-Info {
  $cwd = Current-Cwd; $fetch = 0
  while ($true) {
    switch (Vcs-Of $cwd) {
      'hg' { $out = Cmd-Info $cwd $fetch }
      'git' { Show-Text (Git-Info $cwd); Pause-Ui; return }
      default { Say "Not inside an hg or git repository: $cwd"; Pause-Ui; return }
    }
    if ($fetch -ne 0) { try { Refresh-Ws (Current-Ws) '' 'cache' } catch { } }   # sidebar picks up the new incoming count
    Show-Text $out
    $ans = Ask "`n[f] check incoming now $MID enter to close: "
    if ($ans -ne 'f') { return }
    $fetch = 1
  }
}

# --- CLI --------------------------------------------------------------------------------------------------

$script:CLI = $null
function Parse-Cli([string[]]$a) {
  $c = @{ Cwd = (Get-Location).ProviderPath; Bm = ''; Base = ''; Path = ''; Force = 0; Json = 0; Strip = 0; Dry = 0; Prune = 0; Label = ''; Fetch = 0 }
  $ws = ''
  for ($i = 0; $i -lt $a.Count; $i++) {
    switch ($a[$i]) {
      '--cwd' { $c.Cwd = $a[++$i] }
      { $_ -in '--bookmark', '-b' } { $c.Bm = $a[++$i] }
      { $_ -in '--base', '-r' } { $c.Base = $a[++$i] }
      '--path' { $c.Path = $a[++$i] }   # resolved per command: create may name a new dir
      '--label' { $c.Label = $a[++$i] }
      '--workspace' { $ws = $a[++$i] }
      { $_ -in '--force', '-f' } { $c.Force = 1 }
      '--json' { $c.Json = 1 }
      '--strip' { $c.Strip = 1 }
      { $_ -in '--dry-run', '-n' } { $c.Dry = 1 }
      '--prune' { $c.Prune = 1 }
      '--fetch' { $c.Fetch = 1 }
      '--no-focus' { $env:HGWT_FOCUS = '0' }
      '--focus' { $env:HGWT_FOCUS = '1' }
      default { Die "unknown option: $($a[$i])" }
    }
  }
  if ($ws) { $c.Cwd = Ws-Cwd $ws; if (-not $c.Cwd) { Die "no workspace $ws" } }
  if ((Vcs-Of $c.Cwd) -ne 'hg') { Die "not inside an hg repository: $($c.Cwd) (for git use: herdr worktree)" }
  $c.Src = Hg-Source-Root $c.Cwd
  $script:CLI = $c
}

function Cli-Target {   # resolve --path/--bookmark/current share
  $c = $script:CLI
  if ($c.Path) { if (Test-Path -LiteralPath $c.Path -PathType Container) { return (Real-Path $c.Path) } else { Die "no such directory: $($c.Path)" } }
  if ($c.Bm) { $p = Find-Share $c.Src $c.Bm; if ($p) { return $p } else { Die "no share for '$($c.Bm)'" } }
  $r = Hg-Root $c.Cwd
  if (PathEq $r $c.Src) { Die 'specify --bookmark or --path' }
  $r
}

function Invoke-Cli([string]$cmd, [string[]]$rest) {
  Parse-Cli $rest
  $c = $script:CLI
  switch ($cmd) {
    'list' {
      if ($c.Json -eq 1) {
        $rows = @([pscustomobject]@{ Path = $c.Src; Label = (Wc-Label $c.Src) }) + @(Hg-Shares $c.Src)
        $items = @($rows | ForEach-Object {
          $w = Ws-For-Path $_.Path
          [ordered]@{ path = $_.Path; bookmark = $_.Label; source = (PathEq $_.Path $c.Src); workspace_id = $(if ($w) { $w } else { $null }) }
        })
        $shares = @(); if ($items.Count -gt 1) { $shares = @($items[1..($items.Count - 1)]) }
        $o = [ordered]@{ source = $items[0].path; shares = $shares; source_workspace_id = $items[0].workspace_id }
        Say ($o | ConvertTo-Json -Compress -Depth 5)
      } else {
        Say ("{0}`t{1}`t(source)" -f (Wc-Label $c.Src), $c.Src)
        foreach ($s in (Hg-Shares $c.Src)) { Say ("{0}`t{1}`t{2}" -f $s.Label, $s.Path, (Ws-For-Path $s.Path)) }
      }
    }
    'create' {
      if (-not $c.Bm) { Die '--bookmark required' }
      $dest = Core-Create $c.Src $c.Bm $c.Base $c.Path
      if (-not $dest) { exit 1 }
      $ws = Core-Open $dest $c.Src $c.Label
      Say ([ordered]@{ workspace_id = $ws; path = $dest } | ConvertTo-Json -Compress)
    }
    'open' {
      $t = Cli-Target
      $ws = Core-Open $t $c.Src $c.Label
      Say ([ordered]@{ workspace_id = $ws; path = $t } | ConvertTo-Json -Compress)
    }
    'remove' {
      $t = Cli-Target
      $rc = Core-Remove $t $c.Src $c.Force $c.Strip
      if ($rc -eq 3) { Die "$t has uncommitted changes or untracked files (use --force to discard)" }
      exit $rc
    }
    'prune' { Core-Prune $c.Src 0 $c.Dry }
    'info' { (Cmd-Info $c.Cwd $c.Fetch) | ForEach-Object { Say $_ } }
    'close-group' { if ($c.Prune -eq 1) { Core-Prune $c.Src 1 0 }; Core-Close-Group $c.Src }
  }
}

# --- main ------------------------------------------------------------------------------------------------------

function Setup-Script-Path { Join-Path $script:BinDir 'hgwt-setup.ps1' }
function Invoke-Setup([string[]]$a) {
  $ps = if ($script:Win) { 'powershell.exe' } else { 'pwsh' }
  $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Setup-Script-Path)) + $a
  & $ps @args2 | Out-Host
  [int]$global:LASTEXITCODE
}

$cmd = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
[string[]]$rest = @(if ($args.Count -gt 1) { $args[1..($args.Count - 1)] })

switch ($cmd) {
  { $_ -in 'list', 'create', 'open', 'remove', 'prune', 'close-group', 'info' } { Invoke-Cli $cmd $rest }
  'action' {
    $id = if ($rest.Count -gt 0) { $rest[0] } else { Die 'usage: hgwt action new|open|remove|prune|close-group|info|setup' }
    $ep = if ($id.EndsWith('-win')) { $id } elseif ($script:Win) { "$id-win" } else { $id }   # Windows panes carry a -win suffix (herdr rejects duplicate ids)
    [void](Herdr plugin pane open --plugin $PLUGIN_ID --entrypoint $ep)
  }
  'ui' {
    switch ($(if ($rest.Count -gt 0) { $rest[0] } else { '' })) {
      'new' { Ui-New } 'open' { Ui-Open } 'remove' { Ui-Remove } 'prune' { Ui-Prune }
      'close-group' { Ui-Close-Group } 'info' { Ui-Info }
      'setup' { [void](Invoke-Setup @()); Pause-Ui }
      default { Die 'usage: hgwt ui new|open|remove|prune|close-group|info|setup' }
    }
  }
  'refresh' {
    $script:BG = $true
    try { Cmd-Refresh $rest } catch { }
  }
  'setup' { exit (Invoke-Setup $rest) }
  'startup' {   # herdr startup hook: restore sidebar tokens + grouping, nudge once if not set up
    $script:BG = $true
    try { Cmd-Refresh @('--all', 'auto') } catch { }
    try { Relabel-All } catch { }
    $st = Invoke-Setup @('--status')
    if ($st -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $env:HERDR_PLUGIN_CONFIG_DIR '.setup-dismissed'))) {
      [void](Herdr notification show 'hg worktrees: finish setup' --body "Run the 'Set up hg worktrees' action, or: herdr plugin action invoke $PLUGIN_ID.setup-win")
    }
  }
  { $_ -in '-h', '--help', 'help', '' } {
    [IO.File]::ReadAllLines($script:Self) | Select-Object -Skip 1 -First 19 | ForEach-Object { $_ -replace '^# ?', '' } | ForEach-Object { Say $_ }
  }
  default { Die "unknown command: $cmd (try: hgwt help)" }
}
