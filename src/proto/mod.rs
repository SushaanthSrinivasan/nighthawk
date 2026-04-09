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

    /// Detect default shell from env vars + platform.
    ///
    /// Priority: `NIGHTHAWK_SHELL` env var > `$SHELL` (Unix) > platform default.
    pub fn detect_default() -> Self {
        Self::detect_from(
            std::env::var("NIGHTHAWK_SHELL").ok(),
            std::env::var("SHELL").ok(),
        )
    }

    /// Pure detection function for testability — takes env values as parameters.
    pub fn detect_from(nighthawk_shell: Option<String>, shell_env: Option<String>) -> Self {
        // 1. NIGHTHAWK_SHELL override
        if let Some(ref s) = nighthawk_shell {
            if let Ok(shell) = s.parse::<Shell>() {
                return shell;
            }
            // Unknown value — fall through (caller should log warning)
        }

        // 2. Platform default / $SHELL
        let _shell_env = shell_env; // used only on non-Windows
        #[cfg(windows)]
        {
            Shell::PowerShell
        }

        #[cfg(not(windows))]
        {
            shell_env
                .as_deref()
                .and_then(|s| s.rsplit('/').next())
                .and_then(|name| name.parse::<Shell>().ok())
                .unwrap_or(Shell::Zsh)
        }
    }
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
        // NIGHTHAWK_SHELL takes priority over $SHELL
        let shell = Shell::detect_from(Some("powershell".into()), Some("/bin/zsh".into()));
        assert_eq!(shell, Shell::PowerShell);
    }

    #[test]
    fn detect_from_unknown_override_falls_through() {
        // Unknown NIGHTHAWK_SHELL falls through to $SHELL / platform default
        let shell = Shell::detect_from(Some("ksh".into()), Some("/bin/fish".into()));
        #[cfg(not(windows))]
        assert_eq!(shell, Shell::Fish);
        #[cfg(windows)]
        assert_eq!(shell, Shell::PowerShell);
    }

    #[test]
    fn detect_from_shell_path_parsing() {
        let shell = Shell::detect_from(None, Some("/usr/local/bin/fish".into()));
        #[cfg(not(windows))]
        assert_eq!(shell, Shell::Fish);
        #[cfg(windows)]
        assert_eq!(shell, Shell::PowerShell);
    }

    #[test]
    fn detect_from_shell_pwsh_on_unix() {
        let shell = Shell::detect_from(None, Some("/usr/bin/pwsh".into()));
        #[cfg(not(windows))]
        assert_eq!(shell, Shell::PowerShell);
        #[cfg(windows)]
        assert_eq!(shell, Shell::PowerShell);
    }

    #[test]
    fn detect_from_no_env_vars() {
        let shell = Shell::detect_from(None, None);
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
