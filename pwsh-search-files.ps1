# Search-Files — paste this whole file into a PowerShell 7 prompt, then call:  Search-Files
# That launches a hidden background searcher; press Ctrl+Alt+F to summon it.
# Docs & roadmap: README.md
#
# A GUI sibling of pwsh-find-files (the console tool): a hotkey-summoned window
# with a Find box on top and a results pane below. On summon it captures the
# folder of the Explorer window you were just on and uses that as the search
# root, so you browse to a folder, hit the hotkey, type a pattern, and the hits
# stream into the pane -- same full-path matching as Find-Files, just in a GUI.

# The GUI as a scriptblock so Search-Files can ship its source text to a detached
# hidden pwsh process. Same paste-friendly pattern as pwsh-switch-window / pwsh-launch.
$SearchFilesGui = {

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Host "Search-Files needs PowerShell 7 -- this is Windows PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor Red
        Write-Host "Type  pwsh  to drop into PowerShell 7, then load and run again." -ForegroundColor Yellow
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # Win32 + hotkey shim -- compiled once per session (a .NET type can't be redefined).
    if (-not ('SearchForm' -as [type])) {
        (New-Object System.Windows.Forms.Form).Dispose()
        $null = [System.Windows.Forms.Message]
        $refs = @(
            [System.AppDomain]::CurrentDomain.GetAssemblies() |
                Where-Object { -not $_.IsDynamic -and $_.Location } |
                ForEach-Object Location
            Join-Path ([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'System.Private.CoreLib.dll'
        )
        Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// Exposes the foreground window handle -- captured at hotkey time (before the
// searcher shows itself) so we can tell which Explorer window you were on.
public class SearchWin {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}

// A ListBox with double-buffering on -- kills the owner-draw flicker as rows
// stream in and when the list is rebuilt on the final re-sort.
public class BufferedListBox : ListBox {
    public BufferedListBox() { this.DoubleBuffered = true; }
}

// A Form that registers one global hotkey and raises Hotkey when it is pressed.
public class SearchForm : Form {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    const int WM_HOTKEY = 0x0312;
    const int ID = 0xB1B3;   // distinct from switch-window (0xB1B1) and launch (0xB1B2)
    public event EventHandler Hotkey;

    public bool RegisterHotkey(uint mod, uint vk) { return RegisterHotKey(this.Handle, ID, mod, vk); }
    public void ReleaseHotkey() { UnregisterHotKey(this.Handle, ID); }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY && (int)m.WParam == ID && Hotkey != null) Hotkey(this, EventArgs.Empty);
        base.WndProc(ref m);
    }
}
'@
    }

    # Per-user settings live in the registry (just the hotkey for now).
    $rootKey = 'HKCU:\Software\SearchFiles'
    if (-not (Test-Path $rootKey)) { New-Item -Path $rootKey -Force | Out-Null }

    # Fallback root when the summon wasn't over an Explorer window. S:\ is the
    # usual share; drop back to the profile folder if it isn't mapped.
    $script:fallbackRoot = 'S:\'
    if (-not (Test-Path -LiteralPath $script:fallbackRoot)) { $script:fallbackRoot = $env:USERPROFILE }

    # Search state -- all shared with the background runspace by reference.
    $script:hits         = [System.Collections.Generic.List[object]]::new()  # parallel to $list.Items
    $script:searchQueue  = $null   # ConcurrentQueue the walker pushes hits onto
    $script:searchState  = $null   # synchronized hashtable: Cancel / Scanned / Done
    $script:ps           = $null   # background PowerShell instance
    $script:rs           = $null   # its runspace
    $script:psHandle     = $null   # async handle
    $script:finalized    = $true   # guards the one-shot finalize in the drain tick
    $script:rootLeaf     = ''
    $script:lastPattern  = ''
    $script:currentWild  = ''
    $script:maxExtent    = 0     # widest row drawn so far -> the list's HorizontalExtent

    # --- form ---
    $form = New-Object SearchForm
    $form.Text            = 'Search Files'
    $form.ClientSize      = New-Object System.Drawing.Size(760, 480)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'Sizable'
    $form.TopMost         = $true
    $form.ShowInTaskbar   = $false
    $form.KeyPreview      = $true

    $rootLabel = New-Object System.Windows.Forms.Label
    $rootLabel.Text      = 'Root'
    $rootLabel.Location  = New-Object System.Drawing.Point(8, 11)
    $rootLabel.Size      = New-Object System.Drawing.Size(40, 18)
    $rootLabel.Font      = New-Object System.Drawing.Font('Consolas', 9)
    $rootLabel.ForeColor = [System.Drawing.Color]::DimGray

    $rootBox = New-Object System.Windows.Forms.TextBox
    $rootBox.Location = New-Object System.Drawing.Point(50, 8)
    $rootBox.Width    = 702
    $rootBox.Anchor   = 'Top, Left, Right'
    $rootBox.Font     = New-Object System.Drawing.Font('Consolas', 11)

    $patLabel = New-Object System.Windows.Forms.Label
    $patLabel.Text      = 'Find'
    $patLabel.Location  = New-Object System.Drawing.Point(8, 39)
    $patLabel.Size      = New-Object System.Drawing.Size(40, 18)
    $patLabel.Font      = New-Object System.Drawing.Font('Consolas', 9)
    $patLabel.ForeColor = [System.Drawing.Color]::DimGray

    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(50, 36)
    $box.Width    = 702
    $box.Anchor   = 'Top, Left, Right'
    $box.Font     = New-Object System.Drawing.Font('Consolas', 11)

    $list = New-Object BufferedListBox
    $list.IntegralHeight = $false
    $list.Location       = New-Object System.Drawing.Point(8, 66)
    $list.Size           = New-Object System.Drawing.Size(744, 380)
    $list.Anchor         = 'Top, Bottom, Left, Right'
    $list.Font           = New-Object System.Drawing.Font('Consolas', 11)
    $list.DrawMode       = 'OwnerDrawFixed'
    $list.ItemHeight     = 20
    $list.SelectionMode  = 'MultiExtended'
    $list.HorizontalScrollbar = $true

    # Owner-draw each hit: dim timestamp, then full path (both white when selected).
    $list.Add_DrawItem({
        param($s, $e)
        $e.DrawBackground()
        if ($e.Index -lt 0 -or $e.Index -ge $script:hits.Count) { return }
        $h = $script:hits[$e.Index]
        $selected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
        if ($selected) {
            $tsBrush   = [System.Drawing.SystemBrushes]::HighlightText
            $pathBrush = [System.Drawing.SystemBrushes]::HighlightText
        } else {
            $tsBrush   = [System.Drawing.Brushes]::DimGray
            $pathBrush = [System.Drawing.SystemBrushes]::WindowText
        }
        $x  = [single]($e.Bounds.X + 3)
        $y  = [single]($e.Bounds.Y + 2)
        $ts = "$($h.T)  "
        $e.Graphics.DrawString($ts, $s.Font, $tsBrush, $x, $y)
        $x += $e.Graphics.MeasureString($ts, $s.Font).Width
        $e.Graphics.DrawString($h.P, $s.Font, $pathBrush, $x, $y)
    })

    $status = New-Object System.Windows.Forms.Label
    $status.Location  = New-Object System.Drawing.Point(8, 454)
    $status.Size      = New-Object System.Drawing.Size(560, 18)
    $status.Anchor    = 'Bottom, Left'
    $status.Font      = New-Object System.Drawing.Font('Consolas', 9)
    $status.ForeColor = [System.Drawing.Color]::DimGray

    $clock = New-Object System.Windows.Forms.Label
    $clock.Location  = New-Object System.Drawing.Point(642, 454)
    $clock.Size      = New-Object System.Drawing.Size(110, 18)
    $clock.Anchor    = 'Bottom, Right'
    $clock.TextAlign = 'MiddleRight'
    $clock.Font      = New-Object System.Drawing.Font('Consolas', 9)
    $clock.ForeColor = [System.Drawing.Color]::DimGray

    $form.Controls.Add($rootLabel)
    $form.Controls.Add($rootBox)
    $form.Controls.Add($patLabel)
    $form.Controls.Add($box)
    $form.Controls.Add($list)
    $form.Controls.Add($status)
    $form.Controls.Add($clock)

    # Modal feedback helper -- same pattern as the sibling tools.
    $tell = {
        param($msg, $icon = 'Information')
        [System.Windows.Forms.MessageBox]::Show($form, $msg, 'Search Files', 'OK', $icon) | Out-Null
    }

    # --- resolve an Explorer window handle to its folder path (COM Shell.Application) ---
    $resolveExplorerFolder = {
        param($hwnd)
        if ($null -eq $hwnd) { return $null }
        $target = ([IntPtr]$hwnd).ToInt64()
        if ($target -eq 0) { return $null }
        $shell = $null
        try {
            $shell = New-Object -ComObject Shell.Application
            foreach ($w in $shell.Windows()) {
                try {
                    if ([int64]$w.HWND -eq $target) {
                        $p = $w.Document.Folder.Self.Path
                        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
                    }
                } catch { }
            }
        } catch {
        } finally {
            if ($shell) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
        }
        return $null
    }

    # --- the background tree walk (runs in its own runspace) ---
    # Reads $root / $wildcard, pushes matching FileInfo-derived rows onto
    # $searchQueue, bumps $state.Scanned, and honours $state.Cancel. Same
    # breadth-first walk as the console Find-Files, one folder at a time.
    $walkScript = {
        $dirs    = [System.Collections.Generic.Queue[string]]::new()
        $dirs.Enqueue($root)
        $scanned = 0
        while ($dirs.Count -gt 0) {
            if ($state.Cancel) { break }
            $dir = $dirs.Dequeue()
            foreach ($entry in Get-ChildItem -LiteralPath $dir -ErrorAction SilentlyContinue) {
                if ($state.Cancel) { break }
                if ($entry.PSIsContainer) {
                    $dirs.Enqueue($entry.FullName)
                } else {
                    $scanned++
                    if ($entry.FullName -like $wildcard) {
                        $searchQueue.Enqueue([pscustomobject]@{ T = $entry.LastWriteTime; P = $entry.FullName })
                    }
                    if (($scanned -band 63) -eq 0) { $state.Scanned = $scanned }
                }
            }
        }
        $state.Scanned = $scanned
        $state.Done    = $true
    }

    # --- stop and dispose any running search ---
    $cleanupSearch = {
        if ($script:searchState) { $script:searchState.Cancel = $true }
        if ($script:ps) {
            try { $script:ps.Stop() }    catch { }
            try { $script:ps.Dispose() } catch { }
            $script:ps = $null
        }
        if ($script:rs) {
            try { $script:rs.Close() }   catch { }
            try { $script:rs.Dispose() } catch { }
            $script:rs = $null
        }
        $script:psHandle  = $null
        $script:finalized = $true
        $drainTimer.Stop()
    }

    # --- start a search of $rootBox for the given pattern ---
    $startSearch = {
        param($pattern)
        $root = $rootBox.Text.Trim()
        if (-not $root -or -not (Test-Path -LiteralPath $root)) {
            & $tell "Root folder not found:`n$root" 'Warning'; return
        }
        $pat = $pattern.Trim().Trim('*')
        if (-not $pat) { & $tell 'Type something to search for.' 'Warning'; return }

        & $cleanupSearch
        $script:hits = [System.Collections.Generic.List[object]]::new()
        $list.Items.Clear()
        $script:maxExtent = 0
        $list.HorizontalExtent = 0

        $script:searchQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        $script:searchState = [hashtable]::Synchronized(@{ Cancel = $false; Scanned = 0; Done = $false })
        $script:currentWild = '*' + $pat + '*'
        $script:lastPattern = $pat
        $rootFull = (Resolve-Path -LiteralPath $root).Path
        $script:rootLeaf = Split-Path $rootFull -Leaf
        if (-not $script:rootLeaf) { $script:rootLeaf = $rootFull }
        $script:finalized = $false

        $script:rs = [runspacefactory]::CreateRunspace()
        $script:rs.Open()
        $script:rs.SessionStateProxy.SetVariable('searchQueue', $script:searchQueue)
        $script:rs.SessionStateProxy.SetVariable('state',       $script:searchState)
        $script:rs.SessionStateProxy.SetVariable('root',        $rootFull)
        $script:rs.SessionStateProxy.SetVariable('wildcard',    $script:currentWild)
        $script:ps = [powershell]::Create()
        $script:ps.Runspace = $script:rs
        [void]$script:ps.AddScript($walkScript.ToString())
        $script:psHandle = $script:ps.BeginInvoke()

        $status.Text = "Searching ... [{0}]" -f $script:rootLeaf
        $drainTimer.Start()
    }

    # --- drain the hit queue into the list; finalize when the walk is done ---
    $drainTimer = New-Object System.Windows.Forms.Timer
    $drainTimer.Interval = 100
    $drainTimer.Add_Tick({
        if (-not $script:searchState) { $drainTimer.Stop(); return }
        # Pull whatever's queued into a batch first, then touch the list only if
        # there's something to add -- an idle tick leaves the list alone, so it
        # doesn't repaint (and flicker) when no new hits arrived.
        $item  = $null
        $batch = [System.Collections.Generic.List[object]]::new()
        while ($batch.Count -lt 2000 -and $script:searchQueue.TryDequeue([ref]$item)) {
            $batch.Add($item)
        }
        if ($batch.Count -gt 0) {
            # Measure rows exactly as DrawItem paints them: 3px indent + timestamp
            # + path, using GDI+ MeasureString (same engine as DrawString) so the
            # scroll extent doesn't fall short and clip the last characters.
            $g = $list.CreateGraphics()
            $list.BeginUpdate()
            foreach ($it in $batch) {
                $script:hits.Add($it)
                [void]$list.Items.Add($it.P)
                $rowW = 3 + $g.MeasureString("$($it.T)  ", $list.Font).Width + $g.MeasureString($it.P, $list.Font).Width
                $rowW = [int][math]::Ceiling($rowW)
                if ($rowW -gt $script:maxExtent) { $script:maxExtent = $rowW }
            }
            $list.EndUpdate()
            $g.Dispose()
            if ($list.HorizontalExtent -lt $script:maxExtent) { $list.HorizontalExtent = $script:maxExtent + 12 }
        }

        $scanned = [int]$script:searchState.Scanned
        if ($script:searchState.Done -and $script:searchQueue.Count -eq 0 -and -not $script:finalized) {
            $script:finalized = $true
            $drainTimer.Stop()
            # Re-sort newest-first to match the console tool's final output.
            $sorted = @($script:hits | Sort-Object { $_.T } -Descending)
            $script:hits = [System.Collections.Generic.List[object]]::new()
            $list.BeginUpdate()
            $list.Items.Clear()
            foreach ($h in $sorted) { $script:hits.Add($h); [void]$list.Items.Add($h.P) }
            $list.EndUpdate()
            $list.HorizontalExtent = $script:maxExtent + 12
            if ($script:hits.Count -eq 0) {
                $status.Text = "No files matched  $($script:currentWild)   [{0}]" -f $script:rootLeaf
            } else {
                $status.Text = "{0} file(s)  --  {1:N0} scanned   [{2}]" -f $script:hits.Count, $scanned, $script:rootLeaf
            }
            try { $script:ps.EndInvoke($script:psHandle) } catch { }
            & $cleanupSearch
        } elseif (-not $script:finalized) {
            $status.Text = "Searching ... {0:N0} files, {1} match(es)   [{2}]" -f $scanned, $script:hits.Count, $script:rootLeaf
        }
    })

    # --- open the selected result with its default app ---
    $openSel = {
        $i = $list.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:hits.Count) { return }
        $p = $script:hits[$i].P
        try { Start-Process -FilePath $p } catch { & $tell "Couldn't open:`n$p`n`n$($_.Exception.Message)" 'Warning' }
    }

    # --- copy selected results (or all, if none selected) as time<tab>path ---
    $copySel = {
        if ($script:hits.Count -eq 0) { return }
        $idx = @($list.SelectedIndices)
        if ($idx.Count -eq 0) { $idx = 0..($script:hits.Count - 1) }
        $text = ($idx | ForEach-Object { "$($script:hits[$_].T)`t$($script:hits[$_].P)" }) -join "`r`n"
        Set-Clipboard -Value $text
        $status.Text = "Copied $($idx.Count) path(s) to clipboard"
    }

    # --- summon: capture the Explorer folder, reset, show, focus ---
    $summon = {
        # Capture the foreground window BEFORE we show ourselves and steal focus.
        $hwnd   = [SearchWin]::GetForegroundWindow()
        $folder = & $resolveExplorerFolder $hwnd
        if ($folder) { $rootBox.Text = $folder }
        elseif (-not $rootBox.Text.Trim()) { $rootBox.Text = $script:fallbackRoot }

        & $cleanupSearch
        $script:hits = [System.Collections.Generic.List[object]]::new()
        $list.Items.Clear()
        $script:maxExtent = 0
        $list.HorizontalExtent = 0
        $box.Clear()
        $leaf = Split-Path $rootBox.Text -Leaf
        if (-not $leaf) { $leaf = $rootBox.Text }
        $status.Text = "Ready -- type a pattern, Enter to search   [{0}]" -f $leaf

        $form.Show()
        $form.TopMost = $true
        $form.Activate()
        $box.Focus()
    }

    # --- hotkey parse/format (same as the sibling tools) ---
    $parseHotkey = {
        param($spec)
        if (-not $spec) { return $null }
        $mod = 0; $vk = 0
        foreach ($p in $spec.Split('+')) {
            $p = $p.Trim()
            $thisVk = 0
            switch ($p) {
                'ctrl'    { $mod = $mod -bor 2 }
                'control' { $mod = $mod -bor 2 }
                'alt'     { $mod = $mod -bor 1 }
                'shift'   { $mod = $mod -bor 4 }
                'win'     { $mod = $mod -bor 8 }
                'space'   { $thisVk = 0x20 }
                'tab'     { $thisVk = 0x09 }
                'escape'  { $thisVk = 0x1B }
                'esc'     { $thisVk = 0x1B }
                'enter'   { $thisVk = 0x0D }
                'return'  { $thisVk = 0x0D }
                default {
                    if     ($p -match '^[A-Za-z]$')           { $thisVk = [int][char]$p.ToUpper() }
                    elseif ($p -match '^[0-9]$')              { $thisVk = [int][char]$p }
                    elseif ($p -match '^[Ff]([1-9]|1[0-2])$') { $thisVk = 0x70 + [int]$Matches[1] - 1 }
                    else                                      { return $null }
                }
            }
            if ($thisVk -ne 0) {
                if ($vk -ne 0) { return $null }
                $vk = $thisVk
            }
        }
        if ($vk -eq 0) { return $null }
        return @{ Mod = $mod; Vk = $vk }
    }
    $formatHotkey = {
        param($mod, $vk)
        $out = ''
        if ($mod -band 2) { $out += 'Ctrl+' }
        if ($mod -band 1) { $out += 'Alt+' }
        if ($mod -band 4) { $out += 'Shift+' }
        if ($mod -band 8) { $out += 'Win+' }
        $key = switch ($vk) {
            0x20    { 'Space' }
            0x09    { 'Tab' }
            0x1B    { 'Escape' }
            0x0D    { 'Enter' }
            default {
                if     ($vk -ge 0x41 -and $vk -le 0x5A) { [string][char]$vk }
                elseif ($vk -ge 0x30 -and $vk -le 0x39) { [string][char]$vk }
                elseif ($vk -ge 0x70 -and $vk -le 0x7B) { "F$($vk - 0x6F)" }
                else                                    { "VK{0:X2}" -f $vk }
            }
        }
        $out + $key
    }

    # --- run a !command typed in the Find box ---
    $runCommand = {
        param($cmd)
        $box.Clear()
        $parts = $cmd.Trim() -split '\s+', 2
        $arg   = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
        switch ($parts[0].ToLower()) {
            '!hotkey' {
                if (-not $arg) { & $tell "Hotkey: $($script:hotkeyStr)"; return }
                $parsed = & $parseHotkey $arg
                if (-not $parsed) { & $tell "Couldn't parse: $arg" 'Warning'; return }
                $newStr = & $formatHotkey $parsed.Mod $parsed.Vk
                $form.ReleaseHotkey()
                if (-not $form.RegisterHotkey($parsed.Mod, $parsed.Vk)) {
                    $form.RegisterHotkey($script:hotkeyMod, $script:hotkeyVk) | Out-Null
                    & $tell "Couldn't claim: $newStr  (already taken)" 'Warning'
                    return
                }
                $script:hotkeyMod = $parsed.Mod
                $script:hotkeyVk  = $parsed.Vk
                $script:hotkeyStr = $newStr
                Set-ItemProperty -Path $rootKey -Name Hotkey -Value $newStr -Type String
                & $tell "Hotkey: $newStr"
            }
            '!quit' {
                & $cleanupSearch
                [System.Windows.Forms.Application]::Exit()
            }
            '!help' {
                # Open the online README (rendered) in the default browser.
                try {
                    Start-Process 'https://github.com/robertvigil/pwsh-search-files#readme'
                } catch {
                    & $tell "Couldn't open help:  $($_.Exception.Message)" 'Warning'
                }
            }
            '!demo' {
                # Maintainer helper (undocumented -- not in README/!help): fill the
                # pane with fake hits for a clean screenshot, no real search. A real
                # search or the next summon replaces it.
                & $cleanupSearch
                $script:hits = [System.Collections.Generic.List[object]]::new()
                $list.Items.Clear()
                $script:maxExtent = 0
                $list.HorizontalExtent = 0
                $rootBox.Text = 'S:\Projects'
                $script:rootLeaf = 'Projects'
                $script:currentWild = '*budget*'
                $now = Get-Date
                $demo = @(
                    [pscustomobject]@{ T = $now.AddMinutes(-8);  P = 'S:\Projects\Acme\2026\Q4-Budget-final.xlsx' }
                    [pscustomobject]@{ T = $now.AddMinutes(-52); P = 'S:\Projects\Acme\2026\Q4-Budget-draft.xlsx' }
                    [pscustomobject]@{ T = $now.AddHours(-3);    P = 'S:\Projects\Acme\2026\Q4-Budget-notes.docx' }
                    [pscustomobject]@{ T = $now.AddHours(-9);    P = 'S:\Projects\Acme\Reports\Weekly-Status-2026-07.docx' }
                    [pscustomobject]@{ T = $now.AddHours(-27);   P = 'S:\Projects\Acme\Reports\Monthly-Summary-June.pdf' }
                    [pscustomobject]@{ T = $now.AddDays(-2);     P = 'S:\Projects\Engineering\specs\api-design-v2.md' }
                    [pscustomobject]@{ T = $now.AddDays(-3);     P = 'S:\Projects\Engineering\specs\data-model.md' }
                    [pscustomobject]@{ T = $now.AddDays(-4);     P = 'S:\Projects\Engineering\src\Get-InventoryReport.ps1' }
                    [pscustomobject]@{ T = $now.AddDays(-5);     P = 'S:\Projects\Engineering\src\Sync-Warehouse.ps1' }
                    [pscustomobject]@{ T = $now.AddDays(-7);     P = 'S:\Projects\Engineering\tests\Get-InventoryReport.Tests.ps1' }
                    [pscustomobject]@{ T = $now.AddDays(-9);     P = 'S:\Projects\Design\diagrams\architecture-overview.png' }
                    [pscustomobject]@{ T = $now.AddDays(-12);    P = 'S:\Projects\Design\mockups\dashboard-v3.png' }
                    [pscustomobject]@{ T = $now.AddDays(-15);    P = 'S:\Projects\Marketing\deck\Launch-Deck.pptx' }
                    [pscustomobject]@{ T = $now.AddDays(-19);    P = 'S:\Projects\Acme\contracts\MSA-signed.pdf' }
                    [pscustomobject]@{ T = $now.AddDays(-23);    P = 'S:\Projects\Acme\2025\Q4-Budget-2025.xlsx' }
                    [pscustomobject]@{ T = $now.AddDays(-31);    P = 'S:\Projects\Engineering\build\release-notes.txt' }
                    [pscustomobject]@{ T = $now.AddDays(-40);    P = 'S:\Projects\Archive\2025\kickoff-meeting-notes.txt' }
                    [pscustomobject]@{ T = $now.AddDays(-58);    P = 'S:\Projects\Archive\2025\old-roadmap.xlsx' }
                )
                $demo = @($demo | Sort-Object { $_.T } -Descending)
                $g = $list.CreateGraphics()
                $list.BeginUpdate()
                foreach ($h in $demo) {
                    $script:hits.Add($h); [void]$list.Items.Add($h.P)
                    $rowW = 3 + $g.MeasureString("$($h.T)  ", $list.Font).Width + $g.MeasureString($h.P, $list.Font).Width
                    $rowW = [int][math]::Ceiling($rowW)
                    if ($rowW -gt $script:maxExtent) { $script:maxExtent = $rowW }
                }
                $list.EndUpdate()
                $g.Dispose()
                $list.HorizontalExtent = $script:maxExtent + 12
                $status.Text = "{0} file(s)  --  {1:N0} scanned   [{2}]" -f $script:hits.Count, 3847, $script:rootLeaf
            }
            default {
                & $tell "Unknown command  '$($parts[0])'  --  try  !help" 'Warning'
            }
        }
    }

    # Typing '!' text is a command hint; anything else is just the pattern (no
    # live search -- only Enter runs it, matching the console tool's ergonomics).
    $box.Add_TextChanged({
        if ($box.Text.StartsWith('!')) {
            $status.Text = 'Command mode -- Enter to run   (!help for commands)'
        }
    })
    # MouseDoubleClick + hit-test the row under the cursor (more reliable than the
    # plain DoubleClick event, which can fire before the click updates SelectedIndex).
    $list.Add_MouseDoubleClick({
        param($s, $e)
        $i = $list.IndexFromPoint($e.Location)
        if ($i -ge 0 -and $i -lt $script:hits.Count) { $list.SelectedIndex = $i; & $openSel }
    })

    $form.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Return') {
            if ($box.Focused -or $rootBox.Focused) {
                if ($box.Text.StartsWith('!')) { & $runCommand $box.Text } else { & $startSearch $box.Text }
            } elseif ($list.Focused) {
                & $openSel
            }
            $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Escape') {
            $form.Hide(); $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Down' -and $box.Focused) {
            if ($list.Items.Count -gt 0) { $list.Focus(); $list.SelectedIndex = 0 }
            $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'F5') {
            if ($script:lastPattern) { & $startSearch $script:lastPattern }
            $e.SuppressKeyPress = $true
        } elseif ($e.Control -and $e.KeyCode -eq 'C' -and $list.Focused) {
            & $copySel; $e.SuppressKeyPress = $true
        }
    })

    # X button hides instead of closing -- keeps the searcher loaded.
    $form.Add_FormClosing({
        param($s, $e)
        if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            $form.Hide()
        }
    })

    $form.Add_Hotkey({ & $summon })

    # Live clock -- ticks only while the searcher is visible.
    $clockTimer = New-Object System.Windows.Forms.Timer
    $clockTimer.Interval = 1000
    $clockTimer.Add_Tick({ $clock.Text = (Get-Date).ToString('h:mm:ss tt') })

    $form.Add_VisibleChanged({
        if ($form.Visible) {
            $clock.Text = (Get-Date).ToString('h:mm:ss tt')
            $clockTimer.Start()
        } else {
            $clockTimer.Stop()
            & $cleanupSearch   # stop any walk while hidden -- no wasted CPU off-screen
        }
    })

    # --- parse the saved hotkey (default Ctrl+Alt+F) and register it ---
    $savedHotkey = (Get-ItemProperty -Path $rootKey -Name Hotkey -ErrorAction SilentlyContinue).Hotkey
    if (-not $savedHotkey) { $savedHotkey = 'Ctrl+Alt+F' }
    $parsed = & $parseHotkey $savedHotkey
    if (-not $parsed) {
        $savedHotkey = 'Ctrl+Alt+F'
        $parsed = & $parseHotkey $savedHotkey
    }
    $script:hotkeyMod = $parsed.Mod
    $script:hotkeyVk  = $parsed.Vk
    $script:hotkeyStr = & $formatHotkey $parsed.Mod $parsed.Vk

    [void]$form.Handle
    if (-not $form.RegisterHotkey($script:hotkeyMod, $script:hotkeyVk)) {
        $msgOwner = New-Object System.Windows.Forms.Form
        $msgOwner.FormBorderStyle = 'None'
        $msgOwner.ShowInTaskbar   = $false
        $msgOwner.TopMost         = $true
        $msgOwner.StartPosition   = 'Manual'
        $msgOwner.Location        = New-Object System.Drawing.Point(-32000, -32000)
        $msgOwner.Size            = New-Object System.Drawing.Size(1, 1)
        $msgOwner.Show()
        [System.Windows.Forms.MessageBox]::Show($msgOwner,
            "Search-Files could not register $($script:hotkeyStr) -- another program or a leftover searcher already owns it. Close that one and start again.",
            'Search Files', 'OK', 'Warning') | Out-Null
        $msgOwner.Dispose()
        return
    }
    try { [System.Windows.Forms.Application]::Run() }
    finally {
        & $cleanupSearch
        if (-not $form.IsDisposed) { $form.ReleaseHotkey() }
    }
}

function Search-Files {
    [CmdletBinding()]
    param()
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Host "Search-Files needs PowerShell 7 -- this is Windows PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor Red
        Write-Host "Type  pwsh  to drop into PowerShell 7, then load and run again." -ForegroundColor Yellow
        return
    }
    # Same detached-launch pattern as the sibling tools: hand the GUI source via an
    # inherited env var; the child runs a tiny base64 loader. -STA is required for
    # WinForms + RegisterHotKey.
    $env:SearchFilesGuiSrc = $SearchFilesGui.ToString()
    $loader  = 'Invoke-Expression $env:SearchFilesGuiSrc'
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($loader))
    $pwshExe = (Get-Process -Id $PID).Path
    $proc    = Start-Process -FilePath $pwshExe -PassThru -WindowStyle Hidden `
                             -ArgumentList '-STA', '-NoProfile', '-EncodedCommand', $encoded
    Remove-Item Env:\SearchFilesGuiSrc -ErrorAction SilentlyContinue
    Write-Host "Search-Files running (PID $($proc.Id)) -- press Ctrl+Alt+F to summon it." -ForegroundColor Cyan
    Write-Host "Stop it with:  Stop-Process -Id $($proc.Id)" -ForegroundColor DarkGray
}
