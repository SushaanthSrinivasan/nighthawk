# nighthawk PowerShell plugin — inline ghost text autocomplete
#
# Install: add to $PROFILE:  . ~/.config/nighthawk/nighthawk.ps1
# Requires: PSReadLine 2.0+ (ships with PowerShell 5.1+)

# --- Initialization ---
$script:_nh_esc = [char]27
# Disable PSReadLine's built-in prediction to avoid overlap with nighthawk ghost text
try { Set-PSReadLineOption -PredictionSource None } catch {}

# --- Configuration ---
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

# --- Diagnostic logging (foreground) ---
function _nh_log {
    param([string]$msg)
    if (-not $script:_nh_debug) { return }
    try {
        $ts = (Get-Date).ToString('HH:mm:ss.fff')
        $tid = [System.Threading.Thread]::CurrentThread.ManagedThreadId
        Add-Content -Path $script:_nh_log_path -Value "$ts t$tid $msg" -ErrorAction SilentlyContinue
    } catch {}
}

# --- Synchronized shared state ---
# Foreground writes pending_* fields; runspace-pool worker reads pending_* and writes `published`.
# `published` is a hashtable reference — assignment is a single pointer write, never torn —
# so foreground readers can snapshot once and use snap['text']/['start']/['end'] safely.
$script:_nh_state = [hashtable]::Synchronized(@{
    pipe_name       = 'nighthawk'
    hint_arrow      = $script:_nh_hint_arrow
    debug           = $script:_nh_debug
    log_path        = $script:_nh_log_path
    esc             = [char]27
    utf8            = [System.Text.UTF8Encoding]::new($false)
    read_timeout_ms = 2250
    pending_buffer  = ''
    pending_cursor  = 0
    pending_cwd     = ''
    generation      = 0
    published       = $null   # @{ text=...; start=...; end=... } or $null
    ghost_len       = 0
    inflight        = [System.Collections.Generic.List[object]]::new()
})

# --- Ghost text clear ---
# Bumps generation so any in-flight worker sees its result as stale, AND stops the
# debounce timer so a pending dispatch (scheduled before the user moved on) doesn't
# fire with stale pending_buffer/cursor and render a phantom ghost. The next _nh_query
# call (from the very next keystroke) will Start() the timer again — this only kills
# dispatches the user has invalidated by typing/Enter/Escape/Tab.
function _nh_clear_ghost {
    if ($script:_nh_timer) { try { $script:_nh_timer.Stop() } catch {} }
    $script:_nh_state.generation++
    if ($script:_nh_state.ghost_len -gt 0) {
        $e = $script:_nh_esc
        [System.Console]::Write("${e}[s${e}[0J${e}[u")
        $script:_nh_state.ghost_len = 0
    }
    $script:_nh_state.published = $null
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

# --- Background worker scriptblock ---
# Runs on a RunspacePool worker (invoked via [PowerShell]::Create().BeginInvoke()).
# Receives only the synchronized $state hashtable — no other foreground vars are visible.
# All output goes through [Console]::Write and a single atomic $state.published assignment.
$script:_nh_worker = {
    param([hashtable]$state)

    # JSON escape: \\, \", \b, \f, \n, \r, \t, plus \uXXXX for any other 0x00-0x1F control chars.
    # Invariant: chars >= 0x20 MUST pass through RAW, never as \uXXXX — the daemon's byte
    # offsets over `input` only agree with our GetByteCount because both sides see
    # identical UTF-8 on the wire.
    $jsonEscape = {
        param([string]$s)
        if ([string]::IsNullOrEmpty($s)) { return '' }
        $sb = [System.Text.StringBuilder]::new($s.Length + 8)
        foreach ($ch in $s.ToCharArray()) {
            $code = [int]$ch
            switch ($ch) {
                '\'  { [void]$sb.Append('\\') }
                '"'  { [void]$sb.Append('\"') }
                "`b" { [void]$sb.Append('\b') }
                "`f" { [void]$sb.Append('\f') }
                "`n" { [void]$sb.Append('\n') }
                "`r" { [void]$sb.Append('\r') }
                "`t" { [void]$sb.Append('\t') }
                default {
                    if ($code -lt 0x20) {
                        [void]$sb.AppendFormat('\u{0:x4}', $code)
                    } else {
                        [void]$sb.Append($ch)
                    }
                }
            }
        }
        return $sb.ToString()
    }

    # Maps a UTF-8 byte offset (protocol domain) to a UTF-16 char index (.NET domain).
    # Only this plugin needs conversion: the protocol and the zsh plugin are byte-native,
    # but .NET string APIs (Substring, PSReadLine Replace) index by UTF-16 chars. Must be
    # applied against the exact $line snapshot sent in the request — the round-trip check
    # below is only valid for that string. Returns -1 for out-of-range or mid-code-point
    # offsets (fail-closed, like the control-char rejection below). $utf8 MUST be the
    # replacement-fallback encoder ($state.utf8) — a throwOnInvalidBytes instance would
    # turn lone-surrogate buffers into worker-killing exceptions.
    $byteToChar = {
        param([string]$s, [int]$byteOffset, [System.Text.UTF8Encoding]$utf8)
        if ($byteOffset -lt 0) { return -1 }
        if ($byteOffset -eq 0) { return 0 }
        $bytes = $utf8.GetBytes($s)
        if ($byteOffset -gt $bytes.Length) { return -1 }
        # Surrogate-pair aware and never throws (replacement fallback).
        $chars = $utf8.GetCharCount($bytes, 0, $byteOffset)
        # Can't fire on well-formed input; turns a would-be Substring throw into a clean reject.
        if ($chars -gt $s.Length) { return -1 }
        # A char index landing on a low surrogate splits an emoji's UTF-16 pair — and the
        # round-trip below can false-pass on exactly that case: an offset 1 byte into a
        # 4-byte sequence decodes to 1 replacement char, and the truncated prefix's lone
        # high surrogate re-encodes to '?' (1 byte), coincidentally matching. Reject directly.
        if ($chars -lt $s.Length -and [char]::IsLowSurrogate($s[$chars])) { return -1 }
        # LOAD-BEARING: GetCharCount silently rounds a mid-code-point offset to a
        # replacement char; re-encoding the prefix exposes the length mismatch. Together
        # with the surrogate check above this is the mid-sequence rejection — do not
        # remove either as "redundant".
        if ($utf8.GetByteCount($s.Substring(0, $chars)) -ne $byteOffset) { return -1 }
        return $chars
    }

    # Worker-side log. $force=$true bypasses debug-gate so fatal exceptions always leave a trace.
    $writeLog = {
        param([string]$m, [bool]$force = $false)
        if (-not $force -and -not $state.debug) { return }
        try {
            $ts = (Get-Date).ToString('HH:mm:ss.fff')
            $tid = [System.Threading.Thread]::CurrentThread.ManagedThreadId
            [System.IO.File]::AppendAllText($state.log_path, "$ts t$tid [bg] $m`r`n")
        } catch {}
    }

    try {
        $myGen = $state.generation
        $line = $state.pending_buffer
        $cursor = $state.pending_cursor
        $cwd = $state.pending_cwd

        if (-not $line -or $line.Length -lt 2) { return }

        # Torn pending_* snapshot (pending_buffer/pending_cursor are written non-atomically
        # by a racing keystroke): the pair is garbage — drop the request rather than clamp;
        # the generation check would discard the response anyway.
        if ($cursor -lt 0 -or $cursor -gt $line.Length) { return }

        # The protocol speaks UTF-8 byte offsets, but PSReadLine's cursor is a UTF-16 char
        # index — convert for the request only; $cursor itself stays char-domain for the
        # ghost math below. If the buffer ends in a lone surrogate, GetByteCount counts a
        # substituted '?' (matching what the UTF-8 StreamWriter puts on the wire, so the
        # daemon sees consistent input); reply offsets that don't line up then fail the
        # byteToChar checks and we fail closed (no ghost), never corrupting the buffer.
        $utf8 = $state.utf8
        $cursor_bytes = $utf8.GetByteCount($line.Substring(0, $cursor))

        $esc_input = & $jsonEscape $line
        $esc_cwd = & $jsonEscape $cwd
        $json = '{"input":"' + $esc_input + '","cursor":' + $cursor_bytes + ',"cwd":"' + $esc_cwd + '","shell":"powershell"}'

        & $writeLog "sending request len=$($line.Length)"

        # Synchronous IPC bounded by daemon's tier budget (cloud=2000ms) + 250ms slack.
        $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $state.pipe_name, [System.IO.Pipes.PipeDirection]::InOut)
        $reader = $null
        $writer = $null
        $response = $null
        try {
            $pipe.Connect(50)
            $writer = [System.IO.StreamWriter]::new($pipe, $utf8)
            $writer.AutoFlush = $true
            $writer.WriteLine($json)
            $reader = [System.IO.StreamReader]::new($pipe, $utf8)

            # Bounded async read — if daemon hangs we don't hang the worker forever.
            $task = $reader.ReadLineAsync()
            if ($task.Wait($state.read_timeout_ms)) {
                $response = $task.Result
            } else {
                & $writeLog "read timeout $($state.read_timeout_ms)ms"
                # Observe the orphan task to suppress post-dispose UnobservedTaskException.
                $null = $task.ContinueWith(
                    { param($t) $null = $t.Exception },
                    [System.Threading.Tasks.TaskContinuationOptions]::OnlyOnFaulted)
                return
            }
        } finally {
            if ($reader) { try { $reader.Dispose() } catch {} }
            if ($writer) { try { $writer.Dispose() } catch {} }
            try { $pipe.Dispose() } catch {}
        }

        if (-not $response) { return }
        if ($state.generation -ne $myGen) {
            & $writeLog "stale (gen advanced)"
            return
        }

        # Parse with ConvertFrom-Json (works on PS 5.1 + PS 7+). Returns PSCustomObjects.
        $parsed = $null
        try {
            $parsed = $response | ConvertFrom-Json -ErrorAction Stop
        } catch {
            & $writeLog "parse fail: $($_.Exception.Message)"
            return
        }

        if (-not $parsed -or -not $parsed.suggestions -or $parsed.suggestions.Count -eq 0) { return }

        $s = $parsed.suggestions[0]
        if (-not $s.text -or $null -eq $s.replace_start -or $null -eq $s.replace_end) {
            & $writeLog "malformed suggestion"
            return
        }

        # Reject the suggestion outright if it contains any control char (<0x20 or 0x7f).
        # A response containing ESC (OSC 52 clipboard, DECSET, OSC 8 hyperlink, cursor
        # moves) hijacks the terminal during render; a newline (0x0a) auto-submits on
        # accept, which is a single-keystroke RCE if the model emits `rm -rf $HOME\n`.
        # Fail-closed (reject) over fail-open (strip): stripping concatenates around
        # dropped chars (`ls\x00rm` -> `lsrm`), silently merging tokens. Shell commands
        # never legitimately contain control chars, so reject has zero false-positive cost.
        $text = [string]$s.text
        foreach ($_nh_ch in $text.ToCharArray()) {
            $_nh_ch_code = [int]$_nh_ch
            if ($_nh_ch_code -lt 0x20 -or $_nh_ch_code -eq 0x7f) {
                & $writeLog "rejected: suggestion contains control char 0x$('{0:x2}' -f $_nh_ch_code)"
                return
            }
        }
        if (-not $text) { return }

        # Protocol byte offsets -> .NET char indices, converted against $line (the exact
        # buffer snapshot sent in the request). Must happen BEFORE the diff_ops branch:
        # both branches publish these values and _nh_accept feeds them to PSReadLine
        # Replace(), which is char-indexed. The inverted-range check stays here (not just
        # in _nh_accept): publishing an inverted range would render a ghost that accept
        # bails on before _nh_clear_ghost, leaving it stuck on screen.
        $rstart_bytes = [int]$s.replace_start
        $rend_bytes = [int]$s.replace_end
        $rstart = & $byteToChar $line $rstart_bytes $utf8
        $rend = & $byteToChar $line $rend_bytes $utf8
        if ($rstart -lt 0 -or $rend -lt 0 -or $rend -lt $rstart) {
            & $writeLog "rejected: replace range bytes [$rstart_bytes,$rend_bytes) not on code-point boundary"
            return
        }

        $ghost = $null
        if ($s.PSObject.Properties['diff_ops'] -and $null -ne $s.diff_ops) {
            $ghost = " $($state.hint_arrow) $text"
        } else {
            $typed_len = $cursor - $rstart
            if ($typed_len -ge 0 -and $typed_len -lt $text.Length -and ($rstart + $typed_len) -le $line.Length) {
                $typed_part = $line.Substring($rstart, $typed_len)
                if ($text.StartsWith($typed_part, [System.StringComparison]::Ordinal)) {
                    $ghost = $text.Substring($typed_len)
                } else {
                    $ghost = " $($state.hint_arrow) $text"
                }
            }
        }

        if (-not $ghost) { return }

        # Final staleness check before publishing — user may have typed during parse.
        if ($state.generation -ne $myGen) { return }

        $state.ghost_len = $ghost.Length
        $e = $state.esc
        [System.Console]::Write("${e}[s${e}[90m${ghost}${e}[0m${e}[u")
        $state.published = @{
            text  = $text
            start = $rstart
            end   = $rend
        }
        # Post-publish fence: if foreground bumped generation between our staleness check
        # and the assignment above, our publish + console-write are both stale. Undo BOTH
        # state and display: null published (so Tab can't insert a phantom) AND emit the
        # clear sequence (so a stale ghost doesn't linger on screen). The display undo is
        # required when foreground's racing partner was _nh_query (typing) rather than
        # _nh_clear_ghost — _nh_query advances generation but does NOT clear the screen,
        # so without this, multi-line wrapped ghosts would linger until Enter. Idempotent:
        # if _nh_clear_ghost already ran, the extra clear is a no-op.
        if ($state.generation -ne $myGen) {
            [System.Console]::Write("${e}[s${e}[0J${e}[u")
            $state.published = $null
            $state.ghost_len = 0
            return
        }
        & $writeLog "rendered ghost (len=$($ghost.Length))"
    } catch {
        # Unconditional — fatal worker exceptions always log, even with debug=false.
        & $writeLog "bg-FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)" $true
    }
}

# --- Re-source cleanup: tear down prior subscriber, timer, pool before recreating ---
# Order matters: unregister the subscriber first (so a late Elapsed can't dispatch into
# a closing pool), then stop+dispose the timer, then close+dispose the pool.
Get-EventSubscriber -SourceIdentifier 'nh_debounce' -ErrorAction SilentlyContinue | Unregister-Event -ErrorAction SilentlyContinue
if ($script:_nh_timer) {
    try { $script:_nh_timer.Stop(); $script:_nh_timer.Dispose() } catch {}
}
if ($script:_nh_runspacepool) {
    try { $script:_nh_runspacepool.Close(); $script:_nh_runspacepool.Dispose() } catch {}
}

# --- Runspace pool for background IPC workers ---
# Pool size (1, 3): one worker covers the steady-state debounce; up to 3 lets overlapping
# bursts run concurrently without blocking the event-handler runspace.
# CRITICAL: workers MUST run on a RunspacePool, not a raw [System.Threading.Thread]. PowerShell
# scriptblocks need a Runspace in TLS to execute; without one, ScriptBlock.GetContextFromTLS()
# throws and the unhandled exception fast-fails the entire pwsh process (CLR 0xE0434352).
$script:_nh_runspacepool = [runspacefactory]::CreateRunspacePool(1, 3)
$script:_nh_runspacepool.Open()

# --- Debounce timer + ROE event subscriber ---
$script:_nh_timer = [System.Timers.Timer]::new()
$script:_nh_timer.AutoReset = $false
$script:_nh_timer.Interval = $script:_nh_debounce_ms

# Pre-serialize the worker scriptblock body — [PowerShell]::AddScript takes a string,
# so we'd otherwise pay a ToString() per keystroke.
$script:_nh_worker_text = $script:_nh_worker.ToString()

$null = Register-ObjectEvent -InputObject $script:_nh_timer -EventName Elapsed `
    -SourceIdentifier 'nh_debounce' -MessageData @{
        state       = $script:_nh_state
        worker_text = $script:_nh_worker_text
        pool        = $script:_nh_runspacepool
    } -Action {
    $data = $Event.MessageData
    $state = $data.state

    try {
        # Prune completed instances. EndInvoke on a completed IAsyncResult releases its
        # kernel ManualResetEvent; Dispose releases the PowerShell instance. Skip
        # incomplete slots so this stays O(pool size) and never blocks.
        $inflight = $state.inflight
        for ($i = $inflight.Count - 1; $i -ge 0; $i--) {
            if ($inflight[$i].iar.IsCompleted) {
                $slot = $inflight[$i]
                try { $null = $slot.ps.EndInvoke($slot.iar) } catch {}
                try { $slot.ps.Dispose() } catch {}
                $inflight.RemoveAt($i)
            }
        }

        # Dispatch to a pooled runspace. BeginInvoke returns immediately — the event-handler
        # runspace (pumped on the main pipeline thread) is freed before the IPC happens.
        # If AddScript/BeginInvoke throws (e.g., pool closing during reload), the created
        # [PowerShell] instance would leak — dispose it unless ownership transferred to
        # $inflight. Set $ps = $null after Add so finally only disposes orphans.
        $ps = [PowerShell]::Create()
        try {
            $ps.RunspacePool = $data.pool
            $null = $ps.AddScript($data.worker_text).AddArgument($state)
            $iar = $ps.BeginInvoke()
            $inflight.Add(@{ ps = $ps; iar = $iar })
            $ps = $null
        } finally {
            if ($ps) { try { $ps.Dispose() } catch {} }
        }
    } catch {
        if ($state.debug) {
            try {
                $ts = (Get-Date).ToString('HH:mm:ss.fff')
                Add-Content -Path $state.log_path -Value "$ts [evt] dispatch fail: $($_.Exception.Message)" -ErrorAction SilentlyContinue
            } catch {}
        }
    }
}

# --- Schedule debounced query ---
function _nh_query {
    $line = ''; $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

    _nh_log "_nh_query: line='$line' cursor=$cursor"

    if ($cursor -ne $line.Length -or $line.Length -lt 2) { return }

    if ([DateTime]::UtcNow -lt $script:_nh_backoff_until) { return }

    if (-not (Test-Path "\\.\pipe\$($script:_nh_state.pipe_name)")) {
        _nh_log "_nh_query: pipe missing, setting backoff"
        $script:_nh_backoff_until = [DateTime]::UtcNow.AddSeconds(5)
        if (-not $script:_nh_tried_start) { _nh_ensure_daemon }
        return
    }

    # Capture state for the worker. $PWD must be captured here in the foreground runspace —
    # workers don't have the user's current directory.
    $script:_nh_state.pending_buffer = $line
    $script:_nh_state.pending_cursor = $cursor
    $script:_nh_state.pending_cwd = $PWD.Path
    $script:_nh_state.generation++

    $script:_nh_timer.Stop()
    $script:_nh_timer.Start()

    _nh_log "_nh_query: timer reset (gen=$($script:_nh_state.generation))"
}

# --- Accept suggestion ---
# Snapshots $state.published once so a worker publishing mid-accept can't tear our read.
function _nh_accept {
    $script:_nh_state.generation++
    $snap = $script:_nh_state.published
    if ($snap -and [int]$snap['start'] -ge 0) {
        $text = [string]$snap['text']
        $start = [int]$snap['start']
        $end = [int]$snap['end']
        # Buffer may have shrunk since the worker captured the suggestion; re-read it so
        # PSReadLine.Replace doesn't throw ArgumentOutOfRangeException on a stale end.
        # Also defend against malformed ranges (start past end-of-buffer, inverted range)
        # in case a future tier returns bad values.
        $current = ''; $cur = 0
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$current, [ref]$cur)
        if ($end -lt 0 -or $end -gt $current.Length -or $start -gt $current.Length -or $end -lt $start) { return }
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
    if ($script:_nh_state.published) {
        _nh_accept
    } else {
        [Microsoft.PowerShell.PSConsoleReadLine]::TabCompleteNext($key, $arg)
    }
}

Set-PSReadLineKeyHandler -Chord 'RightArrow' -ScriptBlock {
    param($key, $arg)
    $line = ''; $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    if ($script:_nh_state.published -and $cursor -eq $line.Length) {
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
