use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Protocol version for forward compatibility.
pub const PROTOCOL_VERSION: u32 = 1;

// --- Shell ---

/// Which shell the request originates from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Shell {
    Zsh,
    Bash,
    Fish,
    #[serde(alias = "pwsh")]
    PowerShell,
    #[serde(alias = "nu")]
    Nushell,
}

impl std::str::FromStr for Shell {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        // Strip version suffix (handles "bash-5.2" from $SHELL)
        let lower = s.to_lowercase();
        let base = lower.split('-').next().unwrap_or(&lower);
        match base {
            "zsh" => Ok(Shell::Zsh),
            "bash" | "sh" => Ok(Shell::Bash),
            "fish" => Ok(Shell::Fish),
            "powershell" | "pwsh" => Ok(Shell::PowerShell),
            "nushell" | "nu" => Ok(Shell::Nushell),
            _ => Err(format!("unknown shell: {s}")),
        }
    }
}

impl Shell {
    pub fn as_str(&self) -> &'static str {
        match self {
            Shell::Zsh => "zsh",
            Shell::Bash => "bash",
            Shell::Fish => "fish",
            Shell::PowerShell => "powershell",
            Shell::Nushell => "nushell",
        }
    }

    pub fn index(&self) -> usize {
        match self {
            Shell::Zsh => 0,
            Shell::Bash => 1,
            Shell::Fish => 2,
            Shell::PowerShell => 3,
            Shell::Nushell => 4,
        }
    }

    /// Detect default shell from env vars + platform.
    ///
    /// Priority:
    /// 1. `NIGHTHAWK_SHELL` env var (explicit override, all platforms)
    /// 2. Parent process name via `/proc` (Linux/macOS only)
    /// 3. Shell version env vars like `ZSH_VERSION` (Unix only, rarely exported)
    /// 4. `$SHELL` env var (Unix only, login shell - may differ from current)
    /// 5. Platform default: PowerShell on Windows, Zsh on Unix
    ///
    /// Note: On Windows, only `NIGHTHAWK_SHELL` override works reliably.
    /// The hint will always suggest PowerShell unless overridden.
    pub fn detect_default() -> Self {
        Self::detect_from(
            std::env::var("NIGHTHAWK_SHELL").ok(),
            std::env::var("ZSH_VERSION").ok(),
            std::env::var("BASH_VERSION").ok(),
            std::env::var("FISH_VERSION").ok(),
            std::env::var("NU_VERSION").ok(),
            std::env::var("SHELL").ok(),
        )
    }

    /// Pure detection function for testability — takes env values as parameters.
    ///
    /// Priority:
    /// 1. `NIGHTHAWK_SHELL` override (explicit user choice)
    /// 2. Shell version env vars: `ZSH_VERSION`, `BASH_VERSION`, `FISH_VERSION`, `NU_VERSION`
    ///    (set by the current shell, not inherited — detects actual running shell)
    /// 3. `$SHELL` fallback (login shell — may differ from current interactive shell)
    /// 4. Platform default (PowerShell on Windows, Zsh on Unix)
    pub fn detect_from(
        nighthawk_shell: Option<String>,
        zsh_version: Option<String>,
        bash_version: Option<String>,
        fish_version: Option<String>,
        nu_version: Option<String>,
        shell_env: Option<String>,
    ) -> Self {
        // 1. Explicit override (highest priority)
        if let Some(shell) = detect_from_override(&nighthawk_shell) {
            return shell;
        }

        // 2. Parent process name (most reliable on Linux)
        #[cfg(not(windows))]
        if let Some(shell) = detect_from_parent_process() {
            return shell;
        }

        // 3. Shell-specific version env vars (current shell detection) — Unix only
        //    Note: These are shell-internal vars, not always exported to children.
        //    Kept as fallback in case user exports them.
        #[cfg(not(windows))]
        if let Some(shell) =
            detect_from_version_vars(&zsh_version, &bash_version, &fish_version, &nu_version)
        {
            return shell;
        }

        // Suppress unused warnings on Windows where version vars aren't checked
        #[cfg(windows)]
        {
            let _ = (&zsh_version, &bash_version, &fish_version, &nu_version);
        }

        // 4. $SHELL fallback (login shell) — Unix only
        #[cfg(not(windows))]
        if let Some(shell) = detect_from_shell_env(&shell_env) {
            return shell;
        }

        #[cfg(windows)]
        {
            let _ = &shell_env;
        }

        // 5. Platform default
        #[cfg(windows)]
        {
            Shell::PowerShell
        }
        #[cfg(not(windows))]
        {
            Shell::Zsh
        }
    }
}

/// Detect shell from NIGHTHAWK_SHELL env var (explicit override).
fn detect_from_override(nighthawk_shell: &Option<String>) -> Option<Shell> {
    let trimmed = nighthawk_shell.as_ref()?.trim();
    if trimmed.is_empty() {
        return None;
    }
    trimmed.parse::<Shell>().ok()
}

/// Detect shell from parent process name (Linux/macOS).
/// Reads `/proc/$PPID/comm` on Linux or uses `ps` on macOS.
#[cfg(not(windows))]
fn detect_from_parent_process() -> Option<Shell> {
    let ppid = std::os::unix::process::parent_id();

    // Try /proc filesystem first (Linux)
    if let Ok(comm) = std::fs::read_to_string(format!("/proc/{}/comm", ppid)) {
        let name = comm.trim();
        tracing::trace!("Parent process name from /proc: {}", name);
        if let Ok(shell) = name.parse::<Shell>() {
            return Some(shell);
        }
    }

    // Fall back to ps command (macOS, or if /proc unavailable)
    if let Ok(output) = std::process::Command::new("ps")
        .args(["-p", &ppid.to_string(), "-o", "comm="])
        .output()
    {
        if output.status.success() {
            let comm = String::from_utf8_lossy(&output.stdout);
            // ps output may include full path, extract basename
            let name = comm.trim().rsplit('/').next().unwrap_or("");
            tracing::trace!("Parent process name from ps: {}", name);
            if let Ok(shell) = name.parse::<Shell>() {
                return Some(shell);
            }
        }
    }

    None
}

/// Detect shell from version env vars (ZSH_VERSION, BASH_VERSION, etc.).
/// Priority: zsh > bash > fish > nushell (first match wins).
/// Note: Only used on Unix — version vars are never set on Windows.
#[cfg(not(windows))]
fn detect_from_version_vars(
    zsh_version: &Option<String>,
    bash_version: &Option<String>,
    fish_version: &Option<String>,
    nu_version: &Option<String>,
) -> Option<Shell> {
    // Note: Version vars can be inherited from parent shells in nested scenarios.
    // We check in order of commonality. User can override with NIGHTHAWK_SHELL.
    if zsh_version.is_some() {
        tracing::trace!("Detected ZSH_VERSION, using zsh");
        return Some(Shell::Zsh);
    }
    if bash_version.is_some() {
        tracing::trace!("Detected BASH_VERSION, using bash");
        return Some(Shell::Bash);
    }
    if fish_version.is_some() {
        tracing::trace!("Detected FISH_VERSION, using fish");
        return Some(Shell::Fish);
    }
    if nu_version.is_some() {
        tracing::trace!("Detected NU_VERSION, using nushell");
        return Some(Shell::Nushell);
    }
    None
}

/// Detect shell from $SHELL env var (login shell fallback).
/// Note: Only used on Unix — Windows uses platform default.
#[cfg(not(windows))]
fn detect_from_shell_env(shell_env: &Option<String>) -> Option<Shell> {
    shell_env
        .as_deref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .and_then(|s| s.rsplit('/').next())
        .filter(|name| !name.is_empty())
        .and_then(|name| name.parse::<Shell>().ok())
}

// --- Request / Response ---

/// Sent by shell plugin to daemon on each keystroke (debounced).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompletionRequest {
    /// The full current input buffer contents.
    pub input: String,

    /// Cursor position (byte offset) within `input`.
    pub cursor: usize,

    /// Current working directory.
    pub cwd: PathBuf,

    /// Which shell is asking.
    pub shell: Shell,
}

/// Sent by daemon back to shell plugin.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompletionResponse {
    /// Ordered suggestions (best first). Shell plugin typically
    /// renders only the first one as ghost text.
    pub suggestions: Vec<Suggestion>,
}

// --- Suggestion ---

/// A single completion suggestion.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Suggestion {
    /// The text to insert. For full-token replacement, this is the
    /// complete replacement (e.g. "claude" when user typed "ccla").
    pub text: String,

    /// Byte offset in the original input where replacement starts.
    pub replace_start: usize,

    /// Byte offset in the original input where replacement ends.
    pub replace_end: usize,

    /// Confidence score 0.0..=1.0. Drives ghost text brightness
    /// and tier escalation decisions.
    pub confidence: f32,

    /// Which prediction tier produced this.
    pub source: SuggestionSource,

    /// Optional description (e.g. "Switch branches" for `git checkout`).
    pub description: Option<String>,

    /// Character-level diff ops for inline diff rendering of fuzzy matches.
    /// None for prefix matches (use normal ghost text). Some for fuzzy matches.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diff_ops: Option<Vec<DiffOp>>,
}

/// A single character-level diff operation for inline rendering.
///
/// Fuzzy matches produce a sequence of these ops describing how the
/// typed text differs from the corrected text. The shell plugin uses
/// them to render strikethrough (Delete), gray ghost (Insert), and
/// normal (Keep) characters inline.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "op", content = "ch")]
pub enum DiffOp {
    /// Character matches — render in normal color.
    Keep(char),
    /// Character should be removed — render as strikethrough red.
    Delete(char),
    /// Character should be inserted — render as gray ghost text.
    Insert(char),
}

/// Which prediction tier produced a suggestion.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SuggestionSource {
    /// Tier 0: matched from shell history.
    History,
    /// Tier 1: matched from a CLI spec (withfig or --help parsed).
    Spec,
    /// Tier 2: generated by a local LLM.
    LocalModel,
    /// Tier 3: generated by a cloud API.
    CloudModel,
}

// --- Socket paths ---

/// Default socket path for the daemon.
pub fn default_socket_path() -> PathBuf {
    #[cfg(unix)]
    {
        let uid = unsafe { libc::getuid() };
        PathBuf::from(format!("/tmp/nighthawk-{}.sock", uid))
    }
    #[cfg(windows)]
    {
        PathBuf::from(r"\\.\pipe\nighthawk")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_roundtrip_json() {
        let req = CompletionRequest {
            input: "git ch".into(),
            cursor: 6,
            cwd: PathBuf::from("/home/user/project"),
            shell: Shell::Zsh,
        };
        let json = serde_json::to_string(&req).unwrap();
        let parsed: CompletionRequest = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.input, "git ch");
        assert_eq!(parsed.cursor, 6);
        assert_eq!(parsed.shell, Shell::Zsh);
    }

    #[test]
    fn response_roundtrip_json() {
        let resp = CompletionResponse {
            suggestions: vec![Suggestion {
                text: "checkout".into(),
                replace_start: 4,
                replace_end: 6,
                confidence: 0.95,
                source: SuggestionSource::Spec,
                description: Some("Switch branches or restore files".into()),
                diff_ops: None,
            }],
        };
        let json = serde_json::to_string(&resp).unwrap();
        let parsed: CompletionResponse = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.suggestions.len(), 1);
        assert_eq!(parsed.suggestions[0].text, "checkout");
        assert_eq!(parsed.suggestions[0].replace_start, 4);
    }

    #[test]
    fn shell_serde() {
        let s = Shell::PowerShell;
        let json = serde_json::to_string(&s).unwrap();
        assert_eq!(json, "\"powershell\"");
        let parsed: Shell = serde_json::from_str("\"pwsh\"").unwrap();
        assert_eq!(parsed, Shell::PowerShell);
    }

    #[test]
    fn diff_op_roundtrip() {
        let ops = vec![
            DiffOp::Keep('c'),
            DiffOp::Delete('a'),
            DiffOp::Insert('e'),
            DiffOp::Keep('k'),
        ];
        let json = serde_json::to_string(&ops).unwrap();
        let parsed: Vec<DiffOp> = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, ops);
    }

    #[test]
    fn suggestion_with_diff_ops() {
        let suggestion = Suggestion {
            text: "checkout".into(),
            replace_start: 4,
            replace_end: 12,
            confidence: 0.7,
            source: SuggestionSource::Spec,
            description: None,
            diff_ops: Some(vec![DiffOp::Keep('c'), DiffOp::Insert('h')]),
        };
        let json = serde_json::to_string(&suggestion).unwrap();
        assert!(json.contains("diff_ops"));
        let parsed: Suggestion = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.diff_ops.unwrap().len(), 2);
    }

    #[test]
    fn suggestion_without_diff_ops_backward_compat() {
        // Old JSON without diff_ops field should deserialize with None
        let json = r#"{"text":"checkout","replace_start":4,"replace_end":6,"confidence":0.9,"source":"spec","description":null}"#;
        let parsed: Suggestion = serde_json::from_str(json).unwrap();
        assert!(parsed.diff_ops.is_none());
    }

    #[test]
    fn powershell_request_with_windows_path() {
        // Simulates the JSON the PowerShell plugin sends (backslashes escaped)
        let json = r#"{"input":"cd C:\\Users\\iamsu","cursor":18,"cwd":"D:\\projects\\nighthawk","shell":"powershell"}"#;
        let parsed: CompletionRequest = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.input, r"cd C:\Users\iamsu");
        assert_eq!(parsed.cursor, 18);
        assert_eq!(parsed.cwd, PathBuf::from(r"D:\projects\nighthawk"));
        assert_eq!(parsed.shell, Shell::PowerShell);
    }

    #[test]
    fn powershell_request_with_quotes_in_input() {
        // Input containing escaped double quotes
        let json = r#"{"input":"echo \"hello world\"","cursor":20,"cwd":"C:\\","shell":"pwsh"}"#;
        let parsed: CompletionRequest = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.input, r#"echo "hello world""#);
        assert_eq!(parsed.shell, Shell::PowerShell); // pwsh alias
    }

    #[test]
    fn powershell_request_unc_path() {
        let json = r#"{"input":"dir","cursor":3,"cwd":"\\\\server\\share","shell":"powershell"}"#;
        let parsed: CompletionRequest = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.cwd, PathBuf::from(r"\\server\share"));
    }

    #[test]
    fn suggestion_none_diff_ops_omitted_in_json() {
        // diff_ops: None should not appear in serialized JSON (skip_serializing_if)
        let suggestion = Suggestion {
            text: "checkout".into(),
            replace_start: 4,
            replace_end: 6,
            confidence: 0.9,
            source: SuggestionSource::Spec,
            description: None,
            diff_ops: None,
        };
        let json = serde_json::to_string(&suggestion).unwrap();
        assert!(
            !json.contains("diff_ops"),
            "None diff_ops should be omitted: {}",
            json
        );
    }

    // --- Shell detection tests ---

    #[test]
    fn shell_from_str_basics() {
        assert_eq!("zsh".parse::<Shell>().unwrap(), Shell::Zsh);
        assert_eq!("bash".parse::<Shell>().unwrap(), Shell::Bash);
        assert_eq!("fish".parse::<Shell>().unwrap(), Shell::Fish);
        assert_eq!("powershell".parse::<Shell>().unwrap(), Shell::PowerShell);
        assert_eq!("pwsh".parse::<Shell>().unwrap(), Shell::PowerShell);
        assert_eq!("nushell".parse::<Shell>().unwrap(), Shell::Nushell);
        assert_eq!("nu".parse::<Shell>().unwrap(), Shell::Nushell);
        assert_eq!("sh".parse::<Shell>().unwrap(), Shell::Bash);
    }

    #[test]
    fn shell_from_str_case_insensitive() {
        assert_eq!("ZSH".parse::<Shell>().unwrap(), Shell::Zsh);
        assert_eq!("PowerShell".parse::<Shell>().unwrap(), Shell::PowerShell);
        assert_eq!("BASH".parse::<Shell>().unwrap(), Shell::Bash);
        assert_eq!("Fish".parse::<Shell>().unwrap(), Shell::Fish);
    }

    #[test]
    fn shell_from_str_versioned() {
        assert_eq!("bash-5.2".parse::<Shell>().unwrap(), Shell::Bash);
        assert_eq!("zsh-5.9".parse::<Shell>().unwrap(), Shell::Zsh);
    }

    #[test]
    fn shell_from_str_unknown() {
        assert!("ksh".parse::<Shell>().is_err());
        assert!("csh".parse::<Shell>().is_err());
        assert!("tcsh".parse::<Shell>().is_err());
    }

    #[test]
    fn shell_from_str_empty() {
        assert!("".parse::<Shell>().is_err());
    }

    #[test]
    fn detect_from_nighthawk_shell_override() {
        // NIGHTHAWK_SHELL takes priority over $SHELL and version vars
        let shell = Shell::detect_from(
            Some("powershell".into()),
            Some("5.9".into()), // ZSH_VERSION (ignored)
            None,
            None,
            None,
            Some("/bin/zsh".into()),
        );
        assert_eq!(shell, Shell::PowerShell);
    }

    #[test]
    fn detect_from_unknown_override_falls_through() {
        // Unknown NIGHTHAWK_SHELL falls through to version vars / $SHELL / platform default
        let shell = Shell::detect_from(
            Some("ksh".into()),
            None,
            None,
            None,
            None,
            Some("/bin/fish".into()),
        );
        #[cfg(not(windows))]
        assert_eq!(shell, Shell::Fish);
        #[cfg(windows)]
        assert_eq!(shell, Shell::PowerShell);
    }

    #[test]
    fn detect_from_shell_path_parsing() {
        let shell = Shell::detect_from(
            None,
            None,
            None,
            None,
            None,
            Some("/usr/local/bin/fish".into()),
        );
        #[cfg(not(windows))]
        assert_eq!(shell, Shell::Fish);
        #[cfg(windows)]
        assert_eq!(shell, Shell::PowerShell);
    }

    #[test]
    fn detect_from_shell_pwsh_on_unix() {
        let shell = Shell::detect_from(None, None, None, None, None, Some("/usr/bin/pwsh".into()));
        #[cfg(not(windows))]
        assert_eq!(shell, Shell::PowerShell);
        #[cfg(windows)]
        assert_eq!(shell, Shell::PowerShell);
    }

    #[test]
    fn detect_from_no_env_vars() {
        let shell = Shell::detect_from(None, None, None, None, None, None);
        #[cfg(not(windows))]
        assert_eq!(shell, Shell::Zsh);
        #[cfg(windows)]
        assert_eq!(shell, Shell::PowerShell);
    }

    // --- New version var detection tests (issue #64) ---

    #[test]
    fn detect_from_zsh_version_beats_shell_env() {
        let shell = Shell::detect_from(
            None,
            Some("5.9".into()), // ZSH_VERSION
            None,
            None,
            None,
            Some("/bin/bash".into()), // $SHELL points to bash
        );
        #[cfg(not(windows))]
        assert_eq!(shell, Shell::Zsh); // Version var wins
        #[cfg(windows)]
        assert_eq!(shell, Shell::PowerShell); // Windows ignores version vars
    }

    #[test]
    fn detect_from_bash_version() {
        let shell = Shell::detect_from(None, None, Some("5.2".into()), None, None, None);
        #[cfg(not(windows))]
        assert_eq!(shell, Shell::Bash);
        #[cfg(windows)]
        assert_eq!(shell, Shell::PowerShell);
    }

    #[test]
    fn detect_from_fish_version() {
        let shell = Shell::detect_from(None, None, None, Some("3.6".into()), None, None);
        #[cfg(not(windows))]
        assert_eq!(shell, Shell::Fish);
        #[cfg(windows)]
        assert_eq!(shell, Shell::PowerShell);
    }

    #[test]
    fn detect_from_nu_version() {
        let shell = Shell::detect_from(None, None, None, None, Some("0.89".into()), None);
        #[cfg(not(windows))]
        assert_eq!(shell, Shell::Nushell);
        #[cfg(windows)]
        assert_eq!(shell, Shell::PowerShell);
    }

    #[test]
    fn detect_from_override_beats_version_vars() {
        let shell = Shell::detect_from(
            Some("fish".into()), // NIGHTHAWK_SHELL
            Some("5.9".into()),  // ZSH_VERSION (should be ignored)
            Some("5.2".into()),  // BASH_VERSION (should be ignored)
            None,
            None,
            None,
        );
        assert_eq!(shell, Shell::Fish); // Override wins on all platforms
    }

    #[test]
    fn detect_from_override_with_whitespace() {
        let shell = Shell::detect_from(
            Some("  zsh  ".into()), // NIGHTHAWK_SHELL with whitespace
            None,
            None,
            None,
            None,
            None,
        );
        assert_eq!(shell, Shell::Zsh); // Trimmed and parsed
    }

    #[test]
    fn detect_from_override_whitespace_only_falls_through() {
        let shell = Shell::detect_from(
            Some("   ".into()), // NIGHTHAWK_SHELL with only whitespace
            Some("5.9".into()), // ZSH_VERSION should be used instead
            None,
            None,
            None,
            None,
        );
        #[cfg(not(windows))]
        assert_eq!(shell, Shell::Zsh); // Falls through to version var
        #[cfg(windows)]
        assert_eq!(shell, Shell::PowerShell); // Windows ignores version vars
    }

    #[test]
    fn detect_from_shell_env_trailing_slash() {
        let shell = Shell::detect_from(
            None,
            None,
            None,
            None,
            None,
            Some("/bin/".into()), // Trailing slash, empty basename
        );
        // Should fall through to platform default (empty basename filtered)
        #[cfg(not(windows))]
        assert_eq!(shell, Shell::Zsh);
        #[cfg(windows)]
        assert_eq!(shell, Shell::PowerShell);
    }

    #[test]
    fn shell_serde_nu_alias() {
        let parsed: Shell = serde_json::from_str("\"nu\"").unwrap();
        assert_eq!(parsed, Shell::Nushell);
    }

    #[test]
    fn shell_from_str_roundtrip() {
        // Every variant must roundtrip through as_str -> parse
        let all_shells = [
            Shell::Zsh,
            Shell::Bash,
            Shell::Fish,
            Shell::PowerShell,
            Shell::Nushell,
        ];
        for shell in all_shells {
            assert_eq!(
                shell.as_str().parse::<Shell>().unwrap(),
                shell,
                "roundtrip failed for {:?}",
                shell,
            );
        }
    }
}
