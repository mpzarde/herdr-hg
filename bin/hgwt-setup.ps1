# hgwt-setup.ps1 - wire herdr-hg into herdr's config.toml and ~/.hgrc. Idempotent.
# PowerShell port of bin/hgwt-setup for Windows (Windows PowerShell 5.1 and PowerShell 7+).
#
#   hgwt-setup [--yes]        apply (asks first unless --yes)
#   hgwt-setup --uninstall    remove everything setup added
#   hgwt-setup --status       exit 0 if set up, 1 if not
#   hgwt-setup --dismiss      stop the startup "run setup" reminder
#
# Everything added is fenced by "herdr-hg" markers so it can be found and removed.
# Files are backed up to <file>.herdr-hg.bak before each change; if herdr rejects
# the new config, the backup is restored.

$ErrorActionPreference = 'Stop'
$script:Win = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($PSVersionTable.PSObject.Properties['Platform'] -and $PSVersionTable.Platform -eq 'Win32NT')
$script:Self = $MyInvocation.MyCommand.Path
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$PLUGIN_ID = 'mpzarde.hg-worktree'
$BEGIN = '# >>> herdr-hg (managed by hgwt-setup; remove with: hgwt-setup --uninstall) >>>'
$END = '# <<< herdr-hg <<<'
$TAG = '# herdr-hg'
# herdr rejects duplicate ids, so the Windows entries in herdr-plugin.toml carry a -win suffix
$SUFFIX = if ($script:Win) { '-win' } else { '' }

$HOMEDIR = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
function Herdr-Bin { if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { 'herdr' } }
function Run-Native([string]$exe, [string[]]$a, [int]$timeout = 0) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $c = Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  $psi.FileName = if ($c) { $c.Source } else { $exe }
  $psi.Arguments = ($a | ForEach-Object { if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $_ } }) -join ' '
  $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  try { $p = [System.Diagnostics.Process]::Start($psi) } catch { return [pscustomobject]@{ Out = ''; Err = "$_"; Code = 127 } }
  $p.StandardInput.Close()
  $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
  if ($timeout -gt 0) { if (-not $p.WaitForExit($timeout * 1000)) { try { $p.Kill() } catch { }; return [pscustomobject]@{ Out = ''; Err = 'timeout'; Code = 124 } } } else { $p.WaitForExit() }
  $p.WaitForExit()
  [void]$so.Wait(3000); [void]$se.Wait(3000)
  [pscustomobject]@{ Out = $so.Result; Err = $se.Result; Code = $p.ExitCode }
}
function Herdr { Run-Native (Herdr-Bin) ([string[]]$args) 15 }

if ($env:HERDR_CONFIG_PATH) { $HERDR_CONFIG = $env:HERDR_CONFIG_PATH }
elseif ($script:Win -and $env:APPDATA) { $HERDR_CONFIG = Join-Path $env:APPDATA 'herdr\config.toml' }
else { $HERDR_CONFIG = Join-Path (Join-Path (Join-Path $(if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOMEDIR '.config' }) 'herdr') '') 'config.toml' }
$HGRC = if ($env:HGRCPATH_USER) { $env:HGRCPATH_USER } else { Join-Path $HOMEDIR '.hgrc' }

$CONFIG_DIR = $env:HERDR_PLUGIN_CONFIG_DIR
if (-not $CONFIG_DIR) { $r = Herdr plugin config-dir $PLUGIN_ID; if ($r.Code -eq 0) { $CONFIG_DIR = $r.Out.Trim() } }
if (-not $CONFIG_DIR) { [Console]::Error.WriteLine("hgwt-setup: plugin $PLUGIN_ID is not linked/installed in herdr"); exit 1 }
$HOOK = Join-Path $CONFIG_DIR 'hg-hook.ps1'
$SHIM_PS = Join-Path $CONFIG_DIR 'hgwt-shim.ps1'
# CLI shim goes in ~/.local/bin if it's on PATH
$BIN_DIR = if ($env:HGWT_BIN_DIR) { $env:HGWT_BIN_DIR } else { Join-Path (Join-Path $HOMEDIR '.local') 'bin' }
$SHIM = Join-Path $BIN_DIR 'hgwt.cmd'
$SHIM_MARK = 'rem hgwt shim (managed by herdr-hg setup)'

# Keys this plugin wants. Override in $CONFIG_DIR\config.env (KEY=VALUE lines) before running setup.
$cfgEnv = Join-Path $CONFIG_DIR 'config.env'
$envFile = @{}
if (Test-Path -LiteralPath $cfgEnv) {
  foreach ($l in [IO.File]::ReadAllLines($cfgEnv)) {
    if ($l -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*?)\s*$') {
      $v = $Matches[2]
      if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) { $v = $v.Substring(1, $v.Length - 2) }
      $envFile[$Matches[1]] = $v
    }
  }
}
function Cfg($name, $default) {
  $v = [Environment]::GetEnvironmentVariable($name); if ($v) { return $v }
  if ($envFile.ContainsKey($name)) { return $envFile[$name] }
  $default
}
$KEY_NEW = Cfg 'HGWT_KEY_NEW' 'prefix+shift+g'
$KEY_OPEN = Cfg 'HGWT_KEY_OPEN' 'prefix+shift+o'
$KEY_REMOVE = Cfg 'HGWT_KEY_REMOVE' 'prefix+shift+y'
$KEY_CLOSE_GROUP = Cfg 'HGWT_KEY_CLOSE_GROUP' 'prefix+shift+c'
$KEY_INFO = Cfg 'HGWT_KEY_INFO' 'prefix+shift+i'
$KEY_GIT_NATIVE = Cfg 'HGWT_KEY_GIT_NATIVE' 'prefix+alt+g'   # where herdr's own new_worktree moves
$ROWS = '[["state_icon", "workspace"], ["branch", "git_status", "$hg_bookmark", "$hg_status"]]'

# --- helpers ---------------------------------------------------------------------

$UTF8 = New-Object System.Text.UTF8Encoding($false)
function Read-Text([string]$f) { if (Test-Path -LiteralPath $f -PathType Leaf) { [IO.File]::ReadAllText($f) } else { '' } }
function To-Lines([string]$t) { if ($t -eq '') { @() } else { @(($t -replace "`r`n", "`n").TrimEnd("`n") -split "`n") } }
function Lines-Text($lines) { $lines = @($lines); if ($lines.Count -eq 0) { '' } else { ($lines -join "`n") + "`n" } }
# files keep the line endings they had; candidates are built with LF and converted on write
function Write-Keep-Eol([string]$f, [string]$lfText) {
  $old = Read-Text $f
  $t = if ($old.Contains("`r`n")) { $lfText -replace "`n", "`r`n" } else { $lfText }
  $dir = Split-Path -Parent $f; if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
  [IO.File]::WriteAllText($f, $t, $UTF8)
}
function Norm([string]$t) { $t -replace "`r`n", "`n" }

# file -> lines without our block or tagged lines; trailing blank lines dropped
function Strip-Managed([string]$file) {
  $out = New-Object System.Collections.ArrayList; $blanks = @(); $skip = $false
  foreach ($l in (To-Lines (Read-Text $file))) {
    if ($l -ceq $BEGIN) { $skip = $true; continue }
    if ($l -ceq $END) { $skip = $false; continue }
    if ($skip) { continue }
    if ($l.Contains($TAG) -and $l -match '# herdr-hg$') { continue }
    if ($l -match '^\s*$') { $blanks += $l; continue }
    foreach ($b in $blanks) { [void]$out.Add($b) }; $blanks = @()
    [void]$out.Add($l)
  }
  , @($out)
}

function Strip-Hdr([string]$l) { ($l -replace '\s*#.*$', '') -replace '\s', '' }
function Has-Table($hdr, $lines) { foreach ($l in $lines) { if ($l -match "^\s*\[$([regex]::Escape($hdr))\]\s*(#.*)?$") { return $true } }; $false }
# insert $line right after the [$hdr] header
function Insert-After-Table($hdr, $lines, $line) {
  $out = New-Object System.Collections.ArrayList; $done = $false
  foreach ($l in $lines) {
    [void]$out.Add($l)
    if (-not $done -and (Strip-Hdr $l) -ceq "[$hdr]") { [void]$out.Add($line); $done = $true }
  }
  , @($out)
}
# does table [$hdr] already set key (regex) $key?
function Table-Sets($hdr, $lines, $key) {
  $inT = $false
  foreach ($l in $lines) {
    $h = Strip-Hdr $l
    if ($h -match '^\[') { $inT = ($h -ceq "[$hdr]"); continue }
    if ($inT -and $l -match "^\s*$key\s*=") { return $true }
  }
  $false
}

# --- herdr config.toml ---------------------------------------------------------------

# candidate config as LF text; notes go to stderr
function Plan-Herdr-Config {
  $lines = Strip-Managed $HERDR_CONFIG
  $block = New-Object System.Collections.ArrayList
  [void]$block.Add($BEGIN)
  # Move herdr's git-only new_worktree off the key we take over.
  if (Has-Table 'keys' $lines) {
    if (Table-Sets 'keys' $lines 'new_worktree') { [Console]::Error.WriteLine('  note: [keys].new_worktree is already customised; leaving it alone') }
    else { $lines = Insert-After-Table 'keys' $lines "new_worktree = ""$KEY_GIT_NATIVE""  $TAG" }
  } else {
    [void]$block.Add('[keys]'); [void]$block.Add("new_worktree = ""$KEY_GIT_NATIVE"""); [void]$block.Add('')
  }
  foreach ($spec in @(@('new', $KEY_NEW, 'new worktree (hg/git)'), @('open', $KEY_OPEN, 'open worktree (hg/git)'),
                      @('remove', $KEY_REMOVE, 'remove worktree (hg/git)'), @('close-group', $KEY_CLOSE_GROUP, 'close hg repo + shares'),
                      @('info', $KEY_INFO, 'hg details'))) {
    [void]$block.Add('[[keys.command]]'); [void]$block.Add("key = ""$($spec[1])"""); [void]$block.Add('type = "plugin_action"')
    [void]$block.Add("command = ""$PLUGIN_ID.$($spec[0])$SUFFIX"""); [void]$block.Add("description = ""$($spec[2])"""); [void]$block.Add('')
  }
  # Sidebar rows: only touch them if the user hasn't customised them.
  if ((Table-Sets 'ui.sidebar.spaces' $lines 'rows') -or (Table-Sets 'ui.sidebar' $lines 'spaces\.rows') -or
      (Table-Sets 'ui' $lines 'sidebar\.spaces\.rows') -or ($lines | Where-Object { $_ -match '^\s*ui\.sidebar\.spaces\.rows\s*=' })) {
    [Console]::Error.WriteLine('  note: Space sidebar rows are customised; add "$hg_bookmark", "$hg_status" to them yourself')
  } elseif (Has-Table 'ui.sidebar.spaces' $lines) {
    $lines = Insert-After-Table 'ui.sidebar.spaces' $lines "rows = $ROWS  $TAG"
  } else {
    [void]$block.Add('[ui.sidebar.spaces]'); [void]$block.Add("rows = $ROWS")
  }
  [void]$block.Add($END)
  $res = New-Object System.Collections.ArrayList
  foreach ($l in $lines) { [void]$res.Add($l) }
  if ($res.Count -gt 0) { [void]$res.Add('') }
  foreach ($l in $block) { [void]$res.Add($l) }
  Lines-Text $res
}

function Apply-Herdr-Config([string]$cand) {
  if (Test-Path -LiteralPath $HERDR_CONFIG) { Copy-Item -LiteralPath $HERDR_CONFIG -Destination "$HERDR_CONFIG.herdr-hg.bak" -Force }
  Write-Keep-Eol $HERDR_CONFIG $cand
  $c = Herdr config check
  if ($c.Code -ne 0) {
    [Console]::Error.WriteLine('  herdr rejected the new config, restoring backup:')
    [Console]::Error.WriteLine(($c.Out + $c.Err).Trim())
    if (Test-Path -LiteralPath "$HERDR_CONFIG.herdr-hg.bak") { Copy-Item -LiteralPath "$HERDR_CONFIG.herdr-hg.bak" -Destination $HERDR_CONFIG -Force }
    [Console]::Error.WriteLine("  Pick other keys in $CONFIG_DIR\config.env (HGWT_KEY_NEW, HGWT_KEY_OPEN,")
    [Console]::Error.WriteLine('  HGWT_KEY_REMOVE, HGWT_KEY_CLOSE_GROUP, HGWT_KEY_INFO, HGWT_KEY_GIT_NATIVE) and run setup again.')
    return $false
  }
  $rc = Herdr server reload-config
  if ($rc.Code -ne 0) { Write-Host '  (herdr not running; config applies on next start)' }
  $true
}

# --- ~/.hgrc + hook shim ---------------------------------------------------------------

function Hook-Content {
@"
# Installed by hgwt-setup. Called from ~/.hgrc hooks; resolves the plugin's
# current install dir each time so 'herdr plugin update' never breaks it.
if (-not (`$env:HERDR_ENV -or `$env:HERDR_WORKSPACE_ID)) { exit 0 }
if (`$env:HGWT_INTERNAL) { exit 0 }
`$h = if (`$env:HERDR_BIN_PATH) { `$env:HERDR_BIN_PATH } else { 'herdr' }
`$psi = New-Object System.Diagnostics.ProcessStartInfo
`$psi.FileName = `$h; `$psi.Arguments = 'plugin list --json --plugin $PLUGIN_ID'
`$psi.UseShellExecute = `$false; `$psi.RedirectStandardOutput = `$true; `$psi.RedirectStandardInput = `$true; `$psi.CreateNoWindow = `$true
try { `$p = [System.Diagnostics.Process]::Start(`$psi) } catch { exit 0 }
`$p.StandardInput.Close()
`$so = `$p.StandardOutput.ReadToEndAsync()
if (-not `$p.WaitForExit(10000)) { try { `$p.Kill() } catch { }; exit 0 }
`$root = ''
try { `$root = [string]((`$so.Result | ConvertFrom-Json).result.plugins[0].plugin_root) } catch { }
`$main = if (`$root) { Join-Path `$root 'bin\hgwt.ps1' } else { '' }
if (-not `$main -or -not (Test-Path -LiteralPath `$main)) { exit 0 }
`$env:HERDR_PLUGIN_CONFIG_DIR = '$CONFIG_DIR'
& `$main refresh --cwd (Get-Location).ProviderPath
"@
}
function Hook-Current { (Test-Path -LiteralPath $HOOK) -and ((Norm (Read-Text $HOOK)).TrimEnd("`n") -ceq (Norm (Hook-Content)).TrimEnd("`n")) }
function Write-Hook { [void](New-Item -ItemType Directory -Force -Path $CONFIG_DIR); [IO.File]::WriteAllText($HOOK, ((Norm (Hook-Content)) + "`n"), $UTF8) }

function Shim-PS-Content {
@"
# Resolves the plugin's current install dir so 'herdr plugin update' never breaks it.
`$h = if (`$env:HERDR_BIN_PATH) { `$env:HERDR_BIN_PATH } else { 'herdr' }
`$root = ''
try { `$root = [string]((& `$h plugin list --json --plugin $PLUGIN_ID | ConvertFrom-Json).result.plugins[0].plugin_root) } catch { }
if (-not `$root) { [Console]::Error.WriteLine('hgwt: plugin $PLUGIN_ID is not installed in herdr'); exit 1 }
`$env:HERDR_PLUGIN_CONFIG_DIR = '$CONFIG_DIR'
& (Join-Path `$root 'bin\hgwt.ps1') @args
exit `$LASTEXITCODE
"@
}
function Shim-Content { "@echo off`r`n$SHIM_MARK`r`npowershell -NoProfile -ExecutionPolicy Bypass -File ""$SHIM_PS"" %*`r`n" }

function On-Path {
  $sep = [IO.Path]::PathSeparator
  foreach ($p in ($env:PATH -split [regex]::Escape($sep))) {
    if ($p -and ($p.TrimEnd('\', '/') -ieq $BIN_DIR.TrimEnd('\', '/'))) { return $true }
  }
  $false
}
function Shim-Ours { (-not (Test-Path -LiteralPath $SHIM)) -or (Read-Text $SHIM).Contains($SHIM_MARK) }
function Shim-Current { (Test-Path -LiteralPath $SHIM) -and (Test-Path -LiteralPath $SHIM_PS) -and ((Norm (Read-Text $SHIM)) -ceq (Norm (Shim-Content))) -and ((Norm (Read-Text $SHIM_PS)).TrimEnd("`n") -ceq (Norm (Shim-PS-Content)).TrimEnd("`n")) }
function Shim-Needed { $script:Win -and (On-Path) -and (Shim-Ours) -and -not (Shim-Current) }
function Write-Shim {
  if (-not $script:Win) { Write-Host '  note: the hgwt command shim is Windows-only; skipping'; return }
  if (-not (On-Path)) { Write-Host "  note: $BIN_DIR is not on PATH; skipping the hgwt command"; return }
  if (-not (Shim-Ours)) { Write-Host "  note: $SHIM exists and isn't ours; leaving it alone"; return }
  [void](New-Item -ItemType Directory -Force -Path $BIN_DIR)
  [void](New-Item -ItemType Directory -Force -Path $CONFIG_DIR)
  [IO.File]::WriteAllText($SHIM_PS, ((Norm (Shim-PS-Content)) + "`n"), $UTF8)
  [IO.File]::WriteAllText($SHIM, (Shim-Content), $UTF8)
}

# candidate hgrc as LF text. hg runs hook commands through the shell (cmd.exe on Windows),
# so the helper is started detached with `start /B` and hg never waits for it.
function Plan-Hgrc {
  $lines = Strip-Managed $HGRC
  $cmd = if ($script:Win) { "start """" /B powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""$HOOK"" >nul 2>&1" }
         else { "sh -c '(pwsh -NoProfile -File ""$HOOK"" >/dev/null 2>&1 &); true'" }
  $res = New-Object System.Collections.ArrayList
  foreach ($l in $lines) { [void]$res.Add($l) }
  if ($res.Count -gt 0) { [void]$res.Add('') }
  foreach ($l in @($BEGIN, '[hooks]', "update.herdr = $cmd", "txnclose.herdr = $cmd", "post-resolve.herdr = $cmd", $END)) { [void]$res.Add($l) }
  Lines-Text $res
}
function Hgrc-Current { (Test-Path -LiteralPath $HGRC) -and ((Norm (Read-Text $HGRC)) -ceq (Plan-Hgrc)) }

function Is-Setup {   # also false when the hgrc block is from an older version
  (Test-Path -LiteralPath $HERDR_CONFIG) -and (Read-Text $HERDR_CONFIG).Contains($BEGIN) -and
  (Test-Path -LiteralPath $HGRC) -and (Read-Text $HGRC).Contains($BEGIN) -and (Hook-Current) -and (Hgrc-Current)
}

# --- main ------------------------------------------------------------------------------------

function Show-Diff([string]$name, [string]$old, [string]$new) {
  $d = Compare-Object (To-Lines $old) (To-Lines $new) -CaseSensitive
  if (-not $d) { Write-Host '  (no changes)'; return }
  foreach ($x in $d) { if ($x.SideIndicator -eq '=>') { Write-Host "  + $($x.InputObject)" } else { Write-Host "  - $($x.InputObject)" } }
}

$a0 = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
switch ($a0) {
  '--status' { if (Is-Setup) { exit 0 } else { exit 1 } }
  '--dismiss' { [void](New-Item -ItemType Directory -Force -Path $CONFIG_DIR); [IO.File]::WriteAllText((Join-Path $CONFIG_DIR '.setup-dismissed'), ''); Write-Host 'Reminder dismissed.'; exit 0 }
  '--uninstall' {
    foreach ($f in @($HERDR_CONFIG, $HGRC)) {
      if (-not (Test-Path -LiteralPath $f)) { continue }
      Copy-Item -LiteralPath $f -Destination "$f.herdr-hg.bak" -Force
      Write-Keep-Eol $f (Lines-Text (Strip-Managed $f))
      Write-Host "cleaned $f (backup: $f.herdr-hg.bak)"
    }
    Remove-Item -LiteralPath $HOOK -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $SHIM_PS -Force -ErrorAction SilentlyContinue
    if ((Test-Path -LiteralPath $SHIM) -and (Read-Text $SHIM).Contains($SHIM_MARK)) { Remove-Item -LiteralPath $SHIM -Force; Write-Host "removed $SHIM" }
    [void](Herdr server reload-config)
    exit 0
  }
  { $_ -in '--yes', '' } { }
  default { [IO.File]::ReadAllLines($script:Self) | Select-Object -Skip 1 -First 10 | ForEach-Object { $_ -replace '^# ?', '' }; exit 2 }
}

if (-not (Get-Command hg -CommandType Application -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('warning: hg not on PATH') }

Write-Host 'herdr-hg setup'
Write-Host ''
$candCfg = Plan-Herdr-Config
$candHgrc = Plan-Hgrc
if (((Norm (Read-Text $HERDR_CONFIG)) -ceq $candCfg) -and ((Norm (Read-Text $HGRC)) -ceq $candHgrc) -and (Hook-Current) -and -not (Shim-Needed)) {
  Write-Host 'Already set up, nothing to change.'; exit 0
}
Write-Host "Changes to ${HERDR_CONFIG}:"; Show-Diff $HERDR_CONFIG (Norm (Read-Text $HERDR_CONFIG)) $candCfg; Write-Host ''
Write-Host "Changes to ${HGRC}:"; Show-Diff $HGRC (Norm (Read-Text $HGRC)) $candHgrc; Write-Host ''
Write-Host "Hook helper: $HOOK"
Write-Host "Command:     $SHIM (hgwt list/create/open/remove/prune/close-group/info)"; Write-Host ''

if ($a0 -ne '--yes') {
  [Console]::Out.Write('Apply? [y/N] '); $ans = [Console]::In.ReadLine()
  if ($ans -ne 'y') { Write-Host 'Nothing changed.'; exit 0 }
}

if (-not (Apply-Herdr-Config $candCfg)) { exit 1 }
Write-Hook
Write-Shim
if (Test-Path -LiteralPath $HGRC) { Copy-Item -LiteralPath $HGRC -Destination "$HGRC.herdr-hg.bak" -Force }
Write-Keep-Eol $HGRC $candHgrc
Remove-Item -LiteralPath (Join-Path $CONFIG_DIR '.setup-dismissed') -Force -ErrorAction SilentlyContinue
try {
  $ps = if ($script:Win) { 'powershell.exe' } else { 'pwsh' }
  [void](Run-Native $ps @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path (Split-Path -Parent $script:Self) 'hgwt.ps1'), 'refresh', '--all') 60)
} catch { }
Write-Host "Done. Backups: $HERDR_CONFIG.herdr-hg.bak, $HGRC.herdr-hg.bak"
Write-Host "Keys: $KEY_NEW new $([char]0x00B7) $KEY_OPEN open $([char]0x00B7) $KEY_REMOVE remove $([char]0x00B7) $KEY_CLOSE_GROUP close repo+shares $([char]0x00B7) $KEY_INFO details"
Write-Host "      herdr's own git worktree key moved to $KEY_GIT_NATIVE"
