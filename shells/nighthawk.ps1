# nighthawk PowerShell plugin — inline ghost text autocomplete
#
# Install: add to $PROFILE:  . ~/.config/nighthawk/nighthawk.ps1
# Requires: PSReadLine 2.0+ (ships with PowerShell 5.1+)

# --- Initialization ---
$script:_nh_esc = [char]27
# Disable PSReadLine's built-in prediction to avoid overlap with nighthawk ghost text
try { Set-PSReadLineOption -PredictionSource None } catch {}

# --- Configuration ---
# Load plugin settings from config.toml [plugin] section (simple regex parse).
# Env vars override config file values.
function _nh_load_plugin_config {
    $settings = @{
        debounce_ms = 200
        hint_arrow = '->'
        debug = $false
    }
    $configPath = Join-Path $env:APPDATA "nighthawk\config.toml"
    if (Test-Path $configPath) {
        try {
            $content = Get-Content $configPath -Raw -ErrorAction Stop
            if ($content -match '(?ms)^\[plugin\]\s*(.*?)(?=^\[|\z)') {
                $section = $matches[1]
                if ($section -match '(?m)^\s*debounce_ms\s*=\s*(\d+)') {
                    $settings.debounce_ms = [int]$matches[1]
                }
                if ($section -match '(?m)^\s*hint_arrow\s*=\s*"([^"]*)"') {
                    $settings.hint_arrow = $matches[1]
                }
                if ($section -match '(?m)^\s*debug\s*=\s*(true|false)') {
                    $settings.debug = ($matches[1] -eq 'true')
                }
            }
        } catch {}
    }
    return $settings
}

$script:_nh_config = _nh_load_plugin_config
$script:_nh_hint_arrow = if ($env:NIGHTHAWK_HINT_ARROW) { $env:NIGHTHAWK_HINT_ARROW } else { $script:_nh_config.hint_arrow }
$script:_nh_debounce_ms = if ($env:NIGHTHAWK_DEBOUNCE_MS) { [int]$env:NIGHTHAWK_DEBOUNCE_MS } else { $script:_nh_config.debounce_ms }
$script:_nh_debug = if ($env:NIGHTHAWK_DEBUG) { $env:NIGHTHAWK_DEBUG -eq '1' } else { $script:_nh_config.debug }
$script:_nh_log_path = Join-Path $env:APPDATA "nighthawk\plugin.log"

# --- Diagnostic logging (only when debug enabled) ---
# Thread-safe via append; can be called from foreground or background.
function _nh_log {
    param([string]$msg)
    if (-not $script:_nh_debug) { return }
    try {
        $ts = (Get-Date).ToString('HH:mm:ss.fff')
        $tid = [System.Threading.Thread]::CurrentThread.ManagedThreadId
        Add-Content -Path $script:_nh_log_path -Value "$ts t$tid $msg" -ErrorAction SilentlyContinue
    } catch {}
}

# --- Synchronized shared state (accessed across threads) ---
# Foreground reads/writes via $script:_nh_state.X
# Background timer Action reads/writes via $Event.MessageData.X (same hashtable instance)
$script:_nh_state = [hashtable]::Synchronized(@{
    pipe_name      = 'nighthawk'
    debounce_ms    = $script:_nh_debounce_ms
    hint_arrow     = $script:_nh_hint_arrow
    debug          = $script:_nh_debug
    log_path       = $script:_nh_log_path
    esc            = [char]27
    # Per-keystroke captured state
    pending_buffer = ''
    pending_cursor = 0
    generation     = 0
    # Currently-displayed ghost suggestion (read by accept handler)
    suggestion     = ''
    replace_start  = -1
    replace_end    = -1
    ghost_len      = 0
})

# --- Ghost text rendering via ANSI ---
# Uses [Console]::Write so it's safe to call from any thread.
function _nh_render_ghost([string]$ghost) {
    if ($ghost.Length -eq 0) { return }
    $e = $script:_nh_esc
    $clean = $ghost -replace '"', ''
    $script:_nh_state.ghost_len = $clean.Length
    [System.Console]::Write("${e}[s${e}[90m${clean}${e}[0m${e}[u")
}

function _nh_clear_ghost {
    if ($script:_nh_state.ghost_len -gt 0) {
        $e = $script:_nh_esc
        [System.Console]::Write("${e}[s${e}[0J${e}[u")
        $script:_nh_state.ghost_len = 0
    }
    $script:_nh_state.suggestion = ''
    $script:_nh_state.replace_start = -1
    $script:_nh_state.replace_end = -1
}

# --- Auto-start ---
$script:_nh_tried_start = $false
$script:_nh_backoff_until = [DateTime]::MinValue
function _nh_ensure_daemon {
    if ($script:_nh_tried_start) { return }
    $script:_nh_tried_start = $true
    $nhCmd = Get-Command nh -ErrorAction SilentlyContinue
    if ($nhCmd) {
        Start-Process nh -ArgumentList 'start' -WindowStyle Hidden
    }
}

# --- Debounce timer + ROE event subscriber ---
# Register-ObjectEvent runs the -Action in PowerShell's event-handler runspace.
# That runspace cannot see this script's functions or $script: vars, so:
#   - State is shared via -MessageData (synchronized hashtable, by reference)
#   - Daemon IPC + render logic is INLINED in the Action block
#   - All ANSI output goes through [Console]::Write (thread-safe)
$script:_nh_timer = [System.Timers.Timer]::new()
$script:_nh_timer.AutoReset = $false
$script:_nh_timer.Interval = $script:_nh_debounce_ms

# Cleanup any previous registration if plugin is re-sourced
Get-EventSubscriber -SourceIdentifier 'nh_debounce' -ErrorAction SilentlyContinue | Unregister-Event -ErrorAction SilentlyContinue

$null = Register-ObjectEvent -InputObject $script:_nh_timer -EventName Elapsed `
    -SourceIdentifier 'nh_debounce' -MessageData $script:_nh_state -Action {
    $state = $Event.MessageData

    # Inline diagnostic log (can't call _nh_log from this runspace)
    $writeLog = {
        param([string]$m)
        if (-not $state.debug) { return }
        try {
            $ts = (Get-Date).ToString('HH:mm:ss.fff')
            $tid = [System.Threading.Thread]::CurrentThread.ManagedThreadId
            Add-Content -Path $state.log_path -Value "$ts t$tid [bg] $m" -ErrorAction SilentlyContinue
        } catch {}
    }

    & $writeLog "Elapsed fired (gen=$($state.generation), buf='$($state.pending_buffer)')"

    try {
        $myGen = $state.generation
        $line = $state.pending_buffer
        $cursor = $state.pending_cursor

        if (-not $line -or $line.Length -lt 2) {
            & $writeLog "skip: empty/short buffer"
            return
        }

        $pipePath = "\\.\pipe\$($state.pipe_name)"
        if (-not (Test-Path $pipePath)) {
            & $writeLog "skip: pipe missing at $pipePath"
            return
        }

        # Build JSON request (escape Windows backslashes, quotes, newlines)
        $esc_input = $line -replace '\\','\\' -replace '"','\"' -replace "`n",'\n' -replace "`r",'\r'
        $esc_cwd = $PWD.Path -replace '\\','\\' -replace '"','\"'
        $json = "{`"input`":`"$esc_input`",`"cursor`":$cursor,`"cwd`":`"$esc_cwd`",`"shell`":`"powershell`"}"

        & $writeLog "sending request len=$($line.Length)"

        # Synchronous IPC — daemon enforces tier budgets so this is bounded
        $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $state.pipe_name, [System.IO.Pipes.PipeDirection]::InOut)
        $response = $null
        try {
            $pipe.Connect(50)
            $utf8 = [System.Text.UTF8Encoding]::new($false)
            $writer = [System.IO.StreamWriter]::new($pipe, $utf8)
            $writer.AutoFlush = $true
            $writer.WriteLine($json)
            $reader = [System.IO.StreamReader]::new($pipe, $utf8)
            $response = $reader.ReadLine()
        } finally {
            $pipe.Dispose()
        }

        if (-not $response) {
            & $writeLog "empty response"
            return
        }

        # Staleness check — abort if user typed during the daemon call
        if ($state.generation -ne $myGen) {
            & $writeLog "stale (gen advanced $myGen -> $($state.generation))"
            return
        }

        # Parse response
        $parsed = $null
        try { $parsed = $response | ConvertFrom-Json } catch {
            & $writeLog "parse fail: $($_.Exception.Message)"
            return
        }
        if (-not $parsed.suggestions -or $parsed.suggestions.Count -eq 0) {
            & $writeLog "no suggestions"
            return
        }

        $s = $parsed.suggestions[0]
        $state.suggestion = $s.text
        $state.replace_start = [int]$s.replace_start
        $state.replace_end = [int]$s.replace_end

        # Compute ghost text
        $ghost = $null
        if ($s.PSObject.Properties['diff_ops'] -and $null -ne $s.diff_ops) {
            $ghost = " $($state.hint_arrow) $($s.text)"
        } else {
            $typed_len = $cursor - [int]$s.replace_start
            if ($typed_len -ge 0 -and $typed_len -lt $s.text.Length) {
                $typed_part = $line.Substring([int]$s.replace_start, $typed_len)
                if ($s.text.StartsWith($typed_part, [System.StringComparison]::Ordinal)) {
                    $ghost = $s.text.Substring($typed_len)
                } else {
                    $ghost = " $($state.hint_arrow) $($s.text)"
                }
            }
        }

        if (-not $ghost) {
            & $writeLog "no ghost computed"
            return
        }

        $clean = $ghost -replace '"', ''
        $state.ghost_len = $clean.Length

        # Render via [Console]::Write — thread-safe, bypasses runspace $Host
        $e = $state.esc
        [System.Console]::Write("${e}[s${e}[90m${clean}${e}[0m${e}[u")
        & $writeLog "rendered ghost (len=$($clean.Length))"
    } catch {
        & $writeLog "EXCEPTION: $($_.Exception.Message)"
    }
}

# --- Schedule debounced query ---
function _nh_query {
    $line = ''; $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

    _nh_log "_nh_query: line='$line' cursor=$cursor"

    if ($cursor -ne $line.Length -or $line.Length -lt 2) { return }

    if ([DateTime]::UtcNow -lt $script:_nh_backoff_until) {
        _nh_log "_nh_query: in backoff window"
        return
    }

    if (-not (Test-Path "\\.\pipe\$($script:_nh_state.pipe_name)")) {
        _nh_log "_nh_query: pipe missing, setting backoff"
        $script:_nh_backoff_until = [DateTime]::UtcNow.AddSeconds(5)
        if (-not $script:_nh_tried_start) { _nh_ensure_daemon }
        return
    }

    # Capture state for the timer Elapsed callback
    $script:_nh_state.pending_buffer = $line
    $script:_nh_state.pending_cursor = $cursor
    $script:_nh_state.generation++

    # Reset debounce window
    $script:_nh_timer.Stop()
    $script:_nh_timer.Start()

    _nh_log "_nh_query: timer reset (gen=$($script:_nh_state.generation))"
}

# --- Accept suggestion ---
function _nh_accept {
    if ($script:_nh_state.suggestion -and $script:_nh_state.replace_start -ge 0) {
        $text = $script:_nh_state.suggestion
        $start = $script:_nh_state.replace_start
        $end = $script:_nh_state.replace_end
        _nh_clear_ghost
        $len = $end - $start
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace($start, $len, $text)
    }
}

# --- Key bindings ---

$_nh_insert_handler = {
    param($key, $arg)
    if ($key.Modifiers -band [System.ConsoleModifiers]::Control -or
        $key.Modifiers -band [System.ConsoleModifiers]::Alt) {
        [Microsoft.PowerShell.PSConsoleReadLine]::SelfInsert($key, $arg)
        return
    }
    _nh_clear_ghost
    [Microsoft.PowerShell.PSConsoleReadLine]::SelfInsert($key, $arg)
    _nh_query
}

$_nh_bind_chars = @()
$_nh_bind_chars += 97..122  | ForEach-Object { [string][char]$_ }
$_nh_bind_chars += 65..90   | ForEach-Object { [string][char]$_ }
$_nh_bind_chars += 48..57   | ForEach-Object { [string][char]$_ }
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

Set-PSReadLineKeyHandler -Chord 'Ctrl+Backspace' -ScriptBlock {
    param($key, $arg)
    _nh_clear_ghost
    [Microsoft.PowerShell.PSConsoleReadLine]::BackwardKillWord($key, $arg)
    _nh_query
}

Set-PSReadLineKeyHandler -Chord 'Tab' -ScriptBlock {
    param($key, $arg)
    if ($script:_nh_state.suggestion) {
        _nh_accept
    } else {
        [Microsoft.PowerShell.PSConsoleReadLine]::TabCompleteNext($key, $arg)
    }
}

Set-PSReadLineKeyHandler -Chord 'RightArrow' -ScriptBlock {
    param($key, $arg)
    $line = ''; $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    if ($script:_nh_state.suggestion -and $cursor -eq $line.Length) {
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
    if ($script:_nh_state.ghost_len -gt 0) {
        _nh_clear_ghost
    } else {
        [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine($key, $arg)
    }
}

_nh_log "plugin loaded (debounce_ms=$($script:_nh_debounce_ms), debug=$($script:_nh_debug))"
