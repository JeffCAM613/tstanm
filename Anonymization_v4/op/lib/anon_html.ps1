# ============================================================================
# OP Anonymization - report.html of a run
# ============================================================================
# Purpose : Writes report.html in a run folder from the files the run left
#           there: manifest.txt, results.txt (the figures, counts only),
#           report.txt and verify.txt. The verdict in a word, the result in
#           one sentence, the main figures, then the work, the verification,
#           what was left for review, the unclassified parties, the
#           identities, the checks, the switches, the duration of each step,
#           what to know and what comes next; folded below, every column of
#           the inventory, what is not in this database, and the full text
#           output. One file with its styles inside: it can be opened,
#           printed and sent as it is.
#
#           It reads, never re-checks: every figure is one the run or its
#           verification recorded. It holds counts and names of tables and
#           columns only - never an identifier. The queries that list the
#           unclassified parties are printed for the operator, never run.
# Usage   : Dot-sourced by anon.ps1, with anon_screen.ps1 (Get-Figures).
#           Write-HtmlReport <run folder> returns the path written, '' when
#           the folder has no manifest.
# Requires: Windows PowerShell 5.1.
# ============================================================================

function ConvertTo-HtmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Get-HtmlTable {
    param([string[]]$Head, [object[]]$Rows, [int[]]$Numeric = @(), [string]$Id = '')
    $h = New-Object System.Text.StringBuilder
    $idAttr = ''
    if ($Id -ne '') { $idAttr = ' id="' + $Id + '"' }
    $null = $h.Append('<div class="tw"><table' + $idAttr + '><thead><tr>')
    for ($i = 0; $i -lt $Head.Count; $i++) {
        $cls = ''
        if ($Numeric -contains $i) { $cls = ' class="n"' }
        $null = $h.Append('<th' + $cls + '>' + $Head[$i] + '</th>')
    }
    $null = $h.Append('</tr></thead><tbody>')
    foreach ($row in $Rows) {
        $null = $h.Append('<tr>')
        for ($i = 0; $i -lt $row.Count; $i++) {
            $cls = ''
            if ($Numeric -contains $i) { $cls = ' class="n"' }
            $null = $h.Append('<td' + $cls + '>' + [string]$row[$i] + '</td>')
        }
        $null = $h.Append('</tr>')
    }
    $null = $h.Append('</tbody></table></div>')
    return $h.ToString()
}

function Get-HtmlCard {
    param([string]$Title, [string]$Inner)
    return '<div class="card"><h2>' + $Title + '</h2>' + $Inner + '</div>'
}

function Get-HtmlFolded {
    param([string]$Summary, [string]$Inner)
    return '<div class="card"><details class="more"><summary>' + $Summary + '</summary>' + $Inner + '</details></div>'
}

function Get-HtmlPill {
    param([string]$Class, [string]$Word)
    return '<span class="pill ' + $Class + '">' + $Word + '</span>'
}

function Get-HtmlBar {
    param([string]$Label, [double]$Seconds, [double]$Max)
    $width = 0.6
    if ($Max -gt 0) { $width = [Math]::Max(0.6, [Math]::Min(100.0, 100.0 * $Seconds / $Max)) }
    $w = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}', $width)
    return '<div class="bar"><span class="bl">' + (ConvertTo-HtmlText $Label) + '</span><span class="track"><span class="fill" style="width:' +
           $w + '%"></span></span><span class="bv">' + (Format-Clock $Seconds) + '</span></div>'
}

# The rows a statement of the run changed (or would change) for one column:
# its own rows for an identifier column; the rows of the statement that
# covers it for free text, labels and attributes - one statement covers the
# columns of a table together.
function Get-ColumnFigures {
    param($Item, [object[]]$Steps, [object[]]$Verify)
    $name = $Item.Table + '.' + $Item.Column
    $phase = @{ 'CODE' = 'CODE'; 'NULL_OUT' = 'NULL_OUT'; 'DESCRIPTION' = 'DESCRIPTION'; 'SELF_CODE' = 'SELF_CODE' }[$Item.Rule]
    $fig = [pscustomobject]@{ Rows = 0.0; X = 0.0; Ms = 0.0; Review = 0.0; Statuses = @(); Shared = $false; Check = '' }
    foreach ($s in $Steps) {
        if ($s.Phase -ne $phase) { continue }
        $mine = $false
        if ($phase -eq 'CODE') {
            $mine = (($s.Object -replace ' .*$', '') -eq $name)
        } elseif ($s.Object -match ('^' + [regex]::Escape($Item.Table) + '\.\[([^\]]*)\]')) {
            $cols = @($Matches[1].Split(',') | ForEach-Object { ($_ -replace '\(masked\)$', '').Trim() })
            $mine = ($cols -contains $Item.Column)
            if ($mine -and $cols.Count -gt 1) { $fig.Shared = $true }
        } elseif ($s.Object -eq $name) {
            $mine = $true
        }
        if (-not $mine) { continue }
        $fig.Statuses += $s.Status
        if ($s.Status -eq 'REVIEW') { $fig.Review += $s.Rows; continue }
        if ($s.Status -eq 'OK' -or $s.Status -eq 'DRYRUN') { $fig.Rows += $s.Rows; $fig.X += $s.X }
        $fig.Ms += $s.Ms
    }
    $rank = @{ 'FAIL' = 5; 'REVIEW' = 4; 'DISABLED' = 3; 'WARN' = 2; 'PASS' = 1; 'SKIP' = 0; 'INFO' = 0 }
    $best = -1
    foreach ($v in $Verify) {
        if ($v.Part -ne 'RESIDUAL' -and $v.Part -ne 'FREETEXT' -and $v.Part -ne 'LABELS') { continue }
        if (($v.Check -replace ' .*$', '') -ne $name) { continue }
        $r = 0
        if ($rank.ContainsKey($v.Status)) { $r = $rank[$v.Status] }
        if ($r -gt $best) { $best = $r; $fig.Check = $v.Status }
    }
    return $fig
}

function Write-HtmlReport {
    param([string]$Folder)
    $manifestPath = Join-Path $Folder 'manifest.txt'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return '' }
    $m = @{}
    $steps = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in [System.IO.File]::ReadAllLines($manifestPath)) {
        $eq = $line.IndexOf('=')
        if ($eq -le 0) { continue }
        $m[$line.Substring(0, $eq)] = $line.Substring($eq + 1)
        if ($line -match '^step\.([A-Z]+)=([^|]*)\|(\d+)$') {
            $steps.Add([pscustomobject]@{ Key = $Matches[1]; Status = $Matches[2]; Seconds = [double]$Matches[3] })
        }
    }
    $resultsPath = Join-Path $Folder 'results.txt'
    $lines = @()
    if (Test-Path -LiteralPath $resultsPath) { $lines = @([System.IO.File]::ReadAllLines($resultsPath)) }
    $r = ConvertFrom-Results $lines
    $fig = Get-Figures $r
    $reportText = ''
    $verifyText = ''
    if (Test-Path -LiteralPath (Join-Path $Folder 'report.txt')) { $reportText = [System.IO.File]::ReadAllText((Join-Path $Folder 'report.txt')) }
    if (Test-Path -LiteralPath (Join-Path $Folder 'verify.txt')) { $verifyText = [System.IO.File]::ReadAllText((Join-Path $Folder 'verify.txt')) }

    $dry = ($m['mode'] -eq 'DRYRUN')
    $status = [string]$m['status']
    $verdict = [string]$m['verdict']
    $exitCode = [string]$m['exit_code']
    $run = [string]$m['run']
    $launcher = 'op\run_op_anonymization.bat'
    $kind = 'run'
    if ($dry) { $kind = 'dry run' }
    $when = ''
    if ($null -ne $r.Run) {
        $when = (ConvertTo-HtmlText $r.Run.Started) + ' to ' + (ConvertTo-HtmlText ($r.Run.Finished -replace '^\d{4}-\d\d-\d\d ', '')) +
                '<br>' + (Format-Clock $r.Run.Seconds)
    }
    $workSeconds = 0.0
    foreach ($s in $steps) { if ($s.Key -ne 'READY') { $workSeconds += $s.Seconds } }

    # The verdict in a word, the result in a sentence, the main figures.
    $class = 'ok'
    $badge = 'Done'
    $lead = ''
    $tiles = New-Object 'System.Collections.Generic.List[object]'
    $N = { param($v) Format-Count $v }
    switch ($status) {
        'REFUSED' {
            $class = 'bad'; $badge = 'Not started'
            $unmet = @($r.Checks | Where-Object { $_.Status -eq 'NOT_MET' -and $_.Needed -eq 'REQUIRED' })
            $what = 'The checks refused this run.'
            if ($unmet.Count -gt 0) {
                $titles = @($unmet | ForEach-Object { $_.Title.ToLowerInvariant() }) -join ', '
                $what = 'The checks refused this run: ' + $titles + ', not met.'
            }
            $lead = '<strong>' + (ConvertTo-HtmlText $what) + '</strong> Nothing was changed. Exit code 1.'
            $tiles.Add(@('0', 'rows changed'))
        }
        'CANCELLED' {
            $class = 'warn'; $badge = 'Not started'
            $lead = '<strong>The run was not confirmed.</strong> Nothing was changed. Exit code 1.'
        }
        'FAILED' {
            $class = 'bad'; $badge = 'Failed'
            if ($fig.Rows -gt 0 -and -not $dry) {
                $lead = '<strong>The run failed after ' + (& $N $fig.Rows) + ' rows were changed.</strong> Each table or column is its own transaction: nothing is half done, and the triggers of OP were enabled again. A new run resumes with the same translations. Exit code 1.'
            } else {
                $lead = '<strong>The run failed.</strong> Nothing in OP was changed. Exit code 1.'
            }
        }
        'STOPPED' {
            $class = 'warn'; $badge = 'Stopped'
            if ($fig.Rows -gt 0 -and -not $dry) {
                $lead = '<strong>Stopped on request, after ' + (& $N $fig.Rows) + ' rows were changed.</strong> Every table or column done is complete, and the triggers of OP were enabled again. A new run resumes from there with the same translations. Exit code 5.'
            } else {
                $lead = '<strong>Stopped on request.</strong> Nothing was changed. Exit code 5.'
            }
        }
        default {
            if ($dry) {
                $badge = 'Dry run'
                $lead = '<strong>A run would change ' + (& $N $fig.Rows) + ' rows in ' + $fig.Tables + ' tables.</strong> '
                if ($fig.Expected -eq 'REVIEW REQUIRED') {
                    $lead = $lead + 'It would end REVIEW REQUIRED: ' + (& $N $fig.ReviewRows) + ' values in ' + $fig.ReviewColumns + ' columns would be left for review. '
                } elseif ($fig.Expected -eq 'INCOMPLETE') {
                    $lead = $lead + 'It would end INCOMPLETE: ' + (ConvertTo-HtmlText ($fig.SwitchesOff -join ', ')) + ' switched off. '
                } else {
                    $lead = $lead + 'Its verification would be expected to PASS. '
                }
                if ($null -ne $r.Estimate -and $r.Estimate.Seconds -gt 0) {
                    $about = Format-About $r.Estimate.Seconds
                    $lead = $lead + $about.Substring(0, 1).ToUpperInvariant() + $about.Substring(1) + ', a rough estimate. '
                }
                $lead = $lead + 'Nothing was changed.'
                $tiles.Add(@((& $N $fig.Rows), 'rows a run would change'))
            } else {
                $class = @{ 'PASS' = 'ok'; 'REVIEW REQUIRED' = 'warn'; 'INCOMPLETE' = 'warn' }[$verdict]
                if ($null -eq $class) { $class = 'bad' }
                $badge = @{ 'PASS' = 'Done, PASS'; 'REVIEW REQUIRED' = 'Done, review required'; 'INCOMPLETE' = 'Done, incomplete';
                            'FAIL' = 'Done, FAIL' }[$verdict]
                if ($null -eq $badge) { $badge = 'Done, not verified' }
                $lead = '<strong>' + (& $N $fig.Rows) + ' rows changed in ' + (Format-Clock $workSeconds) + '.</strong> Verification: ' +
                        (ConvertTo-HtmlText $verdict) + '. '
                if ($verdict -eq 'REVIEW REQUIRED' -and $fig.ReviewRows -gt 0) {
                    $lead = $lead + (& $N $fig.ReviewRows) + ' client values in ' + $fig.ReviewColumns + ' columns were left as they were, on purpose. '
                } elseif ($verdict -eq 'INCOMPLETE') {
                    $lead = $lead + 'Switched off: ' + (ConvertTo-HtmlText ($fig.SwitchesOff -join ', ')) + '. '
                } elseif ($verdict -eq 'FAIL') {
                    $lead = $lead + 'Client data is still present where it should have been replaced. '
                }
                $lead = $lead + 'Exit code ' + $exitCode + '.'
                $tiles.Add(@((& $N $fig.Rows), 'rows changed'))
            }
        }
    }
    $identities = 0.0
    foreach ($i in $r.Ident) { $identities += $i.Found }
    if ($identities -gt 0) { $tiles.Add(@((& $N $identities), 'identities')) }
    if ($fig.XParties -gt 0) { $tiles.Add(@((& $N $fig.XParties), 'unclassified parties (X_)')) }
    if ($fig.ReviewRows -gt 0) { $tiles.Add(@((& $N $fig.ReviewRows), 'values left for review')) }
    if ($dry -and $status -eq 'COMPLETED' -and $null -ne $r.Estimate -and $r.Estimate.Seconds -gt 0) {
        $tiles.Add(@(((Format-About $r.Estimate.Seconds) -replace '^about ', 'about '), 'expected time of a run'))
    }
    if (-not $dry -and $status -eq 'COMPLETED') {
        $failed = @($r.Verify | Where-Object { $_.Status -eq 'FAIL' }).Count
        $tiles.Add(@([string]$failed, 'checks failed'))
        $tiles.Add(@((Format-Clock $workSeconds), 'duration of the work'))
    }
    if ($fig.NotHere -gt 0) { $tiles.Add(@((& $N $fig.NotHere), 'inventory items not in this database')) }

    $cards = New-Object 'System.Collections.Generic.List[string]'

    # What stopped a refused run.
    if ($status -eq 'REFUSED') {
        $inner = ''
        foreach ($c in @($r.Checks | Where-Object { $_.Status -eq 'NOT_MET' })) {
            $inner = $inner + '<div class="stop"><div><strong>' + (ConvertTo-HtmlText $c.Title) + '</strong> &middot; ' + $c.Needed.ToLowerInvariant() +
                     ' &middot; not met</div><div>' + (ConvertTo-HtmlText $c.Measure) + '</div>'
            if ($c.Happens -ne '') { $inner = $inner + '<div><strong>What happens:</strong> ' + (ConvertTo-HtmlText $c.Happens) + '</div>' }
            if ($c.ToDo -ne '') { $inner = $inner + '<div><strong>What to do:</strong> ' + (ConvertTo-HtmlText $c.ToDo) + '</div>' }
            $inner = $inner + '</div>'
        }
        if ($inner -ne '') { $cards.Add((Get-HtmlCard 'What stopped it' $inner)) }
    }

    # The work, done or to do.
    if ($r.Steps.Count -gt 0) {
        $rowsHead = 'Rows changed'
        if ($dry) { $rowsHead = 'Rows to change' }
        $head = @('What', 'Columns', $rowsHead, 'Of them X_')
        if (-not $dry) { $head += 'Time' }
        $rows = @()
        foreach ($w in @(@('Free text emptied', $fig.Free.Columns, $fig.Free.Rows, '-', $fig.Free.Ms),
                         @('Identifiers renamed', $fig.Ids.Columns, $fig.Ids.Rows, (& $N $fig.Ids.X), $fig.Ids.Ms),
                         @('Labels masked', $fig.Labels.Columns, $fig.Labels.Rows, '-', $fig.Labels.Ms),
                         @('Attributes masked', $fig.Attrs.Columns, $fig.Attrs.Rows, '-', $fig.Attrs.Ms))) {
            $row = @($w[0], [string]$w[1], (& $N $w[2]), $w[3])
            if (-not $dry) { $row += (Format-Clock ($w[4] / 1000)) }
            $rows += ,$row
        }
        if ($fig.ReviewRows -gt 0) {
            $row = @('Left as they are, for review', [string]$fig.ReviewColumns, (& $N $fig.ReviewRows), '-')
            if (-not $dry) { $row += '-' }
            $rows += ,$row
        }
        $title = 'What was done'
        $note = 'Columns: those of the inventory in this database. Free text: the rows that had a value, in ' + $fig.Free.Tables +
                ' tables, one statement per table. ' + $fig.Ids.NoClient + ' identifier columns held no client code.'
        if ($dry) {
            $title = 'What a run would change'
            $note = 'Columns: those of the inventory in this database. Rows: what the count found; a run changes the same rows unless the data changes in between. Free text: the rows with a value, in ' +
                    $fig.Free.Tables + ' tables.'
        } elseif ($status -ne 'COMPLETED') {
            $title = 'What was done before the run ended'
        }
        $cards.Add((Get-HtmlCard $title ((Get-HtmlTable $head $rows @(1, 2, 3, 4)) + '<div class="muted">' + $note + '</div>')))
    }

    # The verification.
    if (-not $dry -and $r.Verify.Count -gt 0) {
        $li = New-Object System.Text.StringBuilder
        foreach ($p in (Get-VerifyParts $r)) {
            $pill = Get-HtmlPill 'ok' 'Pass'
            $text = (& $N $p.Checked) + ' checked'
            if ($p.Part -eq 'SETTINGS') {
                if ($p.Off -gt 0) { $pill = Get-HtmlPill 'warn' 'Off'; $text = $p.Off.ToString() + ' protections switched off' }
                else { $pill = Get-HtmlPill 'skip' 'None'; $text = 'every switch was on' }
            } elseif ($p.Failed -gt 0) {
                $pill = Get-HtmlPill 'bad' 'Fail'; $text = $text + '; ' + $p.Failed + ' failed'
            } elseif ($p.Review -gt 0) {
                $pill = Get-HtmlPill 'warn' 'Review'; $text = $text + '; ' + $p.Review + ' hold values left for review'
            }
            if ($p.Skipped -gt 0) { $text = $text + '; ' + $p.Skipped + ' not in this database' }
            $null = $li.Append('<li>' + $pill + ' <strong>' + $p.Name + '</strong> <span class="muted">' + (ConvertTo-HtmlText $text) + '</span></li>')
        }
        foreach ($v in @($r.Verify | Where-Object { $_.Status -eq 'FAIL' -or $_.Status -eq 'WARN' } | Select-Object -First 40)) {
            $pill = Get-HtmlPill 'bad' 'Fail'
            if ($v.Status -eq 'WARN') { $pill = Get-HtmlPill 'warn' 'Note' }
            $null = $li.Append('<li>' + $pill + ' <code>' + (ConvertTo-HtmlText $v.Check) + '</code> <span class="muted">' + (ConvertTo-HtmlText $v.Detail) + '</span></li>')
        }
        $result = '<div><strong>Result: ' + (ConvertTo-HtmlText $verdict) + ', exit code ' + $exitCode + '.</strong> <span class="muted">PASS needs every protection on, no original left, and nothing left for review.</span></div>'
        $cards.Add((Get-HtmlCard 'Verification' ('<ul class="cmp">' + $li.ToString() + '</ul>' + $result)))
    }

    # What was left for review.
    if ($fig.Review.Count -gt 0) {
        $rows = @()
        foreach ($v in $fig.Review) { $rows += ,@(('<code>' + (ConvertTo-HtmlText $v.Object) + '</code>'), (& $N $v.Rows), (ConvertTo-HtmlText $v.Message)) }
        $lead2 = 'A run would leave ' + (& $N $fig.ReviewRows) + ' values in ' + $fig.ReviewColumns + ' columns as they are, because their role is not settled. Its verification would say REVIEW REQUIRED (exit code 3) while they remain.'
        if (-not $dry) { $lead2 = (& $N $fig.ReviewRows) + ' client values in ' + $fig.ReviewColumns + ' columns were left as they were, on purpose: their role is not settled. The verification says REVIEW REQUIRED (exit code 3) while they remain.' }
        $cards.Add((Get-HtmlCard 'Left for review' ('<div>' + $lead2 + '</div>' + (Get-HtmlTable @('Column', 'Rows', 'Why') $rows @(1)))))
    }

    # The unclassified parties.
    if ($r.XReasons.Count -gt 0) {
        $rows = @()
        foreach ($x in $r.XReasons) {
            $rows += ,@((ConvertTo-HtmlText $x.Label), (& $N $x.Parties), (& $N $x.InTiers), (& $N $x.PartyNode), (& $N $x.OtherScreen),
                        (& $N $x.RefsOnly), (ConvertTo-HtmlText $x.Why))
        }
        $inner = '<div>' + (& $N $fig.XParties) + ' parties: the data does not say which kind of party they are, so they get an X_ value. By reason, and by where each one was found (parties, not rows):</div>'
        $inner = $inner + (Get-HtmlTable @('Reason', 'Parties', 'In tiers', 'On a w_tiers node', 'On another screen', 'Only in references', 'Why') $rows @(1, 2, 3, 4, 5))
        if ($dry) {
            $inner = $inner + '<h3>Before the real run: fix the data, or leave them X_</h3><ul class="plain">'
            foreach ($x in $r.XReasons) { $inner = $inner + '<li><strong>' + (ConvertTo-HtmlText $x.Label) + '</strong>: ' + (ConvertTo-HtmlText $x.Fix) + '</li>' }
            $inner = $inner + '</ul><h3>To list them: one query per reason</h3><div class="muted">They read this dry run''s plan (' + $run +
                     '), so run them before the next run starts. What they return is the client''s codes: keep it on this machine.</div>'
            foreach ($x in $r.XReasons) {
                $inner = $inner + '<div class="reason"><strong>' + (ConvertTo-HtmlText $x.Label) + '</strong><div class="q"><button type="button">Copy</button><pre>' +
                         (ConvertTo-HtmlText ($x.Sql -join "`n")) + '</pre></div></div>'
            }
        }
        if ($r.XTables.Count -gt 0) {
            $verb = 'went'
            if ($dry) { $verb = 'would go' }
            $inner = $inner + '<h3>Where their X_ values ' + $verb + ': ' + (& $N $fig.Ids.X) + ' rows in ' + $r.XTables.Count + ' tables</h3>'
            $top = @()
            $rest = @()
            $k = 0
            foreach ($t in $r.XTables) {
                $row = @(('<code>' + (ConvertTo-HtmlText $t.Table) + '</code>'), (& $N $t.Rows), (& $N $t.Columns))
                if ($k -lt 10) { $top += ,$row } else { $rest += ,$row }
                $k++
            }
            $inner = $inner + (Get-HtmlTable @('Table', 'Rows', 'Columns') $top @(1, 2))
            if ($rest.Count -gt 0) {
                $inner = $inner + '<details class="more"><summary>The other ' + $rest.Count + ' tables</summary>' + (Get-HtmlTable @('Table', 'Rows', 'Columns') $rest @(1, 2)) + '</details>'
            }
        }
        $cards.Add((Get-HtmlCard 'Unclassified parties (X_)' $inner))
    }

    # The identities.
    if ($r.Ident.Count -gt 0) {
        $rows = @()
        foreach ($i in $r.Ident) {
            $note = ''
            if ($i.Category -eq 'UNCLASSIFIED_PARTY' -and $i.Found -gt 0) { $note = 'by reason under "Unclassified parties"' }
            if ($i.Category -eq 'BANK_ACCOUNT' -and $null -ne $r.Accounts) {
                $note = (& $N $r.Accounts.MasterOnly) + ' in compte_banque only, ' + (& $N $r.Accounts.Both) + ' also on the structure, ' +
                        (& $N $r.Accounts.StructureOnly) + ' only on the structure'
                if ($r.Accounts.ReferenceOnly -gt 0) { $note = $note + ', ' + (& $N $r.Accounts.ReferenceOnly) + ' only in references' }
            }
            $rows += ,@($script:CategoryNames[$i.Category], (& $N $i.Found), (& $N $i.New), (& $N $i.Reused), (ConvertTo-HtmlText $note))
        }
        $newHead = 'New translations'
        if (-not $dry -and $status -eq 'COMPLETED') { $newHead = 'New translations recorded' }
        $muted = ''
        if ($null -ne $r.IdNotes) {
            $notes = @()
            if ($r.IdNotes.SameText -gt 0) {
                $notes += ((Format-Plural $r.IdNotes.SameText 'text is' 'texts are') + ' both a party and a bank account: each keeps its own translation.')
            }
            if ($r.IdNotes.Precedence -gt 0) {
                $notes += ((Format-Plural $r.IdNotes.Precedence 'party has' 'parties have') + ' an Entite node and another w_tiers node: one E_ value.')
            }
            if ($r.IdNotes.Drift -gt 0) {
                $notes += ((Format-Plural $r.IdNotes.Drift 'identity' 'identities') + ' would be classified differently today: the recorded translation is kept.')
            }
            if ($r.IdNotes.Superseded -gt 0) {
                $notes += ((Format-Plural $r.IdNotes.Superseded 'earlier translation is' 'earlier translations are') + ' superseded: kept, never used.')
            }
            $muted = $notes -join ' '
        }
        $cards.Add((Get-HtmlCard 'Identities' ((Get-HtmlTable @('Category', 'Found', $newHead, 'Reused', 'Notes') $rows @(1, 2, 3)) + '<div class="muted">' + $muted + '</div>')))
    }

    # The checks.
    if ($r.Checks.Count -gt 0) {
        $li = New-Object System.Text.StringBuilder
        foreach ($c in $r.Checks) {
            $pill = Get-HtmlPill 'ok' 'Met'
            if ($c.Status -eq 'NOT_MET' -and $c.Needed -eq 'REQUIRED') { $pill = Get-HtmlPill 'bad' 'Not met' }
            elseif ($c.Status -eq 'NOT_MET') { $pill = Get-HtmlPill 'warn' 'Not met' }
            elseif ($c.Status -eq 'NOTE' -and $c.Needed -eq 'OPTIONAL') { $pill = Get-HtmlPill 'warn' 'Not here' }
            elseif ($c.Status -eq 'NOTE') { $pill = Get-HtmlPill 'skip' 'Info' }
            elseif ($c.Needed -eq 'INFO') { $pill = Get-HtmlPill 'skip' 'None' }
            $null = $li.Append('<li>' + $pill + ' <strong>' + (ConvertTo-HtmlText $c.Title) + '</strong> <span class="muted">' + $c.Needed.ToLowerInvariant() +
                               ' &middot; ' + (ConvertTo-HtmlText $c.Measure) + '</span></li>')
        }
        $cards.Add((Get-HtmlCard 'Checks' ('<ul class="cmp">' + $li.ToString() + '</ul><div class="muted">Made before anything is changed. A required check that is not met stops the run there, before the question to start it.</div>')))
    }

    # The switches.
    if ($r.Settings.Count -gt 0) {
        $rows = @()
        $word = @{ 'Y' = 'yes'; 'N' = '<strong>no</strong>' }
        foreach ($s in $r.Settings) { $rows += ,@($script:CategoryNames[$s.Category], $word[$s.Id], $word[$s.Desc], $word[$s.Attr]) }
        $rows += ,@('Free text', 'always emptied', '', '')
        $options = 'APPROVE_STRUCTURE_ONLY_ACCOUNTS=' + $m['approve_structure_only_accounts'] + ', PARALLEL_DEGREE=' + $m['parallel_degree'] +
                   ', FAIL_ON_MISSING_OBJECT=' + $m['fail_on_missing_object'] + ', CUSTOM_INVENTORY=' + $m['custom_inventory'] +
                   ' (' + $m['inventory_site'] + ' items)'
        $cards.Add((Get-HtmlCard 'Switches' ((Get-HtmlTable @('Category', 'Rename codes', 'Labels', 'Attributes') $rows) +
                                             '<div class="muted">From config\anonymization.ini. Also: ' + (ConvertTo-HtmlText $options) + '.</div>')))
    }

    # The duration of each step.
    $names = @{ 'READY' = 'Getting ready'; 'CHECK' = 'Checking and planning'; 'COUNT' = 'Counting'; 'RECORD' = 'Recording the translations';
                'APPLY' = 'Anonymizing'; 'VERIFY' = 'Verifying' }
    $bars = @()
    foreach ($s in $steps) {
        if ($s.Key -eq 'COUNT' -or $s.Key -eq 'APPLY') {
            $verb = 'Counting: '
            if ($s.Key -eq 'APPLY') { $verb = '' }
            foreach ($w in @(@('free text', $fig.Free.Ms), @('identifiers', $fig.Ids.Ms), @('labels and attributes', ($fig.Labels.Ms + $fig.Attrs.Ms)))) {
                $label = $verb + $w[0]
                if ($verb -eq '') { $label = $w[0].Substring(0, 1).ToUpperInvariant() + $w[0].Substring(1) }
                $bars += ,@($label, ($w[1] / 1000))
            }
            continue
        }
        $label = $names[$s.Key]
        if ($s.Status -ne 'DONE') { $label = $label + ' (' + $s.Status.ToLowerInvariant() + ')' }
        $bars += ,@($label, $s.Seconds)
    }
    if ($bars.Count -gt 0) {
        $max = 0.0
        foreach ($b in $bars) { $max = [Math]::Max($max, [double]$b[1]) }
        $inner = ''
        foreach ($b in $bars) { $inner = $inner + (Get-HtmlBar $b[0] $b[1] $max) }
        $note = ''
        if ($dry -and $null -ne $r.Estimate) {
            $note = 'The estimate for a run: the planning this dry run took, the rows to change at '
            if ($r.Estimate.Basis -like 'R-*') { $note = $note + 'the speed of ' + $r.Estimate.Basis + ' on this database' } else { $note = $note + 'a default rate' }
            $note = $note + ', and one more pass for the verification.'
        } elseif (-not $dry) {
            $note = 'The work of each kind is the time of its statements. The wait for YES is not counted.'
        }
        $cards.Add((Get-HtmlCard 'Duration by step' ($inner + '<div class="muted">' + (ConvertTo-HtmlText $note) + '</div>')))
    }

    # What to know, and what comes next.
    $good = Get-GoodToKnow $r $fig $dry
    if ($good.Count -gt 0) {
        $cards.Add((Get-HtmlCard 'Good to know' ('<ul class="plain">' + (($good | ForEach-Object { '<li>' + (ConvertTo-HtmlText $_) + '</li>' }) -join '') + '</ul>')))
    }
    $next = @()
    switch ($status) {
        'REFUSED' {
            foreach ($c in @($r.Checks | Where-Object { $_.Status -eq 'NOT_MET' -and $_.ToDo -ne '' })) { $next += (ConvertTo-HtmlText $c.ToDo) }
            $next += ('Then a dry run: <code>' + $launcher + ' /dryrun</code>.')
        }
        'CANCELLED' { $next += ('<code>' + $launcher + '</code> asks again, after the same checks.') }
        'FAILED' { $next += 'report.txt (below) has the full output. Once the cause is removed, the same command resumes: the translations recorded so far are kept.' }
        'STOPPED' { $next += ('The same command resumes from here, with the same translations: <code>' + $launcher + '</code>.') }
        default {
            if ($dry) {
                $next += ('The run itself: <code>' + $launcher + '</code>. It checks again, shows what it will change, then asks for YES.')
            } elseif ($verdict -eq 'PASS') {
                $next += 'Keep this folder with the copy: report.html, verify.txt and manifest.txt say what was done to it.'
            } elseif ($verdict -eq 'REVIEW REQUIRED') {
                $next += 'Decide on what was left for review (above). A new run on this data keeps every translation.'
                $next += 'Keep this folder with the copy: report.html, verify.txt and manifest.txt say what was done to it.'
            } elseif ($verdict -eq 'INCOMPLETE') {
                $next += 'To complete it, switch the protections on in config\anonymization.ini and run again: the translations are kept.'
            } else {
                $next += 'Do not hand over this copy: the verification names the columns that still hold client data.'
            }
        }
    }
    $cards.Add((Get-HtmlCard 'Next' ('<ul class="plain">' + (($next | ForEach-Object { '<li>' + $_ + '</li>' }) -join '') + '</ul>')))

    # Folded: every column, what is not here, the text outputs.
    $here = @($r.Items | Where-Object { $_.State -eq 'HERE' })
    if ($here.Count -gt 0 -and $r.Steps.Count -gt 0) {
        $what = @{ 'CODE' = 'identifier'; 'NULL_OUT' = 'free text'; 'DESCRIPTION' = 'label'; 'SELF_CODE' = 'attribute' }
        $rows = @()
        foreach ($i in $here) {
            $cf = Get-ColumnFigures $i $r.Steps $r.Verify
            $holds = ''
            if ($i.Category -ne 'NONE') { $holds = ', ' + $i.Category.ToLowerInvariant().Replace('_', ' ') }
            $rowsText = & $N $cf.Rows
            if ($cf.Shared) { $rowsText = $rowsText + ' <span class="muted">(its table)</span>' }
            if ($i.Rule -eq 'NULL_OUT' -and $cf.Statuses.Count -eq 0) { $rowsText = '<span class="muted">-</span>' }
            $st = ''
            if ($cf.Review -gt 0) { $st = '<span class="st warn">review ' + (& $N $cf.Review) + '</span>' }
            elseif ($cf.Statuses -contains 'DISABLED') { $st = '<span class="st skip">switched off</span>' }
            elseif ($dry) {
                if ($cf.Rows -gt 0) { $st = '<span class="st ok">change</span>' }
                elseif ($i.Rule -eq 'CODE') { $st = '<span class="st skip">no client code</span>' }
                else { $st = '<span class="st skip">nothing to do</span>' }
            } else {
                switch ($cf.Check) {
                    'PASS' { $st = '<span class="st ok">pass</span>' }
                    'FAIL' { $st = '<span class="st bad">fail</span>' }
                    'REVIEW' { $st = '<span class="st warn">review</span>' }
                    'DISABLED' { $st = '<span class="st skip">switched off</span>' }
                    'WARN' { $st = '<span class="st warn">note</span>' }
                    default { $st = '<span class="st skip">-</span>' }
                }
            }
            $x = ''
            if ($cf.X -gt 0) { $x = & $N $cf.X }
            $row = @([string]$i.Seq, ('<code>' + (ConvertTo-HtmlText ($i.Table + '.' + $i.Column)) + '</code>'),
                     ($what[$i.Rule] + (ConvertTo-HtmlText $holds)), $rowsText, $x)
            if (-not $dry) { $row += (Format-Clock ($cf.Ms / 1000)) }
            $row += $st
            $rows += ,$row
        }
        $head = @('#', 'Column', 'What it is', 'Rows to change', 'X_', 'A run would')
        $numeric = @(0, 3, 4)
        if (-not $dry) { $head = @('#', 'Column', 'What it is', 'Rows changed', 'X_', 'Time', 'Verification'); $numeric = @(0, 3, 4, 5) }
        $inner = '<label class="muted" for="filter">Filter by table, column or word</label>' +
                 '<input id="filter" class="filter" type="search" placeholder="histo_operation, review, attribute...">' +
                 '<div class="muted"><span id="shown">' + $rows.Count + '</span> shown. Free text, labels and attributes are changed by one statement per table: a column marked "its table" shows the rows of that statement.</div>' +
                 (Get-HtmlTable $head $rows $numeric 'cols')
        $cards.Add((Get-HtmlFolded ('Every column of the inventory in this database (' + $here.Count + ')') $inner))
    }
    $absent = @($r.Items | Where-Object { $_.State -ne 'HERE' })
    if ($absent.Count -gt 0) {
        $byName = [ordered]@{}
        foreach ($i in $absent) {
            $key = $i.Table
            $why = 'table not in this database'
            if ($i.State -eq 'NO_COLUMN') { $key = $i.Table + '.' + $i.Column; $why = 'column not in this database' }
            if (-not $byName.Contains($key)) { $byName[$key] = [pscustomobject]@{ Items = 0; Why = $why } }
            $byName[$key].Items++
        }
        $rows = @()
        foreach ($k in ($byName.Keys | Sort-Object)) { $rows += ,@(('<code>' + (ConvertTo-HtmlText $k) + '</code>'), [string]$byName[$k].Items, $byName[$k].Why) }
        $inner = '<div class="muted">' + $fig.TablesNotHere + ' tables and ' + $fig.ColumnsNotHere + ' columns of the inventory. Skipped, because FAIL_ON_MISSING_OBJECT=' +
                 $m['fail_on_missing_object'] + '. A module this database does not have is the usual reason.</div>' + (Get-HtmlTable @('Table or column', 'Items', 'Why') $rows @(1))
        $cards.Add((Get-HtmlFolded ('Not in this database (' + $absent.Count + ' items)') $inner))
    }
    if ($verifyText -ne '') { $cards.Add((Get-HtmlFolded 'Verification output (verify.txt)' ('<pre>' + (ConvertTo-HtmlText $verifyText) + '</pre>'))) }
    if ($reportText -ne '') { $cards.Add((Get-HtmlFolded 'Full text report (report.txt)' ('<pre>' + (ConvertTo-HtmlText $reportText) + '</pre>'))) }

    $css = @'
:root{--bg:#f4f6f9;--card:#fff;--fg:#182131;--muted:#5a6577;--line:#d9dfe8;--accent:#2c5aa0;--ok:#1d7444;--oks:#e2f2e8;--warn:#8f5b00;--warns:#faefd9;--bad:#b42318;--bads:#fbe7e5;--track:#e6eaf0;--code:#eef1f6;color-scheme:light}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#0e131a;--card:#151c26;--fg:#e3e8ef;--muted:#98a3b5;--line:#273245;--accent:#8aaee8;--ok:#63cc90;--oks:#13301f;--warn:#e8b85e;--warns:#33270f;--bad:#f3897e;--bads:#3a1916;--track:#232c3b;--code:#1b2431;color-scheme:dark}}
:root[data-theme="dark"]{--bg:#0e131a;--card:#151c26;--fg:#e3e8ef;--muted:#98a3b5;--line:#273245;--accent:#8aaee8;--ok:#63cc90;--oks:#13301f;--warn:#e8b85e;--warns:#33270f;--bad:#f3897e;--bads:#3a1916;--track:#232c3b;--code:#1b2431;color-scheme:dark}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 "Segoe UI",system-ui,-apple-system,sans-serif}
.wrap{max-width:1000px;margin:0 auto;padding:28px 20px 60px;display:grid;gap:18px}
.head{display:flex;justify-content:space-between;gap:16px;flex-wrap:wrap;align-items:flex-end}
.kicker{font-size:.8rem;color:var(--muted);letter-spacing:.05em;text-transform:uppercase}h1{margin:0;font-size:1.7rem}
.when{color:var(--muted);text-align:right;font-size:.92rem}
.verdict{display:flex;gap:14px;align-items:center;border-radius:12px;padding:16px 18px}
.verdict.ok{background:var(--oks)}.verdict.warn{background:var(--warns)}.verdict.bad{background:var(--bads)}
.badge{flex:none;color:var(--card);font-weight:800;border-radius:999px;padding:4px 16px}
.ok .badge{background:var(--ok)}.warn .badge{background:var(--warn)}.bad .badge{background:var(--bad)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;min-width:0}
.num{font-size:1.3rem;font-weight:800;font-variant-numeric:tabular-nums;white-space:nowrap}.cap{color:var(--muted);font-size:.88rem}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px;display:grid;gap:10px;min-width:0}
h2{margin:0;font-size:1.05rem}h3{margin:6px 0 0;font-size:.95rem}
.bar{display:grid;grid-template-columns:minmax(120px,18rem) 1fr 7rem;gap:10px;align-items:center;font-size:.93rem}
.track{background:var(--track);border-radius:4px;height:14px;overflow:hidden;display:block}.fill{display:block;height:100%;border-radius:4px;background:var(--accent)}
.bv{text-align:right;font-variant-numeric:tabular-nums}
ul.cmp{list-style:none;margin:0;padding:0;display:grid;gap:7px}
.pill{display:inline-block;min-width:4.6em;text-align:center;border-radius:999px;padding:1px 10px;font-size:.8rem;font-weight:700}
.pill.ok{background:var(--oks);color:var(--ok)}.pill.warn{background:var(--warns);color:var(--warn)}.pill.bad{background:var(--bads);color:var(--bad)}.pill.skip{background:var(--track);color:var(--muted)}
.muted{color:var(--muted)}table{border-collapse:collapse;width:100%;font-size:.93rem}th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-weight:600}td.n,th.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}.tw{overflow-x:auto}
code{font-family:Consolas,"Cascadia Mono",monospace;font-size:.9em}
ul.plain{margin:0;padding-left:1.2em;display:grid;gap:6px}
pre{margin:0;overflow-x:auto;font:12.5px/1.4 Consolas,"Cascadia Mono",monospace;background:var(--code);border-radius:8px;padding:12px}
summary{cursor:pointer;font-weight:600}summary:focus-visible,button:focus-visible,input:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.foot{color:var(--muted);font-size:.88rem}
.q{position:relative}.q button{position:absolute;top:8px;right:8px;font:600 .78rem "Segoe UI",system-ui,sans-serif;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:6px;padding:3px 10px;cursor:pointer}
.reason{display:grid;gap:6px;padding-top:10px;border-top:1px solid var(--line)}
.stop{background:var(--bads);border-radius:10px;padding:12px 14px;display:grid;gap:6px}
.filter{width:100%;max-width:360px;padding:6px 10px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--fg);font:inherit}
.st{font-size:.78rem;font-weight:700;border-radius:999px;padding:0 8px;white-space:nowrap}
.st.ok{background:var(--oks);color:var(--ok)}.st.warn{background:var(--warns);color:var(--warn)}.st.bad{background:var(--bads);color:var(--bad)}.st.skip{background:var(--track);color:var(--muted)}
details.more{display:grid;gap:10px}details.more[open]>summary{margin-bottom:10px}
@media (max-width:560px){.bar{grid-template-columns:1fr 5.5rem}.bar .bl{grid-column:1/-1}.when{text-align:left}}
@media print{body{background:#fff}.card,.tile{break-inside:avoid}details{display:none}}
'@
    $js = @'
document.querySelectorAll('.q button').forEach(function (b) {
  b.addEventListener('click', function () {
    var pre = b.parentNode.querySelector('pre');
    var done = function () { b.textContent = 'Copied'; setTimeout(function () { b.textContent = 'Copy'; }, 1500); };
    try { navigator.clipboard.writeText(pre.textContent).then(done, function () { select(pre); }); } catch (e) { select(pre); }
  });
});
function select(el) { var r = document.createRange(); r.selectNodeContents(el); var s = getSelection(); s.removeAllRanges(); s.addRange(r); }
var f = document.getElementById('filter');
if (f) f.addEventListener('input', function () {
  var v = f.value.trim().toLowerCase(), shown = 0;
  document.querySelectorAll('#cols tbody tr').forEach(function (tr) {
    var on = !v || tr.textContent.toLowerCase().indexOf(v) >= 0;
    tr.hidden = !on; if (on) shown++;
  });
  document.getElementById('shown').textContent = shown;
});
'@
    $files = 'report.html, report.txt (what the engine printed), '
    if ($verifyText -ne '') { $files = $files + 'verify.txt (what the verification printed), ' }
    $files = $files + 'console.log (every line of the run), results.txt (the figures of this report), manifest.txt, inventory.sql.'
    $database = $m['database']
    if ($null -ne $r.Run -and $r.Run.Database -ne '') { $database = $r.Run.Database }

    $h = New-Object System.Text.StringBuilder
    $null = $h.Append('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
    $null = $h.Append('<title>OP Anonymization ' + (ConvertTo-HtmlText $run) + '</title><style>' + $css + '</style></head><body><div class="wrap">')
    $null = $h.Append('<div class="head"><div><div class="kicker">OP Anonymization ' + (ConvertTo-HtmlText $m['tool_version']) + ' &middot; ' + $kind +
                      '</div><h1>' + (ConvertTo-HtmlText $database) + ' &middot; run ' + (ConvertTo-HtmlText $run) + '</h1></div><div class="when">' + $when + '</div></div>')
    $null = $h.Append('<div class="verdict ' + $class + '"><span class="badge">' + (ConvertTo-HtmlText $badge) + '</span><div>' + $lead + '</div></div>')
    if ($tiles.Count -gt 0) {
        $null = $h.Append('<div class="tiles">')
        foreach ($t in $tiles) { $null = $h.Append('<div class="tile"><div class="num">' + (ConvertTo-HtmlText ([string]$t[0])) + '</div><div class="cap">' + (ConvertTo-HtmlText ([string]$t[1])) + '</div></div>') }
        $null = $h.Append('</div>')
    }
    foreach ($c in $cards) { $null = $h.Append($c) }
    $null = $h.Append('<div class="foot">Files of this run, in the same folder: ' + $files + '</div>')
    $null = $h.Append('</div><script>' + $js + '</script></body></html>')
    $path = Join-Path $Folder 'report.html'
    [System.IO.File]::WriteAllText($path, $h.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}
