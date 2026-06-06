# Pester 5+ tests for the $byteToChar converter embedded in the worker scriptblock of
# shells/nighthawk.ps1 (issue #76: protocol speaks UTF-8 byte offsets, .NET speaks
# UTF-16 char indices).
#
# The helper is extracted via AST rather than dot-sourcing the plugin, so none of the
# plugin's side effects (PSReadLine key handlers, runspace pool, debounce timer) run
# here. The converter is pure — all inputs arrive as params — which is what makes this
# extraction sound.
#
# Run: Invoke-Pester shells/tests
#
# Non-ASCII test characters are built from code points (not literals) so the tests are
# immune to file-encoding mishaps (e.g. Windows PowerShell 5.1 reading UTF-8-no-BOM as ANSI).

BeforeAll {
    $pluginPath = (Resolve-Path (Join-Path $PSScriptRoot '..\nighthawk.ps1')).Path
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($pluginPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "nighthawk.ps1 failed to parse: $($errors[0].Message)" }

    # $byteToChar lives inside the worker scriptblock — the $true flag (recurse into
    # nested scriptblocks) is mandatory.
    $node = $ast.Find({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$byteToChar' }, $true)
    if (-not $node) {
        throw "Could not find `$byteToChar assignment in nighthawk.ps1 — was it renamed?"
    }
    if ($node.Right -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
        $node.Right.Expression -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
        throw "`$byteToChar is no longer a literal scriptblock assignment — update this extraction."
    }
    $script:byteToChar = $node.Right.Expression.ScriptBlock.GetScriptBlock()

    # Same construction as the plugin's $state.utf8: no BOM, replacement fallback.
    $script:utf8 = [System.Text.UTF8Encoding]::new($false)

    $script:eAcute = [string][char]0xE9                  # é — 2 UTF-8 bytes, 1 UTF-16 char
    $script:cjk    = [string][char]0x4E2D                # 中 — 3 UTF-8 bytes, 1 UTF-16 char
    $script:emoji  = [char]::ConvertFromUtf32(0x1F600)   # 😀 — 4 UTF-8 bytes, 2 UTF-16 chars (surrogate pair)
}

Describe 'byteToChar' {

    Context 'ASCII (byte == char identity)' {
        It 'maps offset 0 to 0' {
            & $byteToChar 'git checkout' 0 $utf8 | Should -Be 0
        }
        It 'maps a mid-string offset identically' {
            & $byteToChar 'git checkout' 4 $utf8 | Should -Be 4
        }
        It 'maps offset == byte length to string length (EOL boundary)' {
            & $byteToChar 'git checkout' 12 $utf8 | Should -Be 12
        }
    }

    Context '2-byte sequence (e-acute)' {
        It 'shifts char index below byte index past the multibyte char' {
            # "echo café build": é occupies bytes 8-9, so the space after it is byte 10 -> char 9
            $s = "echo caf$eAcute build"
            & $byteToChar $s 10 $utf8 | Should -Be 9
        }
        It 'rejects an offset landing mid-sequence' {
            $s = "echo caf$eAcute build"
            & $byteToChar $s 9 $utf8 | Should -Be -1
        }
        It 'maps offset == total bytes on a multibyte string to char length (EOL boundary — the dominant accept path; > vs >= here breaks every end-of-line suggestion)' {
            # "café" = 5 bytes, 4 chars
            & $byteToChar "caf$eAcute" 5 $utf8 | Should -Be 4
        }
    }

    Context '3-byte sequence (CJK)' {
        It 'maps the boundary after one CJK char' {
            # "中文x" = 3+3+1 bytes, 3 chars
            & $byteToChar "$cjk${cjk}x" 3 $utf8 | Should -Be 1
        }
        It 'maps the boundary after two CJK chars' {
            & $byteToChar "$cjk${cjk}x" 6 $utf8 | Should -Be 2
        }
        It 'rejects offsets inside a 3-byte sequence' {
            & $byteToChar "$cjk${cjk}x" 1 $utf8 | Should -Be -1
            & $byteToChar "$cjk${cjk}x" 2 $utf8 | Should -Be -1
        }
    }

    Context '4-byte sequence (emoji, surrogate pair)' {
        It 'maps the boundary after an emoji to char index 2 (one code point, two UTF-16 chars)' {
            # "😀x" = 4+1 bytes, 3 chars
            & $byteToChar "${emoji}x" 4 $utf8 | Should -Be 2
        }
        It 'rejects offsets inside the 4-byte sequence' {
            foreach ($b in 1..3) {
                & $byteToChar "${emoji}x" $b $utf8 | Should -Be -1
            }
        }
    }

    Context 'bounds and degenerate inputs' {
        It 'rejects an offset past the end' {
            & $byteToChar 'abc' 4 $utf8 | Should -Be -1
        }
        It 'rejects a negative offset' {
            & $byteToChar 'abc' -1 $utf8 | Should -Be -1
        }
        It 'maps offset 0 on an empty string to 0' {
            & $byteToChar '' 0 $utf8 | Should -Be 0
        }
        It 'rejects a positive offset on an empty string' {
            & $byteToChar '' 1 $utf8 | Should -Be -1
        }
    }

    Context 'zero-width replace range (pure insertion)' {
        It 'converts start == end to a valid equal char pair (callers use strict < guards, which must keep allowing equality)' {
            $start = & $byteToChar "caf$eAcute" 5 $utf8
            $end = & $byteToChar "caf$eAcute" 5 $utf8
            $start | Should -Be 4
            $end | Should -Be $start
        }
    }

    Context 'round-trip across both conversion directions' {
        It 'byteToChar(GetByteCount(prefix)) recovers every char boundary of a mixed-width string' {
            # "a中😀é": char boundaries 0,1,2,4,5 — index 3 is inside the surrogate pair
            $s = "a$cjk$emoji$eAcute"
            foreach ($i in @(0, 1, 2, 4, 5)) {
                $b = $utf8.GetByteCount($s.Substring(0, $i))
                & $byteToChar $s $b $utf8 | Should -Be $i
            }
        }
        It 'rejects the byte offset pointing inside the surrogate pair''s 4-byte sequence' {
            $s = "a$cjk$emoji$eAcute"
            # bytes: a=1, 中=3, 😀=4 (bytes 4-7), é=2 -> offsets 5,6,7 are mid-emoji
            foreach ($b in 5..7) {
                & $byteToChar $s $b $utf8 | Should -Be -1
            }
        }
    }
}
