# ============================================================================
# OP Anonymization - The screen of a run
# ============================================================================
# Purpose : What a run shows: its steps by what they do, each with its time;
#           while the work runs, one live line for each kind of work (free
#           text, identifiers, labels and attributes) with its bar, what it
#           works on, the rows so far and the time left; the checks as a
#           table; and the end of the run in plain words - the result in one
#           sentence, the figures, what to know, and what comes next.
#           /verbose adds every line of the engine; console.log and
#           report.txt always keep them.
# Usage   : Dot-sourced by anon.ps1, whose output functions it uses.
# Requires: Windows PowerShell 5.1.
# ============================================================================

# The five categories of identity, and their names on the screen and in the
# report.
$script:Categories = @('ENTITY', 'PORTFOLIO', 'COUNTERPARTY', 'UNCLASSIFIED_PARTY', 'BANK_ACCOUNT')
$script:CategoryNames = @{
    'ENTITY' = 'Entity (E_)'; 'PORTFOLIO' = 'Portfolio (P_)'; 'COUNTERPARTY' = 'Counterparty (T_)';
    'UNCLASSIFIED_PARTY' = 'Unclassified party (X_)'; 'BANK_ACCOUNT' = 'Bank account (CB_)'
}

# ----------------------------------------------------------------------------
# Formats
# ----------------------------------------------------------------------------

# A number printed by sqlplus; 0 when there is none.
function ConvertTo-Number {
    param([string]$Text)
    $value = [double]0
    if ([double]::TryParse(($Text -replace ',', '').Trim(), [Globalization.NumberStyles]::Float,
                           [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        return $value
    }
    return [double]0
}

# 19,279,194 for a count.
function Format-Count {
    param([double]$Value)
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:N0}', [Math]::Round($Value))
}

# 0:05, 12:34, 1:02:03.
function Format-Clock {
    param([double]$Seconds)
    $s = [int][Math]::Max(0.0, [Math]::Round($Seconds))
    if ($s -ge 3600) { return ('{0}:{1:00}:{2:00}' -f [Math]::Floor($s / 3600), [Math]::Floor(($s % 3600) / 60), ($s % 60)) }
    return ('{0}:{1:00}' -f [Math]::Floor($s / 60), ($s % 60))
}

# "less than a minute", "about 8 minutes", "about 1 h 20 min".
function Format-About {
    param([double]$Seconds)
    if ($Seconds -lt 45) { return 'less than a minute' }
    $m = [int][Math]::Max(1.0, [Math]::Round($Seconds / 60))
    if ($m -ge 90) { return ('about ' + [Math]::Floor($m / 60) + ' h ' + ($m % 60) + ' min') }
    if ($m -eq 1) { return 'about 1 minute' }
    return ('about ' + $m + ' minutes')
}

# "1 column", "3 columns".
function Format-Plural {
    param([double]$Count, [string]$One, [string]$Many = '')
    if ($Many -eq '') { $Many = $One + 's' }
    if ($Count -eq 1) { return ('1 ' + $One) }
    return ((Format-Count $Count) + ' ' + $Many)
}

function Get-Bar {
    param([double]$Pct, [int]$Width = 20)
    $full = [int][Math]::Floor($Width * [Math]::Max(0.0, [Math]::Min(100.0, $Pct)) / 100)
    return '[' + ('#' * $full) + ('.' * ($Width - $full)) + ']'
}

# Columns a wrapped text may take: the console's, from 80 to 120.
function Get-WrapWidth {
    $width = 100
    try {
        if (-not [Console]::IsOutputRedirected) { $width = [Console]::WindowWidth - 1 }
    } catch {
        $width = 100
    }
    return [Math]::Max(80, [Math]::Min(120, $width))
}

# A text wrapped at the width of the screen: its first line after $First, the
# others under it (or indented by $Indent). Logged as it is shown.
function Write-Wrapped {
    param([string]$First, [string]$Text, [string]$Color = '', [int]$Indent = -1)
    $width = Get-WrapWidth
    $pad = ' ' * $First.Length
    if ($Indent -ge 0) { $pad = ' ' * $Indent }
    $line = $First
    foreach ($word in ($Text -split ' ')) {
        if ($word -eq '') { continue }
        if ($line.Length + $word.Length -gt $width -and $line.Trim() -ne '' -and $line.Length -gt $pad.Length) {
            Write-Out $line.TrimEnd() $Color
            $line = $pad
        }
        $line = $line + $word + ' '
    }
    if ($line.Trim() -ne '') { Write-Out $line.TrimEnd() $Color }
}

function Write-Rule {
    param([string]$Color = 'White')
    Write-Out (' ' + ('=' * ($script:Width - 1))) $Color
}

# "   Database           OPDB: connected as SYS and as OP"
function Write-Kv {
    param([string]$Key, [string]$Value, [string]$Color = '')
    Write-Out ('   ' + $Key.PadRight(19) + $Value) $Color
}

# ----------------------------------------------------------------------------
# The run's state
# ----------------------------------------------------------------------------

function New-RunState {
    param([hashtable]$Settings, [string]$Version, [bool]$DryRun, [string]$Tns, [string]$Database)
    $mode = 'EXECUTE'
    if ($DryRun) { $mode = 'DRYRUN' }
    return [pscustomobject]@{
        Settings = $Settings; Version = $Version; DryRun = $DryRun; Mode = $mode; Tns = $Tns; Database = $Database;
        RunId = [long]0; Folder = $null; Worker = $null; Monitor = $null; Live = $true; LastStep = [long]0;
        Working = $false; Verifying = $false; Prepare = @(); InventorySql = @(); Inventory = $null;
        Report = (New-Object 'System.Collections.Generic.List[string]');
        Durations = (New-Object 'System.Collections.Generic.List[object]');
        Steps = (New-Object 'System.Collections.Generic.List[object]');
        Errors = (New-Object 'System.Collections.Generic.List[string]');
        Checks = @(); Plan = $null; Results = $null; Refusal = $null; Flow = $null
    }
}

# The checks of plan.sql (ANON_CHECK) or results.sql (ANON_R_CHECK).
function ConvertFrom-CheckLines {
    param([string[]]$Lines)
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in $Lines) {
        if ($line -match '^ANON_(R_)?CHECK\|') {
            $f = $line.Split([char[]]@('|'), 10)
            if ($f.Count -lt 10) { continue }
            $list.Add([pscustomobject]@{ Seq = [int](ConvertTo-Number $f[1]); Code = $f[2]; Needed = $f[3]; Status = $f[4];
                                         State = $f[5]; Title = $f[6]; Measure = $f[7]; Happens = $f[8]; ToDo = $f[9] })
        }
    }
    return ,$list.ToArray()
}

# What plan.sql says besides the checks: identities, scope, estimate.
function ConvertFrom-PlanLines {
    param([string[]]$Lines)
    $plan = [pscustomobject]@{ Identities = $null; Scope = $null; Estimate = $null }
    foreach ($line in $Lines) {
        $f = $line.Split('|')
        if ($f[0] -eq 'ANON_IDENTITIES' -and $f.Count -ge 5) {
            $plan.Identities = [pscustomobject]@{ Parties = (ConvertTo-Number $f[1]); Accounts = (ConvertTo-Number $f[2]);
                                                  New = (ConvertTo-Number $f[3]); Known = (ConvertTo-Number $f[4]) }
        } elseif ($f[0] -eq 'ANON_SCOPE' -and $f.Count -ge 5) {
            $plan.Scope = [pscustomobject]@{ Code = (ConvertTo-Number $f[1]); Free = (ConvertTo-Number $f[2]);
                                             Labels = (ConvertTo-Number $f[3]); Attributes = (ConvertTo-Number $f[4]) }
        } elseif ($f[0] -eq 'ANON_ESTIMATE' -and $f.Count -ge 4) {
            $plan.Estimate = [pscustomobject]@{ Seconds = (ConvertTo-Number $f[1]); Basis = $f[2]; DryRun = $f[3] }
        }
    }
    return $plan
}

# ----------------------------------------------------------------------------
# Steps
# ----------------------------------------------------------------------------

# Starts the steps of the run. $Steps: Key, Text and Header ($true for a step
# that is a heading over the live lines of its work), in order. The three
# kinds of work each get a live line under the heading.
function Start-Flow {
    param([object[]]$Steps)
    $kinds = [ordered]@{}
    $kinds['NULL_OUT'] = [pscustomobject]@{ Name = 'Free text'; Unit = 'tables'; Phases = @('NULL_OUT') }
    $kinds['CODE'] = [pscustomobject]@{ Name = 'Identifiers'; Unit = 'columns'; Phases = @('CODE') }
    $kinds['LABELS'] = [pscustomobject]@{ Name = 'Labels and attributes'; Unit = 'columns'; Phases = @('DESCRIPTION', 'SELF_CODE') }
    foreach ($k in $kinds.Values) {
        foreach ($p in @('Seen', 'Shown')) { $k | Add-Member -NotePropertyName $p -NotePropertyValue $false }
        foreach ($p in @('Done', 'Total', 'Rows', 'X', 'Ms', 'Pct', 'InPhase')) { $k | Add-Member -NotePropertyName $p -NotePropertyValue ([double]0) }
        $k | Add-Member -NotePropertyName 'Objects' -NotePropertyValue (@{})
    }
    $script:Run.Flow = [pscustomobject]@{
        Steps = @($Steps); N = 0; Started = (Get-Date); Open = $false; Kinds = $kinds;
        Pending = (New-Object 'System.Collections.Generic.List[object]'); LastLine = (Get-Date); Stage = '';
        TriggersOn = $null
    }
}

function Get-FlowIndex {
    param([string]$Key)
    $f = $script:Run.Flow
    for ($i = 0; $i -lt $f.Steps.Count; $i++) {
        if ($f.Steps[$i].Key -eq $Key) { return ($i + 1) }
    }
    return 0
}

# " 1 of 2  Checking and planning (read-only)                       done    0:41"
function Get-FlowLine {
    param([string]$State = '', [string]$Time = '', [int]$N = 0)
    $f = $script:Run.Flow
    if ($N -eq 0) { $N = $f.N }
    $text = ' ' + $N + ' of ' + $f.Steps.Count + '  ' + $f.Steps[$N - 1].Text
    return ($text.PadRight(66) + ' ' + $State.PadRight(7) + $Time.PadLeft(5)).TrimEnd()
}

# Starts the step $Key, ending the one that runs.
function Start-FlowStep {
    param([string]$Key)
    $f = $script:Run.Flow
    $n = Get-FlowIndex $Key
    if ($n -eq 0) { return }
    if ($f.Open) { Complete-FlowStep }
    $f.N = $n
    $f.Started = Get-Date
    $f.Open = $true
    $f.Stage = ''
    Write-Log ''
    if ($f.Steps[$n - 1].Header) {
        Write-Out ''
        Write-Out (Get-FlowLine) 'White'
    } else {
        Show-Status (Get-FlowLine 'running' (Format-Clock 0))
    }
}

# Ends the running step with its time: done, FAILED, stopped... A heading
# gets a line only when it did not end well. The step's duration goes to the
# report.
function Complete-FlowStep {
    param([string]$State = 'done')
    $f = $script:Run.Flow
    if ($null -eq $f -or -not $f.Open) { return }
    $f.Open = $false
    $seconds = ((Get-Date) - $f.Started).TotalSeconds
    $step = $f.Steps[$f.N - 1]
    $script:Run.Durations.Add([pscustomobject]@{ Key = $step.Key; Text = $step.Text; Status = $State.ToUpperInvariant();
                                                 Seconds = $seconds })
    $color = 'Green'
    if ($State -eq 'FAILED') { $color = 'Red' } elseif ($State -ne 'done') { $color = 'Yellow' }
    if ($step.Header) {
        Clear-Status
        if ($State -ne 'done') { Write-Out ('         ' + $State + ' after ' + (Format-Clock $seconds)) $color }
    } else {
        Write-Out (Get-FlowLine $State (Format-Clock $seconds)) $color
    }
    foreach ($note in $f.Pending) { Write-Wrapped '         ' $note.Text $note.Color }
    $f.Pending.Clear()
}

# A line under the running step: written when a step ends, at once under a
# heading.
function Write-FlowNote {
    param([string]$Text, [string]$Color = '')
    $f = $script:Run.Flow
    if ($f.Open -and -not $f.Steps[$f.N - 1].Header) {
        $f.Pending.Add([pscustomobject]@{ Text = $Text; Color = $Color })
        return
    }
    Write-Wrapped '         ' $Text $Color
}

function Write-FlowError {
    param([string]$Message)
    if ($Message -eq '') { return }
    $script:Run.Errors.Add($Message)
    Write-Wrapped '         ' $Message 'Red'
}

# The word a step ends with, for the status a script returned.
function Get-StepWord {
    param([string]$Status)
    switch ($Status) {
        'OK'        { return 'done' }
        'COMPLETED' { return 'done' }
        'STOPPED'   { return 'stopped' }
        default     { return 'FAILED' }
    }
}

# The kind of work a phase of the engine belongs to: NULL_OUT, CODE, LABELS.
function Get-KindKey {
    param([string]$Phase)
    if ($Phase -eq 'NULL_OUT') { return 'NULL_OUT' }
    if ($Phase -eq 'CODE') { return 'CODE' }
    if ($Phase -eq 'LABELS' -or $Phase -eq 'DESCRIPTION' -or $Phase -eq 'SELF_CODE') { return 'LABELS' }
    return ''
}

# One row the engine logged (anon_step_log), as the monitor read it: added up
# under its kind of work; with /verbose shown as it comes; the triggers of OP
# said when they are disabled and enabled again.
function Add-FlowStep {
    param($Step)
    $state = $script:Run
    $state.Steps.Add($Step)
    if ($script:Verbose) {
        $rows = ''
        if ($Step.Rows -ne 0 -or $Step.Status -eq 'OK' -or $Step.Status -eq 'DRYRUN') { $rows = Format-Count $Step.Rows }
        Write-Out ('   ' + $Step.Phase.PadRight(11) + $Step.Status.PadRight(9) + $rows.PadLeft(12) + '  ' + $Step.Object) 'DarkGray' -NoLog
    }
    if ($Step.Status -eq 'ERROR') { $state.Errors.Add($Step.Object + ': ' + $Step.Message) }
    if ($null -eq $state.Flow) { return }
    if ($Step.Phase -eq 'TRIGGERS') {
        # Enabled again at the end of the work, whether it completed or not:
        # said after the lines of the work, which Complete-Kinds closes with
        # how it ended.
        if ($Step.Object -eq 'ENABLE') {
            $state.Flow.TriggersOn = $Step.Rows
            return
        }
        Clear-Status
        if ($Step.Rows -eq 0) {
            Write-Out '         triggers of OP: none'
        } else {
            Write-Out ('         triggers of OP: ' + (Format-Count $Step.Rows) + ' disabled until the end of the run')
        }
        return
    }
    $key = Get-KindKey $Step.Phase
    if ($key -eq '') { return }
    $kind = $state.Flow.Kinds[$key]
    # A kind that logs a row has begun: the kinds before it have ended.
    Show-EndedKinds $key
    $kind.Seen = $true
    if ($Step.Status -eq 'OK' -or $Step.Status -eq 'DRYRUN') {
        $kind.Rows += $Step.Rows
        $kind.X += $Step.X
    }
    $kind.Ms += $Step.Ms
    if ($Step.Status -ne 'SKIPPED' -and $Step.Status -ne 'DISABLED') {
        foreach ($o in (Get-StepObjects $Step)) { $kind.Objects[$o] = $true }
    }
}

# What one logged row worked on, as its kind counts it: the table of a
# free-text statement, the column of an identifier step, the columns of a
# label or attribute statement ("tiers.[description,fax] [party nodes]").
function Get-StepObjects {
    param($Step)
    $object = $Step.Object
    if ($Step.Phase -eq 'NULL_OUT') { return ,@($object -replace '\..*$', '') }
    if ($Step.Phase -eq 'CODE') { return ,@($object -replace ' .*$', '') }
    if ($object -match '^([^.]+)\.\[([^\]]*)\]') {
        $table = $Matches[1]
        return ,@($Matches[2].Split(',') | ForEach-Object { $table + '.' + ($_ -replace '\(masked\)$', '').Trim() })
    }
    return ,@($object -replace ' .*$', '')
}

# The done line of every kind before $Key that has begun and is not shown.
function Show-EndedKinds {
    param([string]$Key)
    $kinds = $script:Run.Flow.Kinds
    foreach ($k in $kinds.Keys) {
        if ($k -eq $Key) { return }
        $kind = $kinds[$k]
        if ($kind.Seen -and -not $kind.Shown) { Show-KindLine $kind 'done' }
    }
}

# The final line of a kind of work: done, with its rows and time; or how far
# it got when the run stopped or failed during it.
function Show-KindLine {
    param($Kind, [string]$State)
    $Kind.Shown = $true
    Clear-Status
    $count = $Kind.Total
    if ($count -eq 0) { $count = $Kind.Objects.Count }
    $head = '         ' + $Kind.Name.PadRight(23)
    if ($State -eq 'done') {
        Write-Out ($head + (Get-Bar 100) + ' 100%   ' + ((Format-Count $count) + ' ' + $Kind.Unit).PadRight(13) +
                   ((Format-Count $Kind.Rows) + ' rows').PadLeft(17) + (Format-Clock ($Kind.Ms / 1000)).PadLeft(7))
        return
    }
    $color = 'Yellow'
    if ($State -eq 'FAILED') { $color = 'Red' }
    # Done: what the last look saw, or the tables and columns logged since,
    # whichever is more.
    $done = [Math]::Max([double]$Kind.Done, [double]$Kind.Objects.Count)
    Write-Out ($head + (Get-Bar $Kind.Pct) + ' ' + ([string][int][Math]::Floor($Kind.Pct)).PadLeft(3) + '%   ' + $State + ' after ' +
               (Format-Count $done) + ' of ' + (Format-Count $count) + ' ' + $Kind.Unit + ' . ' +
               (Format-Count $Kind.Rows) + ' rows') $color
}

# At the end of the work: the line of every kind not shown yet - done; the
# one the run was in when it stopped or failed, with how far it got; the ones
# it never reached, "not run". Then the triggers of OP, enabled again.
function Complete-Kinds {
    param([string]$Status)
    $f = $script:Run.Flow
    if ($null -eq $f) { return }
    $ended = ($Status -eq 'COMPLETED' -or $Status -eq 'OK')
    $last = ''
    foreach ($k in $f.Kinds.Keys) { if ($f.Kinds[$k].Seen) { $last = $k } }
    foreach ($k in $f.Kinds.Keys) {
        $kind = $f.Kinds[$k]
        if ($kind.Shown) { continue }
        if (-not $kind.Seen) {
            if (-not $ended) {
                $kind.Shown = $true
                Write-Out ('         ' + $kind.Name.PadRight(23) + 'not run') 'DarkGray'
            }
            continue
        }
        if ($k -eq $last -and -not $ended) {
            Show-KindLine $kind (Get-StepWord $Status)
        } else {
            Show-KindLine $kind 'done'
        }
    }
    if ($null -ne $f.TriggersOn) {
        if ($f.TriggersOn -gt 0) { Write-Out ('         triggers of OP: ' + (Format-Count $f.TriggersOn) + ' enabled again') }
        $f.TriggersOn = $null
    }
}

# What the engine does now, in words, for the line of a running step.
function Get-StageWords {
    param($Poll)
    $f = $script:Run.Flow
    $step = $f.Steps[$f.N - 1].Key
    if ($null -eq $Poll) { return $f.Stage }
    if ($step -eq 'VERIFY') {
        $names = [ordered]@{ 'IDENTITY' = 'identities'; 'RESIDUAL' = 'identifier columns'; 'FREETEXT' = 'free text';
                             'LABELS' = 'labels and attributes'; 'MAPPING' = 'mapping integrity'; 'SETTINGS' = 'switches';
                             'PREFIX' = 'prefixes' }
        $text = ''
        foreach ($k in $names.Keys) {
            if ($Poll.Verify.ContainsKey($k)) { $text = $names[$k] + ' (' + (Format-Count $Poll.Verify[$k]) + ' checked)' }
        }
        if ($text -ne '') { $f.Stage = $text }
        return $f.Stage
    }
    if ($null -ne $Poll.Progress -and $Poll.Progress.Stage -ne '') { $f.Stage = $Poll.Progress.Stage }
    return $f.Stage
}

# The status line of the run, after each look at it: the running step with
# its clock and what the engine does, or under a heading the live line of
# the kind of work in progress. Without a console it is written as a line
# once a minute.
function Show-FlowStatus {
    param($Poll)
    $state = $script:Run
    $f = $state.Flow
    if ($null -eq $f -or -not $f.Open) { return }
    $text = ''
    if ($f.Steps[$f.N - 1].Header) {
        if ($null -eq $Poll -or $null -eq $Poll.Progress) { return }
        $p = $Poll.Progress
        $key = Get-KindKey $p.Phase
        if ($key -eq '') { return }
        Show-EndedKinds $key
        $kind = $f.Kinds[$key]
        $kind.Seen = $true
        $kind.Total = $p.Total
        $kind.Done = $p.Done
        $kind.InPhase = $p.InPhase
        $longPct = -1
        if ($null -ne $Poll.LongOp) { $longPct = [Math]::Min(100.0, [Math]::Max(0.0, $Poll.LongOp.Pct)) }
        $frac = 0.0
        if ($p.WeightTotal -gt 0) {
            $part = 0.0
            if ($longPct -ge 0) { $part = $p.Weight * $longPct / 100 }
            $frac = ($p.WeightDone + $part) / $p.WeightTotal
        } elseif ($p.Total -gt 0) {
            $frac = $p.Done / $p.Total
        }
        $frac = [Math]::Max(0.0, [Math]::Min(1.0, $frac))
        $kind.Pct = 100 * $frac
        $text = '         ' + $kind.Name.PadRight(23) + (Get-Bar $kind.Pct) + ' ' + ([string][int][Math]::Floor($kind.Pct)).PadLeft(3) +
                '%   ' + (Format-Count $p.Done) + ' of ' + (Format-Count $p.Total) + ' ' + $kind.Unit
        if ($p.Object -ne '') {
            $text = $text + ' . ' + $p.Object
            if ($longPct -ge 0) { $text = $text + ' ' + [int]$longPct + '%' }
        }
        if ($kind.Rows -gt 0) { $text = $text + ' . ' + (Format-Count $kind.Rows) + ' rows' }
        if ($frac -ge 0.03 -and $p.InPhase -ge 15) {
            $text = $text + ' . ' + (Format-Clock ($p.InPhase * (1 - $frac) / $frac)) + ' left'
        }
    } else {
        $words = Get-StageWords $Poll
        $text = Get-FlowLine 'running' (Format-Clock ((Get-Date) - $f.Started).TotalSeconds)
        if ($words -ne '') { $text = $text + ' . ' + $words }
    }
    if ($script:StatusLine) {
        Show-Status $text
    } elseif (((Get-Date) - $script:LastConsole).TotalSeconds -ge 60) {
        Write-Out $text 'DarkGray' -NoLog
    }
}

# ----------------------------------------------------------------------------
# Getting ready: the switches
# ----------------------------------------------------------------------------

# What is anonymized, as one table, and whether it is everything.
function Show-Switches {
    param([hashtable]$Settings)
    Write-Out ''
    Write-Out '   What is anonymized (config\anonymization.ini)'
    Write-Out ('   ' + 'Category'.PadRight(26) + 'Rename codes'.PadRight(15) + 'Labels'.PadRight(9) + 'Attributes')
    $off = @()
    $word = @{ 'y' = 'yes'; 'n' = 'no' }
    foreach ($c in $script:Categories) {
        $id = $Settings['ANONYMIZE_' + $c]
        $desc = $Settings['ANONYMIZE_' + $c + '_DESCRIPTION']
        $attr = $Settings['ANONYMIZE_' + $c + '_ATTRIBUTES']
        foreach ($pair in @(@($id, 'codes'), @($desc, 'labels'), @($attr, 'attributes'))) {
            if ($pair[0] -eq 'n') { $off += ($script:CategoryNames[$c] -replace ' \(.*$', '').ToLowerInvariant() + ' ' + $pair[1] }
        }
        $color = ''
        if ($id -eq 'n' -or $desc -eq 'n' -or $attr -eq 'n') { $color = 'Yellow' }
        Write-Out ('   ' + $script:CategoryNames[$c].PadRight(26) + $word[$id].PadRight(15) + $word[$desc].PadRight(9) + $word[$attr]) $color
    }
    Write-Out ('   ' + 'Free text'.PadRight(26) + 'always emptied')
    if ($off.Count -eq 0) {
        Write-Out '   Every switch is on: a full anonymization.'
    } else {
        Write-Wrapped '   ' ('Switched off: ' + ($off -join ', ') + '. Their client data stays, and the verification can be no better than INCOMPLETE.') 'Yellow'
    }
}

# ----------------------------------------------------------------------------
# Checks
# ----------------------------------------------------------------------------

# The checks as a table: each with whether it is needed, its state now and
# what was measured; for each one not met, what happens and what to do.
function Show-Checks {
    param([object[]]$Checks, [bool]$DryRun)
    if ($Checks.Count -eq 0) { return }
    Write-Out ''
    Write-Out ('   ' + 'Check'.PadRight(38) + 'Needed'.PadRight(11) + 'Now') 'White'
    $unmet = @()
    foreach ($c in $Checks) {
        $needed = $c.Needed.ToLowerInvariant()
        $now = $c.State
        $color = ''
        if ($c.Status -eq 'NOT_MET') {
            $now = 'NOT MET'
            if ($c.Needed -eq 'REQUIRED') { $color = 'Red'; $unmet += $c.Title } else { $color = 'Yellow' }
        } elseif ($now -eq '') {
            $now = 'ok'
        }
        Write-Out ('   ' + $c.Title.PadRight(38) + $needed.PadRight(11) + $now) $color
        if ($c.Measure -ne '') { Write-Wrapped '       ' $c.Measure 'DarkGray' }
        if ($c.Status -eq 'NOT_MET') {
            if ($c.Happens -ne '') { Write-Wrapped '       What happens: ' $c.Happens $color }
            if ($c.ToDo -ne '') { Write-Wrapped '       What to do:   ' $c.ToDo }
        }
    }
    Write-Out ''
    if ($unmet.Count -gt 0) {
        Write-Wrapped '   ' ('Required and not met: ' + ($unmet -join ', ') + '. The run cannot start.') 'Red'
    } elseif ($DryRun) {
        Write-Out '   Every required check is met: a run can go ahead as things are.'
    } else {
        Write-Out '   Every required check is met: the run can go ahead as things are.'
    }
}

# Before the question to start: what the run will change, and that it cannot
# be undone.
function Show-ReadyBanner {
    param($State)
    $plan = $State.Plan
    Write-Out ''
    Write-Rule
    Write-Out ('  Ready. This replaces the client data of OP on ' + $State.Tns + ':') 'White'
    if ($null -ne $plan.Identities -and $null -ne $plan.Scope) {
        $ids = $plan.Identities.Parties + $plan.Identities.Accounts
        $before = ''
        if ($plan.Identities.Known -gt 0) {
            $before = ' (' + (Format-Count $plan.Identities.Known) + ' of them translated by an earlier run, with the same value)'
        }
        Write-Wrapped '  - ' ((Format-Plural $ids 'identity' 'identities') + ' get their E_, P_, T_, X_ or CB_ value, in ' +
                              (Format-Plural $plan.Scope.Code 'identifier column') + '; their labels and attributes are masked with it' +
                              $before) 'White'
        Write-Wrapped '  - ' ((Format-Plural $plan.Scope.Free 'free-text column') + ' emptied, ' +
                              (Format-Plural ($plan.Scope.Labels + $plan.Scope.Attributes) 'label and attribute column') + ' masked') 'White'
    }
    $off = @((Get-SwitchKeys) | Where-Object { $State.Settings[$_] -eq 'n' })
    if ($off.Count -gt 0) {
        Write-Wrapped '  - ' ((Format-Plural $off.Count 'switch' 'switches') + ' off: their client data stays, and the result is INCOMPLETE') 'Yellow'
    }
    $time = ''
    if ($null -ne $plan.Estimate -and $plan.Estimate.Seconds -gt 0) {
        $time = (Format-About $plan.Estimate.Seconds) + ', from the dry run ' + $plan.Estimate.DryRun + '. '
        $time = $time.Substring(0, 1).ToUpperInvariant() + $time.Substring(1)
    }
    Write-Wrapped '  ' ($time + 'It cannot be undone: run it on a restored copy only.') 'White'
    Write-Rule
}

# ----------------------------------------------------------------------------
# Results
# ----------------------------------------------------------------------------

# The lines of results.sql, as one object.
function ConvertFrom-Results {
    param([string[]]$Lines)
    $r = [pscustomobject]@{
        Complete = $false; Run = $null; Config = $null; Dataset = $null;
        Settings = (New-Object 'System.Collections.Generic.List[object]');
        Checks = @(); Ident = (New-Object 'System.Collections.Generic.List[object]'); Accounts = $null; IdNotes = $null;
        XReasons = (New-Object 'System.Collections.Generic.List[object]');
        XTables = (New-Object 'System.Collections.Generic.List[object]');
        Harvest = (New-Object 'System.Collections.Generic.List[object]');
        Items = (New-Object 'System.Collections.Generic.List[object]');
        Steps = (New-Object 'System.Collections.Generic.List[object]');
        Estimate = $null; Triggers = 0;
        Verify = (New-Object 'System.Collections.Generic.List[object]')
    }
    if ($null -eq $Lines) { return $r }
    $reasons = @{}
    foreach ($line in $Lines) {
        if (-not $line.StartsWith('ANON_R_')) { continue }
        $tag = $line.Substring(0, [Math]::Max(0, $line.IndexOf('|')))
        switch ($tag) {
            'ANON_R_RUN' {
                $f = $line.Split([char[]]@('|'), 10)
                $r.Run = [pscustomobject]@{ RunId = [long](ConvertTo-Number $f[1]); Mode = $f[2]; Status = $f[3]; Started = $f[4];
                                            Finished = $f[5]; Seconds = (ConvertTo-Number $f[6]); Database = $f[7]; Version = $f[8];
                                            Error = $(if ($f.Count -ge 10) { $f[9] } else { '' }) }
            }
            'ANON_R_CONFIG' {
                try { $r.Config = ($line.Substring($tag.Length + 1) | ConvertFrom-Json) } catch { $r.Config = $null }
            }
            'ANON_R_DATASET' {
                try { $r.Dataset = ($line.Substring($tag.Length + 1) | ConvertFrom-Json) } catch { $r.Dataset = $null }
            }
            'ANON_R_SETTING' {
                $f = $line.Split('|')
                $r.Settings.Add([pscustomobject]@{ Category = $f[1]; Id = $f[2]; Desc = $f[3]; Attr = $f[4] })
            }
            'ANON_R_IDENT' {
                $f = $line.Split('|')
                $r.Ident.Add([pscustomobject]@{ Category = $f[1]; Found = (ConvertTo-Number $f[2]); New = (ConvertTo-Number $f[3]);
                                                Reused = (ConvertTo-Number $f[4]); FoundNow = (ConvertTo-Number $f[5]) })
            }
            'ANON_R_ACCOUNTS' {
                $f = $line.Split('|')
                $r.Accounts = [pscustomobject]@{ MasterOnly = (ConvertTo-Number $f[1]); Both = (ConvertTo-Number $f[2]);
                                                 StructureOnly = (ConvertTo-Number $f[3]); ReferenceOnly = (ConvertTo-Number $f[4]) }
            }
            'ANON_R_IDNOTES' {
                $f = $line.Split('|')
                $r.IdNotes = [pscustomobject]@{ SameText = (ConvertTo-Number $f[1]); Precedence = (ConvertTo-Number $f[2]);
                                                Drift = (ConvertTo-Number $f[3]); Superseded = (ConvertTo-Number $f[4]) }
            }
            'ANON_R_XREASON' {
                $f = $line.Split([char[]]@('|'), 11)
                $x = [pscustomobject]@{ Code = $f[1]; Sort = (ConvertTo-Number $f[2]); Label = $f[3]; Parties = (ConvertTo-Number $f[4]);
                                        InTiers = (ConvertTo-Number $f[5]); PartyNode = (ConvertTo-Number $f[6]);
                                        OtherScreen = (ConvertTo-Number $f[7]); RefsOnly = (ConvertTo-Number $f[8]); Brief = $f[9];
                                        Why = ''; Fix = ''; Sql = (New-Object 'System.Collections.Generic.List[string]') }
                $reasons[$x.Code] = $x
                $r.XReasons.Add($x)
            }
            { $_ -eq 'ANON_R_XWHY' -or $_ -eq 'ANON_R_XFIX' -or $_ -eq 'ANON_R_XSQL' } {
                $f = $line.Split([char[]]@('|'), 3)
                if ($f.Count -lt 3 -or -not $reasons.ContainsKey($f[1])) { continue }
                if ($tag -eq 'ANON_R_XWHY') { $reasons[$f[1]].Why = $f[2] }
                elseif ($tag -eq 'ANON_R_XFIX') { $reasons[$f[1]].Fix = $f[2] }
                else { $reasons[$f[1]].Sql.Add($f[2]) }
            }
            'ANON_R_XTABLE' {
                $f = $line.Split('|')
                $r.XTables.Add([pscustomobject]@{ Table = $f[1]; Rows = (ConvertTo-Number $f[2]); Columns = (ConvertTo-Number $f[3]) })
            }
            'ANON_R_HARVEST' {
                $f = $line.Split('|')
                $r.Harvest.Add([pscustomobject]@{ Domain = $f[1]; Codes = (ConvertTo-Number $f[2]); Columns = (ConvertTo-Number $f[3]);
                                                  Rows = (ConvertTo-Number $f[4]) })
            }
            'ANON_R_ITEM' {
                $f = $line.Split('|')
                $r.Items.Add([pscustomobject]@{ Seq = [int](ConvertTo-Number $f[1]); Table = $f[2]; Column = $f[3]; Rule = $f[4];
                                                Category = $f[5]; Source = $f[6]; State = $f[7] })
            }
            'ANON_R_STEP' {
                $f = $line.Split([char[]]@('|'), 9)
                $r.Steps.Add([pscustomobject]@{ Id = [long](ConvertTo-Number $f[1]); Phase = $f[2]; Status = $f[3];
                                                Rows = (ConvertTo-Number $f[4]); X = (ConvertTo-Number $f[5]); Ms = (ConvertTo-Number $f[6]);
                                                Object = $f[7]; Message = $(if ($f.Count -ge 9) { $f[8] } else { '' }) })
            }
            'ANON_R_ESTIMATE' {
                $f = $line.Split('|')
                $r.Estimate = [pscustomobject]@{ Seconds = (ConvertTo-Number $f[1]); Basis = $f[2] }
            }
            'ANON_R_TRIGGERS' { $r.Triggers = ConvertTo-Number ($line.Split('|')[1]) }
            'ANON_R_V' {
                $f = $line.Split([char[]]@('|'), 7)
                $r.Verify.Add([pscustomobject]@{ Part = $f[1]; Status = $f[2]; Bad = (ConvertTo-Number $f[3]); Total = (ConvertTo-Number $f[4]);
                                                 Check = $f[5]; Detail = $(if ($f.Count -ge 7) { $f[6] } else { '' }) })
            }
            'ANON_R_END' { $r.Complete = $true }
        }
    }
    $r.Checks = ConvertFrom-CheckLines $Lines
    if ($r.XReasons.Count -gt 0) { $r.XReasons = @($r.XReasons | Sort-Object Sort) }
    return $r
}

# The figures of a run, from its results: by kind of work, what was left for
# review, what is not in this database, and the verdict a run is expected to
# end with.
function Get-Figures {
    param($Results)
    $here = @($Results.Items | Where-Object { $_.State -eq 'HERE' })
    # Free text is emptied table by table: the tables its statements worked
    # on, as the live line counts them.
    $freeTables = @($Results.Steps | Where-Object { $_.Phase -eq 'NULL_OUT' -and $_.Status -ne 'SKIPPED' } |
                    ForEach-Object { $_.Object -replace '\..*$', '' } | Sort-Object -Unique)
    $fig = [pscustomobject]@{
        Free = [pscustomobject]@{ Columns = @($here | Where-Object { $_.Rule -eq 'NULL_OUT' }).Count;
                                  Tables = $freeTables.Count; Rows = 0.0; Ms = 0.0 }
        Ids = [pscustomobject]@{ Columns = @($here | Where-Object { $_.Rule -eq 'CODE' }).Count; Rows = 0.0; X = 0.0; Ms = 0.0; NoClient = 0 }
        Labels = [pscustomobject]@{ Columns = @($here | Where-Object { $_.Rule -eq 'DESCRIPTION' }).Count; Rows = 0.0; Ms = 0.0 }
        Attrs = [pscustomobject]@{ Columns = @($here | Where-Object { $_.Rule -eq 'SELF_CODE' }).Count; Rows = 0.0; Ms = 0.0 }
        Review = (New-Object 'System.Collections.Generic.List[object]'); ReviewRows = 0.0; ReviewColumns = 0;
        Rows = 0.0; Tables = 0; XParties = 0.0; NotHere = 0; TablesNotHere = 0; ColumnsNotHere = 0;
        SwitchesOff = @(); Expected = 'PASS'; Recorded = 0.0; Reused = 0.0
    }
    $changed = @{}
    $codeRows = @{}
    foreach ($s in $Results.Steps) {
        $counted = ($s.Status -eq 'OK' -or $s.Status -eq 'DRYRUN')
        $target = $null
        switch ($s.Phase) {
            'NULL_OUT'    { $target = $fig.Free }
            'CODE'        { $target = $fig.Ids }
            'DESCRIPTION' { $target = $fig.Labels }
            'SELF_CODE'   { $target = $fig.Attrs }
            'MAPPING'     {
                if ($counted) { $fig.Recorded += $s.Rows }
            }
        }
        if ($null -eq $target) { continue }
        $target.Ms += $s.Ms
        if ($counted) {
            $target.Rows += $s.Rows
            if ($s.Phase -eq 'CODE') { $fig.Ids.X += $s.X }
            if ($s.Rows -gt 0) { $changed[($s.Object -replace '\..*$', '')] = $true }
        }
        if ($s.Phase -eq 'CODE' -and $s.Status -ne 'SKIPPED' -and $s.Status -ne 'DISABLED') {
            $column = $s.Object -replace ' .*$', ''
            if (-not $codeRows.ContainsKey($column)) { $codeRows[$column] = 0.0 }
            if ($counted -or $s.Status -eq 'REVIEW') { $codeRows[$column] += $s.Rows }
        }
        if ($s.Status -eq 'REVIEW') {
            $fig.Review.Add($s)
            $fig.ReviewRows += $s.Rows
        }
    }
    foreach ($c in $codeRows.Keys) { if ($codeRows[$c] -eq 0) { $fig.Ids.NoClient++ } }
    $fig.ReviewColumns = @($fig.Review | ForEach-Object { $_.Object -replace ' .*$', '' } | Sort-Object -Unique).Count
    $fig.Rows = $fig.Free.Rows + $fig.Ids.Rows + $fig.Labels.Rows + $fig.Attrs.Rows
    $fig.Tables = $changed.Count
    foreach ($x in $Results.XReasons) { $fig.XParties += $x.Parties }
    $fig.NotHere = @($Results.Items | Where-Object { $_.State -ne 'HERE' }).Count
    $fig.TablesNotHere = @($Results.Items | Where-Object { $_.State -eq 'NO_TABLE' } | ForEach-Object { $_.Table } | Sort-Object -Unique).Count
    $fig.ColumnsNotHere = @($Results.Items | Where-Object { $_.State -eq 'NO_COLUMN' }).Count
    foreach ($i in $Results.Ident) { $fig.Reused += $i.Reused }
    foreach ($s in $Results.Settings) {
        $name = ($script:CategoryNames[$s.Category] -replace ' \(.*$', '').ToLowerInvariant()
        if ($s.Id -eq 'N') { $fig.SwitchesOff += ($name + ' codes') }
        if ($s.Desc -eq 'N') { $fig.SwitchesOff += ($name + ' labels') }
        if ($s.Attr -eq 'N') { $fig.SwitchesOff += ($name + ' attributes') }
    }
    $drift = 0
    if ($null -ne $Results.IdNotes) { $drift = $Results.IdNotes.Drift }
    if ($fig.ReviewRows -gt 0 -or $drift -gt 0) { $fig.Expected = 'REVIEW REQUIRED' }
    elseif ($fig.SwitchesOff.Count -gt 0) { $fig.Expected = 'INCOMPLETE' }
    return $fig
}

# The verification by part: checked, failed, for review, switched off.
function Get-VerifyParts {
    param($Results)
    $names = [ordered]@{ 'SETUP' = 'Run to verify'; 'IDENTITY' = 'Identities and translations'; 'RESIDUAL' = 'Identifier columns';
                         'FREETEXT' = 'Free text'; 'LABELS' = 'Labels and attributes'; 'MAPPING' = 'Mapping integrity';
                         'SETTINGS' = 'Protections switched off' }
    $parts = New-Object 'System.Collections.Generic.List[object]'
    foreach ($k in $names.Keys) {
        $rows = @($Results.Verify | Where-Object { $_.Part -eq $k -and $_.Status -ne 'INFO' -and $_.Status -ne 'WARN' })
        if ($rows.Count -eq 0) { continue }
        $parts.Add([pscustomobject]@{ Part = $k; Name = $names[$k];
                                      Checked = @($rows | Where-Object { $_.Status -ne 'SKIP' }).Count;
                                      Failed = @($rows | Where-Object { $_.Status -eq 'FAIL' }).Count;
                                      Review = @($rows | Where-Object { $_.Status -eq 'REVIEW' }).Count;
                                      Off = @($rows | Where-Object { $_.Status -eq 'DISABLED' }).Count;
                                      Skipped = @($rows | Where-Object { $_.Status -eq 'SKIP' }).Count })
    }
    return ,$parts.ToArray()
}

# How the run ends: its exit code, the verdict in a word and the code in
# words.
function Get-RunEnd {
    param($State, [string]$Status, $VerifyCode)
    $end = [pscustomobject]@{ ExitCode = $script:ExitError; Verdict = $Status; Words = 'failed'; Color = 'Red' }
    switch ($Status) {
        'REFUSED'   { $end.Verdict = 'NOT STARTED'; $end.Words = 'not started, its checks refused it' }
        'CANCELLED' { $end.Verdict = 'NOT STARTED'; $end.Words = 'not started, it was not confirmed' }
        'STOPPED'   { $end.ExitCode = $script:ExitStopped; $end.Verdict = 'STOPPED'; $end.Words = 'stopped with Ctrl+C'; $end.Color = 'Yellow' }
        'COMPLETED' {
            if ($State.DryRun) {
                $end.ExitCode = $script:ExitPass
                $end.Verdict = 'DRY RUN'
                $end.Words = 'the dry run completed'
                $end.Color = 'Green'
            } else {
                switch ($VerifyCode) {
                    0 { $end.ExitCode = $script:ExitPass; $end.Verdict = 'PASS'; $end.Words = 'done, verified: PASS'; $end.Color = 'Green' }
                    2 { $end.ExitCode = $script:ExitVerifyFail; $end.Verdict = 'FAIL'; $end.Words = 'done, verification FAILED: client data is still present' }
                    3 { $end.ExitCode = $script:ExitReview; $end.Verdict = 'REVIEW REQUIRED'; $end.Words = 'done, review required'; $end.Color = 'Yellow' }
                    4 { $end.ExitCode = $script:ExitIncomplete; $end.Verdict = 'INCOMPLETE'; $end.Words = 'done, incomplete: a protection was switched off'; $end.Color = 'Yellow' }
                    default {
                        # Changed but not verified: not a pass until it is.
                        $end.ExitCode = $script:ExitVerifyFail
                        $end.Verdict = 'NOT VERIFIED'
                        $end.Words = 'done, but the verification could not run'
                    }
                }
            }
        }
    }
    return $end
}

# ----------------------------------------------------------------------------
# The end of a run
# ----------------------------------------------------------------------------

function Show-RunEnd {
    param($State, [string]$Status, $End)
    $results = $State.Results
    $fig = Get-Figures $results
    Write-Out ''
    switch ($Status) {
        'REFUSED'   { Show-RefusedEnd $State }
        'CANCELLED' {
            Write-Rule 'Yellow'
            Write-Out '  NOT STARTED   You did not type YES. Nothing was changed.' 'Yellow'
            Write-Rule 'Yellow'
            Write-Out ('  Next     ' + $script:Launcher + '     asks again, after the same checks')
        }
        'FAILED'    { Show-FailedEnd $State $fig }
        'STOPPED'   { Show-StoppedEnd $State $fig }
        default {
            if ($State.DryRun) { Show-DryRunEnd $State $fig } else { Show-DoneEnd $State $fig $End }
        }
    }
}

# "What / Columns / Rows ..." of the work, done or to do.
function Show-WorkTable {
    param($Fig, [bool]$DryRun)
    $rowsHead = 'Rows changed'
    if ($DryRun) { $rowsHead = 'Rows to change' }
    $head = '   ' + 'What'.PadRight(30) + 'Columns'.PadLeft(7) + $rowsHead.PadLeft(17) + 'Of them X_'.PadLeft(13)
    if (-not $DryRun) { $head = $head + 'Time'.PadLeft(9) }
    Write-Out $head 'White'
    $rows = @(
        @('Free text emptied', $Fig.Free.Columns, $Fig.Free.Rows, $null, $Fig.Free.Ms),
        @('Identifiers renamed', $Fig.Ids.Columns, $Fig.Ids.Rows, $Fig.Ids.X, $Fig.Ids.Ms),
        @('Labels masked', $Fig.Labels.Columns, $Fig.Labels.Rows, $null, $Fig.Labels.Ms),
        @('Attributes masked', $Fig.Attrs.Columns, $Fig.Attrs.Rows, $null, $Fig.Attrs.Ms))
    foreach ($r in $rows) {
        $x = '-'
        if ($null -ne $r[3]) { $x = Format-Count $r[3] }
        $line = '   ' + ([string]$r[0]).PadRight(30) + ([string]$r[1]).PadLeft(7) + (Format-Count $r[2]).PadLeft(17) + $x.PadLeft(13)
        if (-not $DryRun) { $line = $line + (Format-Clock ($r[4] / 1000)).PadLeft(9) }
        Write-Out $line
    }
    if ($Fig.ReviewRows -gt 0) {
        $line = '   ' + 'Left as they are, for review'.PadRight(30) + ([string]$Fig.ReviewColumns).PadLeft(7) +
                (Format-Count $Fig.ReviewRows).PadLeft(17) + '-'.PadLeft(13)
        if (-not $DryRun) { $line = $line + '-'.PadLeft(9) }
        Write-Out $line 'Yellow'
    }
}

function Show-IdentityTable {
    param($Results)
    if ($Results.Ident.Count -eq 0) { return }
    Write-Out ''
    Write-Out ('   ' + 'Identities'.PadRight(26) + 'Found'.PadLeft(8) + 'New translations'.PadLeft(19) + 'Reused'.PadLeft(9)) 'White'
    foreach ($i in $Results.Ident) {
        $note = ''
        if ($i.Category -eq 'UNCLASSIFIED_PARTY' -and $i.Found -gt 0) { $note = 'by reason below' }
        if ($i.Category -eq 'BANK_ACCOUNT' -and $null -ne $Results.Accounts -and $Results.Accounts.StructureOnly -gt 0) {
            $note = (Format-Count $Results.Accounts.StructureOnly) + ' only on the structure'
        }
        $line = '   ' + $script:CategoryNames[$i.Category].PadRight(26) + (Format-Count $i.Found).PadLeft(8) +
                (Format-Count $i.New).PadLeft(19) + (Format-Count $i.Reused).PadLeft(9)
        if ($note -ne '') { $line = $line + '   ' + $note }
        Write-Out $line
    }
}

# The unclassified parties: by reason with the reason in one line, and where
# their X_ values go.
function Show-Unclassified {
    param($Results, $Fig, [bool]$DryRun)
    if ($Results.XReasons.Count -eq 0) { return }
    Write-Out ''
    $total = Format-Count $Fig.XParties
    if ($DryRun) {
        Write-Out ('   Unclassified parties (X_): ' + $total + '. The data does not say which kind of party they are.')
        Write-Out ('     ' + 'Reason'.PadRight(25) + 'Parties'.PadLeft(8) + 'In tiers'.PadLeft(11) + 'w_tiers node'.PadLeft(15) + 'Other screen'.PadLeft(15)) 'White'
        foreach ($x in $Results.XReasons) {
            Write-Out ('     ' + $x.Label.PadRight(25) + (Format-Count $x.Parties).PadLeft(8) + (Format-Count $x.InTiers).PadLeft(11) +
                       (Format-Count $x.PartyNode).PadLeft(15) + (Format-Count $x.OtherScreen).PadLeft(15))
            if ($x.Brief -ne '') { Write-Out ('       ' + $x.Brief) 'DarkGray' }
        }
    } else {
        if ($Fig.Ids.X -gt 0) {
            Write-Out ('   Unclassified parties (X_): ' + $total + ', renamed in ' + (Format-Plural $Results.XTables.Count 'table') +
                       ' (' + (Format-Plural $Fig.Ids.X 'row') + ')')
        } else {
            Write-Out ('   Unclassified parties (X_): ' + $total + '; no row of theirs changed in this run')
        }
        foreach ($x in $Results.XReasons) {
            Write-Out ('     ' + $x.Label.PadRight(25) + (Format-Count $x.Parties).PadLeft(5) + '   ' + $x.Brief)
        }
    }
    if ($DryRun -and $Results.XTables.Count -gt 0) {
        $top = @($Results.XTables | Select-Object -First 3 | ForEach-Object { $_.Table + ' (' + (Format-Count $_.Rows) + ')' })
        $list = $top[0]
        if ($top.Count -eq 2) { $list = $top[0] + ' and ' + $top[1] }
        if ($top.Count -eq 3) { $list = $top[0] + ', ' + $top[1] + ' and ' + $top[2] }
        $where = 'Their X_ values would go to ' + (Format-Plural $Fig.Ids.X 'row') + ' in ' + (Format-Plural $Results.XTables.Count 'table')
        if ($Results.XTables.Count -gt 1) { $where = $where + ', the most in ' + $list + '.' } else { $where = $where + ': ' + $list + '.' }
        Write-Wrapped '   ' $where
        Write-Wrapped '   ' "report.html says what to do about each reason, with one query per reason that lists them. The queries read this dry run's plan: run them before the next run starts."
    }
}

function Show-Review {
    param($Fig, [bool]$DryRun)
    if ($Fig.ReviewRows -eq 0) { return }
    Write-Out ''
    if ($DryRun) {
        Write-Wrapped '   ' ('Left for review: ' + (Format-Plural $Fig.ReviewRows 'value') + ' in ' + (Format-Plural $Fig.ReviewColumns 'column') +
                              '. A run leaves them as they are, and its verification says REVIEW REQUIRED while they remain.') 'Yellow'
    } else {
        Write-Wrapped '   ' ('Left for review: ' + (Format-Plural $Fig.ReviewRows 'value') + ' in ' + (Format-Plural $Fig.ReviewColumns 'column') +
                              ', as they were. The verification says REVIEW REQUIRED while they remain.') 'Yellow'
    }
    foreach ($r in $Fig.Review) {
        Write-Out ('     ' + $r.Object.PadRight(58) + (Format-Count $r.Rows).PadLeft(8))
    }
}

# What to know: the inventory items not in this database, the triggers,
# codes found only in references, classifications that drifted, and the
# verification's warnings.
function Get-GoodToKnow {
    param($Results, $Fig, [bool]$DryRun)
    $results = $Results
    $items = @()
    foreach ($w in @($results.Verify | Where-Object { $_.Status -eq 'WARN' })) {
        if ($w.Detail -match '^([\d,]+) value\(s\) in ([\d,]+) column\(s\)') {
            $items += ('Values that are no client code this run knows - currencies, product codes, system values - were found in ' +
                       'identifier columns: ' + (Format-Plural (ConvertTo-Number $Matches[1]) 'value') + ' in ' +
                       (Format-Plural (ConvertTo-Number $Matches[2]) 'column') + '. Not a leak by itself; a client code among ' +
                       'them belongs in anon_meta.confirmed_identity (verify.txt names the columns).')
        } else {
            $items += ($w.Check + ': ' + $w.Detail)
        }
    }
    if ($Fig.NotHere -gt 0) {
        $text = (Format-Plural $Fig.NotHere 'item') + ' of the inventory are not in this database: ' + (Format-Plural $Fig.TablesNotHere 'table') +
                ' and ' + (Format-Plural $Fig.ColumnsNotHere 'column') + '. They are skipped; report.html lists them.'
        $items += $text
    }
    foreach ($h in $results.Harvest) {
        $what = 'parties: each gets its own X_ value (missing master)'
        if ($h.Domain -eq 'ACCOUNT') { $what = 'bank accounts: each gets its own CB_ value' }
        $items += ('Codes found only in references, their master row deleted, are ' + $what + '. ' +
                   (Format-Plural $h.Codes 'code') + ', in ' + (Format-Plural $h.Rows 'row') + ' of ' + (Format-Plural $h.Columns 'column') + '.')
    }
    if ($null -ne $results.IdNotes -and $results.IdNotes.Drift -gt 0) {
        $items += ((Format-Plural $results.IdNotes.Drift 'identity' 'identities') + ' would be classified differently today than when they were recorded: the recorded translation is kept, and the verification says REVIEW REQUIRED.')
    }
    if ($DryRun -and $results.Triggers -gt 0) {
        $items += ('A run disables the ' + (Format-Count $results.Triggers) + ' triggers of OP while it works, and enables them again at its end.')
    }
    return ,$items
}

function Show-GoodToKnow {
    param([string[]]$Items)
    if ($Items.Count -eq 0) { return }
    Write-Out ''
    Write-Out ('  Good to know (' + $Items.Count + ')') 'White'
    foreach ($i in $Items) { Write-Wrapped '   - ' $i }
}

# The end of a dry run: what a run would change, how it would end, about how
# long it would take; the figures, the identities, the X_ parties, what would
# be left for review, what to know, and the next command.
function Show-DryRunEnd {
    param($State, $Fig)
    $results = $State.Results
    Write-Rule
    Write-Out ('  A run would change ' + (Format-Plural $Fig.Rows 'row') + ' in ' + (Format-Plural $Fig.Tables 'table') + '.') 'White'
    switch ($Fig.Expected) {
        'REVIEW REQUIRED' {
            $why = (Format-Plural $Fig.ReviewRows 'value') + ' in ' + (Format-Plural $Fig.ReviewColumns 'column') + ' would be left for review.'
            if ($Fig.ReviewRows -eq 0) { $why = 'identities classified differently today than when they were recorded.' }
            Write-Wrapped '  ' ('It would end REVIEW REQUIRED: ' + $why) 'Yellow'
        }
        'INCOMPLETE' { Write-Wrapped '  ' ('It would end INCOMPLETE: ' + ($Fig.SwitchesOff -join ', ') + ' switched off.') 'Yellow' }
        default { Write-Out '  Its verification would be expected to PASS.' 'White' }
    }
    if ($null -ne $results.Estimate -and $results.Estimate.Seconds -gt 0) {
        $basis = 'a rough estimate'
        if ($results.Estimate.Basis -like 'R-*') { $basis = 'a rough estimate, from the speed of ' + $results.Estimate.Basis + ' on this database' }
        $about = Format-About $results.Estimate.Seconds
        Write-Out ('  ' + $about.Substring(0, 1).ToUpperInvariant() + $about.Substring(1) + ', ' + $basis + '. Nothing was changed.') 'White'
    } else {
        Write-Out '  Nothing was changed.' 'White'
    }
    Write-Rule
    Show-WorkTable $Fig $true
    Show-IdentityTable $results
    Show-Unclassified $results $Fig $true
    Show-Review $Fig $true
    Show-GoodToKnow (Get-GoodToKnow $results $Fig $true)
    Write-Out ''
    Write-Out '  Nothing was changed.' 'Green'
    Write-Out ('  Next     ' + $script:Launcher + '     the run itself (it checks again, then asks)')
}

# The end of a run that completed: what was done, in how long, and what its
# verification says.
function Show-DoneEnd {
    param($State, $Fig, $End)
    $results = $State.Results
    $seconds = 0.0
    foreach ($d in $State.Durations) { if ($d.Key -ne 'READY') { $seconds += $d.Seconds } }
    Write-Rule $End.Color
    Write-Out ('  DONE   ' + (Format-Plural $Fig.Rows 'row') + ' changed in ' + (Format-Clock $seconds) + '. Verification: ' + $End.Verdict + '.') $End.Color
    switch ($End.Verdict) {
        'PASS' { Write-Wrapped '         ' 'Every protection was on, no original value was found where the inventory covers, and nothing was left for review.' $End.Color }
        'REVIEW REQUIRED' {
            if ($Fig.ReviewRows -gt 0) {
                Write-Wrapped '         ' ((Format-Plural $Fig.ReviewRows 'client value') + ' in ' + (Format-Plural $Fig.ReviewColumns 'column') +
                                           ' were left as they are, on purpose; their role is not settled.') $End.Color
            } else {
                Write-Wrapped '         ' 'Identities are classified differently today than when they were recorded; report.html lists what to review.' $End.Color
            }
        }
        'INCOMPLETE' { Write-Wrapped '         ' ('Nothing was found where protection was on, but ' + ($Fig.SwitchesOff -join ', ') + ' were switched off: their client data stays.') $End.Color }
        'FAIL' { Write-Wrapped '         ' 'Client data is still present where it should have been replaced: report.html names the columns.' $End.Color }
        'NOT VERIFIED' { Write-Wrapped '         ' ('The verification could not run: run ' + 'sqlplus op/<password>@' + $State.Tns + ' @op\verify\verify_op_coverage.sql.') $End.Color }
    }
    Write-Rule $End.Color
    Show-WorkTable $Fig $false
    $parts = Get-VerifyParts $results
    if ($parts.Count -gt 0) {
        Write-Out ''
        Write-Out ('   ' + 'Verification'.PadRight(30) + 'Checked'.PadLeft(8) + 'Failed'.PadLeft(9) + 'For review'.PadLeft(13)) 'White'
        foreach ($p in $parts) {
            if ($p.Part -eq 'SETTINGS') {
                $note = 'none'
                if ($p.Off -gt 0) { $note = (Format-Plural $p.Off 'protection') + ' off' }
                Write-Out ('   ' + $p.Name.PadRight(30) + '-'.PadLeft(8) + '-'.PadLeft(9) + '-'.PadLeft(13) + '   ' + $note)
                continue
            }
            $color = ''
            if ($p.Failed -gt 0) { $color = 'Red' } elseif ($p.Review -gt 0) { $color = 'Yellow' }
            Write-Out ('   ' + $p.Name.PadRight(30) + (Format-Count $p.Checked).PadLeft(8) + (Format-Count $p.Failed).PadLeft(9) +
                       (Format-Count $p.Review).PadLeft(13)) $color
        }
    }
    Show-Unclassified $results $Fig $false
    Show-Review $Fig $false
    Show-GoodToKnow (Get-GoodToKnow $results $Fig $false)
    Write-Out ''
    switch ($End.Verdict) {
        'PASS' { Write-Wrapped '  Next     ' 'keep this run folder with the copy: report.html, verify.txt and manifest.txt say what was done to it.' }
        'REVIEW REQUIRED' { Write-Wrapped '  Next     ' ('decide on what was left for review (report.html, "Left for review"). A new run on this data keeps every translation.') }
        'INCOMPLETE' { Write-Wrapped '  Next     ' 'to complete it, switch the protections on in config\anonymization.ini and run again: the translations are kept.' }
        default { Write-Wrapped '  Next     ' 'do not hand over this copy: report.html names the columns that still hold client data.' }
    }
}

# A run its checks refused: the check that refused it, and what to do.
function Show-RefusedEnd {
    param($State)
    $unmet = @($State.Checks | Where-Object { $_.Status -eq 'NOT_MET' -and $_.Needed -eq 'REQUIRED' })
    $why = ''
    if ($unmet.Count -gt 0) { $why = ' ' + $unmet[0].Title + ': not met.' }
    elseif ($null -ne $State.Refusal) { $why = ' ' + $State.Refusal.Message }
    Write-Rule 'Red'
    Write-Wrapped '  NOT STARTED   ' ('Nothing was changed.' + $why) 'Red'
    Write-Rule 'Red'
    $first = $true
    foreach ($c in $unmet) {
        if ($c.ToDo -eq '') { continue }
        $label = '           '
        if ($first) { $label = '  Next     ' }
        Write-Wrapped $label $c.ToDo
        $first = $false
    }
    if ($first) { Write-Wrapped '  Next     ' 'report.txt says what the checks found.' }
    Write-Out ('           Then ' + $script:Launcher + ' /dryrun')
}

# A run that failed: how far it got, that the triggers of OP are enabled
# again, and that a new run resumes.
function Show-FailedEnd {
    param($State, $Fig)
    $worked = $Fig.Rows -gt 0 -and -not $State.DryRun
    Write-Rule 'Red'
    if ($State.Durations.Count -le 2 -and $Fig.Rows -eq 0) {
        Write-Wrapped '  FAILED   ' 'The checks could not run to their end. Nothing was changed.' 'Red'
    } elseif ($worked) {
        Write-Wrapped '  FAILED   ' ((Format-Plural $Fig.Rows 'row') + ' were changed before it failed. Each table or column is its own transaction: nothing is half done. The triggers of OP are enabled again.') 'Red'
    } else {
        Write-Wrapped '  FAILED   ' 'Nothing in OP was changed.' 'Red'
    }
    Write-Rule 'Red'
    foreach ($e in @($State.Errors | Select-Object -Unique | Select-Object -First 5)) { Write-Wrapped '   - ' $e 'Red' }
    Write-Wrapped '  Next     ' 'report.txt has the full output. Once the cause is removed, the same command resumes: the translations recorded so far are kept.'
}

function Show-StoppedEnd {
    param($State, $Fig)
    Write-Rule 'Yellow'
    if ($State.DryRun -or $Fig.Rows -eq 0) {
        Write-Wrapped '  STOPPED   ' 'On request. Nothing was changed.' 'Yellow'
    } else {
        Write-Wrapped '  STOPPED   ' ('On request, after ' + (Format-Plural $Fig.Rows 'row') + ' were changed. Every table or column done is complete, and the triggers of OP are enabled again.') 'Yellow'
    }
    Write-Rule 'Yellow'
    Write-Wrapped '  Next     ' ('the same command resumes from here, with the same translations: ' + $script:Launcher)
}

# The report in the browser: written in the run folder, said where it is, and
# opened when somebody is at the console (unless /no-open). A report that
# cannot be written or opened never fails the run.
function Show-HtmlReport {
    param($State, $Cli)
    $path = ''
    try {
        $path = Write-HtmlReport $State.Folder
    } catch {
        Write-Log (' report.html was not written: ' + $_.Exception.Message)
        return
    }
    if ($path -eq '') { return }
    $opened = ''
    if (-not $Cli.NoOpen -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
        try {
            Start-Process -FilePath $path
            $opened = '  (opened in your browser)'
        } catch {
            $opened = ''
        }
    }
    Write-Out ('  Report   ' + (Format-Folder $path) + $opened)
}
