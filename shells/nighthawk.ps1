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
        timeout_ms = 100
        hint_arrow = '->'
    }
    $configPath = Join-Path $env:APPDATA "nighthawk\config.toml"
    if (Test-Path $configPath) {
        try {
            $content = Get-Content $configPath -Raw -ErrorAction Stop
            # Extract [plugin] section only (until next section or EOF)
            if ($content -match '(?ms)^\[plugin\]\s*(.*?)(?=^\[|\z)') {
                $section = $matches[1]
                if ($section -match '(?m)^\s*timeout_ms\s*=\s*(\d+)') {
                    $settings.timeout_ms = [int]$matches[1]
                }
                if ($section -match '(?m)^\s*hint_arrow\s*=\s*"([^"]*)"') {
                    $settings.hint_arrow = $matches[1]
                }
            }
        } catch {
            # Silently ignore config read errors — use defaults
        }
    }
    return $settings
}

$script:_nh_config = _nh_load_plugin_config
$script:_nh_hint_arrow = if ($env:NIGHTHAWK_HINT_ARROW) { $env:NIGHTHAWK_HINT_ARROW } else { $script:_nh_config.hint_arrow }
$script:_nh_timeout_ms = if ($env:NIGHTHAWK_TIMEOUT_MS) { [int]$env:NIGHTHAWK_TIMEOUT_MS } else { $script:_nh_config.timeout_ms }

# --- State ---
$script:_nh_pipe = 'nighthawk'
$script:_nh_suggestion = ''
$script:_nh_replace_start = -1
$script:_nh_replace_end = -1
$script:_nh_ghost_len = 0
$script:_nh_last_buffer = ''
$script:_nh_tried_start = $false
$script:_nh_backoff_until = [DateTime]::MinValue

# Async pending query state (for cloud-tier slow responses)
$script:_nh_pending_pipe = $null
$script:_nh_pending_task = $null
$script:_nh_pending_buffer = ''
$script:_nh_pending_cursor = 0
$script:_nh_last_query_at = [DateTime]::MinValue
# Minimum ms between queries (throttle to prevent hammering daemon while typing)
$script:_nh_throttle_ms = 150
# How long to wait synchronously for response (fast tiers respond quickly)
$script:_nh_quick_wait_ms = [Math]::Min($script:_nh_timeout_ms, 150)

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
        # Save cursor, clear to end of screen (handles wrapped multi-line ghost text), restore cursor
        $Host.UI.Write("${e}[s${e}[0J${e}[u")
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
    if ($nhCmd) {
        # Start asynchronously — nh start calls tasklist which blocks 1-3s on Windows.
        # Must not block the PSReadLine key handler or input freezes.
        Start-Process nh -ArgumentList 'start' -WindowStyle Hidden
    }
}

# --- Render a response (shared between sync and async paths) ---
function _nh_render_response {
    param([string]$response, [string]$line, [int]$cursor)
    if (-not $response) { return }
    try {
        $parsed = $response | ConvertFrom-Json
    } catch { return }
    if (-not $parsed.suggestions -or $parsed.suggestions.Count -eq 0) { return }

    $s = $parsed.suggestions[0]
    $script:_nh_suggestion = $s.text
    $script:_nh_replace_start = [int]$s.replace_start
    $script:_nh_replace_end = [int]$s.replace_end

    if ($s.PSObject.Properties['diff_ops'] -and $null -ne $s.diff_ops) {
        _nh_render_ghost " $($script:_nh_hint_arrow) $($s.text)"
    } else {
        $typed_len = $cursor - $script:_nh_replace_start
        if ($typed_len -ge 0 -and $typed_len -lt $s.text.Length) {
            $typed_part = $line.Substring($script:_nh_replace_start, $typed_len)
            if ($s.text.StartsWith($typed_part, [System.StringComparison]::Ordinal)) {
                _nh_render_ghost $s.text.Substring($typed_len)
            } else {
                _nh_render_ghost " $($script:_nh_hint_arrow) $($s.text)"
            }
        }
    }
}

# --- Check if a previous async query completed ---
function _nh_check_pending {
    if (-not $script:_nh_pending_task) { return }
    if (-not $script:_nh_pending_task.IsCompleted) { return }

    try {
        $response = $script:_nh_pending_task.Result

        # Get current buffer - only render if it still matches what we queried for
        $cur_line = ''; $cur_cursor = 0
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$cur_line, [ref]$cur_cursor)
        if ($cur_line -eq $script:_nh_pending_buffer -and $cur_cursor -eq $cur_line.Length) {
            _nh_render_response $response $cur_line $cur_cursor
        }
    } catch {}

    _nh_cleanup_pending
}

function _nh_cleanup_pending {
    if ($script:_nh_pending_pipe) {
        try { $script:_nh_pending_pipe.Dispose() } catch {}
    }
    $script:_nh_pending_pipe = $null
    $script:_nh_pending_task = $null
    $script:_nh_pending_buffer = ''
    $script:_nh_pending_cursor = 0
}

# --- Daemon communication ---
function _nh_query {
    # First: check if a previous async query completed (may render ghost text)
    _nh_check_pending

    $line = ''; $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

    # Only suggest when cursor is at end and buffer has content
    if ($cursor -ne $line.Length -or $line.Length -lt 2) { return }
    if ($line -eq $script:_nh_last_buffer) { return }

    # Throttle: skip if we queried too recently (prevents hammering daemon while typing)
    $elapsed = ([DateTime]::UtcNow - $script:_nh_last_query_at).TotalMilliseconds
    if ($elapsed -lt $script:_nh_throttle_ms) { return }

    # Backoff: skip queries for 5s after connection failure
    if ([DateTime]::UtcNow -lt $script:_nh_backoff_until) { return }

    # Fast check: bail if the named pipe doesn't exist.
    if (-not (Test-Path "\\.\pipe\$($script:_nh_pipe)")) {
        $script:_nh_backoff_until = [DateTime]::UtcNow.AddSeconds(5)
        if (-not $script:_nh_tried_start) { _nh_ensure_daemon }
        return
    }

    $script:_nh_last_buffer = $line
    $script:_nh_last_query_at = [DateTime]::UtcNow

    # Cancel any in-progress query (user typed again, previous is stale)
    _nh_cleanup_pending

    try {
        # Escape for JSON (critical for Windows paths: C:\Users → C:\\Users)
        $esc_input = $line -replace '\\','\\' -replace '"','\"' -replace "`n",'\n' -replace "`r",'\r'
        $esc_cwd = $PWD.Path -replace '\\','\\' -replace '"','\"'
        $json = "{`"input`":`"$esc_input`",`"cursor`":$cursor,`"cwd`":`"$esc_cwd`",`"shell`":`"powershell`"}"

        $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $script:_nh_pipe, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(20)

        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $writer = [System.IO.StreamWriter]::new($pipe, $utf8)
        $writer.AutoFlush = $true
        $writer.WriteLine($json)

        $reader = [System.IO.StreamReader]::new($pipe, $utf8)
        $readTask = $reader.ReadLineAsync()

        # Quick sync wait - fast tiers (history, specs) respond in <50ms
        if ($readTask.Wait($script:_nh_quick_wait_ms)) {
            # Fast response - render immediately
            $response = $readTask.Result
            $pipe.Dispose()
            _nh_render_response $response $line $cursor
        } else {
            # Slow response (cloud tier) - store task, check on next keystroke
            $script:_nh_pending_pipe = $pipe
            $script:_nh_pending_task = $readTask
            $script:_nh_pending_buffer = $line
            $script:_nh_pending_cursor = $cursor
        }
    }
    catch {
        $script:_nh_backoff_until = [DateTime]::UtcNow.AddSeconds(5)
        _nh_cleanup_pending
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
    # Pass through immediately when Ctrl/Alt modifiers are held.
    # Prevents blocking during control sequences which can interfere with
    # Windows Console modifier key tracking on some systems (issue #58).
    if ($key.Modifiers -band [System.ConsoleModifiers]::Control -or
        $key.Modifiers -band [System.ConsoleModifiers]::Alt) {
        [Microsoft.PowerShell.PSConsoleReadLine]::SelfInsert($key, $arg)
        return
    }
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

Set-PSReadLineKeyHandler -Chord 'Ctrl+Backspace' -ScriptBlock {
    param($key, $arg)
    _nh_clear_ghost
    [Microsoft.PowerShell.PSConsoleReadLine]::BackwardKillWord($key, $arg)
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
