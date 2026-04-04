# nighthawk PowerShell plugin — inline ghost text autocomplete
#
# Install: add to $PROFILE:  . ~/.config/nighthawk/nighthawk.ps1
# Requires: PSReadLine 2.0+ (ships with PowerShell 5.1+)

# --- Initialization ---
$script:_nh_esc = [char]27
# Disable PSReadLine's built-in prediction to avoid overlap with nighthawk ghost text
try { Set-PSReadLineOption -PredictionSource None } catch {}

# --- Configuration ---
$script:_nh_hint_arrow = if ($env:NIGHTHAWK_HINT_ARROW) { $env:NIGHTHAWK_HINT_ARROW } else { '->' }

# --- State ---
$script:_nh_pipe = 'nighthawk'
$script:_nh_suggestion = ''
$script:_nh_replace_start = -1
$script:_nh_replace_end = -1
$script:_nh_ghost_len = 0
$script:_nh_last_buffer = ''
$script:_nh_tried_start = $false
$script:_nh_backoff_until = [DateTime]::MinValue

# --- Ghost text rendering via ANSI ---
function _nh_render_ghost([string]$ghost) {
    if ($ghost.Length -eq 0) { return }
    $e = $script:_nh_esc
    $script:_nh_ghost_len = $ghost.Length
    # Save cursor, gray text, reset color, restore cursor
    # Strip double quotes — Windows Terminal renders them as "" inside ANSI regions
    $clean = $ghost -replace '"', ''
    $script:_nh_ghost_len = $clean.Length
    $Host.UI.Write("${e}[s${e}[90m")
    $Host.UI.Write($clean)
    $Host.UI.Write("${e}[0m${e}[u")
}

function _nh_clear_ghost {
    if ($script:_nh_ghost_len -gt 0) {
        $e = $script:_nh_esc
        # Save cursor, clear to end of line, restore cursor
        $Host.UI.Write("${e}[s${e}[0K${e}[u")
        $script:_nh_ghost_len = 0
    }
    $script:_nh_suggestion = ''
    $script:_nh_replace_start = -1
    $script:_nh_replace_end = -1
}

# --- Auto-start ---
function _nh_ensure_daemon {
    if ($script:_nh_tried_start) { return }
    $script:_nh_tried_start = $true
    $nhCmd = Get-Command nh -ErrorAction SilentlyContinue
    if ($nhCmd) { & nh start >$null 2>$null }
}

# --- Daemon communication ---
function _nh_query {
    $line = ''; $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

    # Only suggest when cursor is at end and buffer has content
    if ($cursor -ne $line.Length -or $line.Length -lt 2) { return }
    if ($line -eq $script:_nh_last_buffer) { return }

    # Backoff: skip queries for 5s after connection failure
    if ([DateTime]::UtcNow -lt $script:_nh_backoff_until) { return }

    $script:_nh_last_buffer = $line

    try {
        # Escape for JSON (critical for Windows paths: C:\Users → C:\\Users)
        $esc_input = $line -replace '\\','\\' -replace '"','\"' -replace "`n",'\n' -replace "`r",'\r'
        $esc_cwd = $PWD.Path -replace '\\','\\' -replace '"','\"'
        $json = "{`"input`":`"$esc_input`",`"cursor`":$cursor,`"cwd`":`"$esc_cwd`",`"shell`":`"powershell`"}"

        $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $script:_nh_pipe, [System.IO.Pipes.PipeDirection]::InOut)
        try {
            $pipe.Connect(20)

            $utf8 = [System.Text.UTF8Encoding]::new($false)  # UTF-8 without BOM
            $writer = [System.IO.StreamWriter]::new($pipe, $utf8)
            $writer.AutoFlush = $true
            $writer.WriteLine($json)

            $reader = [System.IO.StreamReader]::new($pipe, $utf8)
            $readTask = $reader.ReadLineAsync()
            if (-not $readTask.Wait(100)) { return }
            $response = $readTask.Result
        } finally {
            $pipe.Dispose()
        }

        if (-not $response) { return }
        $parsed = $response | ConvertFrom-Json
        if (-not $parsed.suggestions -or $parsed.suggestions.Count -eq 0) { return }

        $s = $parsed.suggestions[0]
        $script:_nh_suggestion = $s.text
        $script:_nh_replace_start = [int]$s.replace_start
        $script:_nh_replace_end = [int]$s.replace_end

        if ($s.PSObject.Properties['diff_ops'] -and $null -ne $s.diff_ops) {
            # Fuzzy match: render as hint " → suggestion"
            _nh_render_ghost " $($script:_nh_hint_arrow) $($s.text)"
        } else {
            $typed_len = $cursor - $script:_nh_replace_start
            if ($typed_len -ge 0 -and $typed_len -lt $s.text.Length) {
                $typed_part = $line.Substring($script:_nh_replace_start, $typed_len)
                if ($s.text.StartsWith($typed_part, [System.StringComparison]::Ordinal)) {
                    # True prefix match: show suffix as ghost text
                    _nh_render_ghost $s.text.Substring($typed_len)
                } else {
                    # Replacement changes typed text: show hint instead
                    _nh_render_ghost " $($script:_nh_hint_arrow) $($s.text)"
                }
            }
        }
    }
    catch {
        # Back off for 5s so failed connections don't block typing
        $script:_nh_backoff_until = [DateTime]::UtcNow.AddSeconds(5)
        # Try starting the daemon once
        if (-not $script:_nh_tried_start) { _nh_ensure_daemon }
    }
}

# --- Accept suggestion ---
function _nh_accept {
    if ($script:_nh_suggestion -and $script:_nh_replace_start -ge 0) {
        # Save state before _nh_clear_ghost wipes it
        $text = $script:_nh_suggestion
        $start = $script:_nh_replace_start
        $end = $script:_nh_replace_end
        _nh_clear_ghost
        $len = $end - $start
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace($start, $len, $text)
        $script:_nh_last_buffer = ''
    }
}

# --- Key bindings ---

# Handler for printable character input
$_nh_insert_handler = {
    param($key, $arg)
    _nh_clear_ghost
    [Microsoft.PowerShell.PSConsoleReadLine]::SelfInsert($key, $arg)
    _nh_query
}

# Bind common command-line characters (PS 5.1 compat: use int ranges, not char ranges)
$_nh_bind_chars = @()
$_nh_bind_chars += 97..122  | ForEach-Object { [string][char]$_ }   # a-z
$_nh_bind_chars += 65..90   | ForEach-Object { [string][char]$_ }   # A-Z
$_nh_bind_chars += 48..57   | ForEach-Object { [string][char]$_ }   # 0-9
$_nh_bind_chars += @('-','_','.','/','\',':','~','=','+','@','#','$','%','^','&','*',',',';','!','|','Spacebar')

foreach ($c in $_nh_bind_chars) {
    Set-PSReadLineKeyHandler -Chord $c -ScriptBlock $_nh_insert_handler
}

Set-PSReadLineKeyHandler -Chord 'Backspace' -ScriptBlock {
    param($key, $arg)
    _nh_clear_ghost
    [Microsoft.PowerShell.PSConsoleReadLine]::BackwardDeleteChar($key, $arg)
    _nh_query
}

Set-PSReadLineKeyHandler -Chord 'Tab' -ScriptBlock {
    param($key, $arg)
    if ($script:_nh_suggestion) {
        _nh_accept
    } else {
        [Microsoft.PowerShell.PSConsoleReadLine]::TabCompleteNext($key, $arg)
    }
}

Set-PSReadLineKeyHandler -Chord 'RightArrow' -ScriptBlock {
    param($key, $arg)
    $line = ''; $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    if ($script:_nh_suggestion -and $cursor -eq $line.Length) {
        _nh_accept
    } else {
        [Microsoft.PowerShell.PSConsoleReadLine]::ForwardChar($key, $arg)
    }
}

Set-PSReadLineKeyHandler -Chord 'Enter' -ScriptBlock {
    param($key, $arg)
    _nh_clear_ghost
    [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine($key, $arg)
}

Set-PSReadLineKeyHandler -Chord 'Escape' -ScriptBlock {
    param($key, $arg)
    if ($script:_nh_ghost_len -gt 0) {
        _nh_clear_ghost
    } else {
        [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine($key, $arg)
    }
}
