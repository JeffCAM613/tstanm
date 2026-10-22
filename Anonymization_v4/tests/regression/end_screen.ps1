# ============================================================================
# The end of a run as op/lib/anon_screen.ps1 shows it, for the suite
# ============================================================================
# Prints the end screen of a run (Show-RunEnd) from a results.txt and a state
# file in the format anon.sh writes for op/lib/anon_end.awk: one line of the
# screen per line, its colour, a tab and its text. The suite compares it with
# what anon_end.awk prints from the same files: the Windows and the Linux
# wrapper must end a run with the same screen.
#
#   powershell -ExecutionPolicy Bypass -File end_screen.ps1 <results.txt> <state.txt>
# ============================================================================

param([string]$ResultsPath, [string]$StatePath)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\..\op\lib\anon_screen.ps1')

# What anon.ps1 gives the screen: its output, collected; its constants.
$script:Lines = New-Object 'System.Collections.Generic.List[string]'
function Write-Out {
    param([string]$Text = '', [string]$Color = '', [switch]$NoLog, [switch]$Detail)
    $script:Lines.Add($Color + "`t" + $Text)
}
function Write-Log { param([string]$Text) }
function Clear-Status { }
$script:Width = 80
$script:ExitPass = 0; $script:ExitError = 1; $script:ExitVerifyFail = 2
$script:ExitReview = 3; $script:ExitIncomplete = 4; $script:ExitStopped = 5

# The state of the run.
$values = @{ 'WIDTH' = '100' }
$durations = New-Object 'System.Collections.Generic.List[object]'
$errors = New-Object 'System.Collections.Generic.List[string]'
$checks = New-Object 'System.Collections.Generic.List[string]'
foreach ($line in [System.IO.File]::ReadAllLines($StatePath)) {
    if ($line.StartsWith('ANON_CHECK|')) { $checks.Add($line); continue }
    $f = $line.Split([char[]]@('|'), 2)
    if ($f.Count -lt 2) { continue }
    if ($f[0] -eq 'DURATION') {
        $d = $f[1].Split('|')
        $durations.Add([pscustomobject]@{ Key = $d[0]; Text = ''; Status = $d[1]; Seconds = [double]$d[2] })
    } elseif ($f[0] -eq 'ERROR') {
        $errors.Add($f[1])
    } else {
        $values[$f[0]] = $f[1]
    }
}
$script:WrapWidth = [int]$values['WIDTH']
function Get-WrapWidth { return $script:WrapWidth }
$script:Launcher = $values['LAUNCHER']

$state = New-RunState @{} 'test' ($values['DRY'] -eq '1') $values['TNS'] 'XE'
$state.Results = ConvertFrom-Results ([System.IO.File]::ReadAllLines($ResultsPath))
$state.Durations.AddRange($durations)
$state.Errors.AddRange($errors)
$state.Checks = ConvertFrom-CheckLines $checks.ToArray()
if ($values.ContainsKey('REFUSAL')) { $state.Refusal = [pscustomobject]@{ Status = 'REFUSED'; Code = ''; Message = $values['REFUSAL'] } }
$end = [pscustomobject]@{ ExitCode = 0; Verdict = $values['VERDICT']; Words = ''; Color = $values['COLOR'] }

Show-RunEnd $state $values['STATUS'] $end
[Console]::Out.Write(($script:Lines.ToArray() -join "`n") + "`n")
