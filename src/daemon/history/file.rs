use super::{HistoryEntry, ShellHistory};
use crate::proto::Shell;
use std::path::PathBuf;
use std::time::SystemTime;

/// Reads history from shell history files on disk.
///
/// Supports:
/// - zsh: ~/.zsh_history (extended format with timestamps)
/// - bash: ~/.bash_history (plain text, one command per line)
/// - fish: ~/.local/share/fish/fish_history (custom format)
pub struct FileHistory {
    shell: Shell,
    path: PathBuf,
    entries: Vec<HistoryEntry>,
    /// File modification time at last load (for change detection)
    last_modified: Option<SystemTime>,
    /// File size at last load (for change detection)
    last_size: u64,
}

impl FileHistory {
    pub fn new(shell: Shell) -> Self {
        let path = Self::default_history_path(shell);
        Self {
            shell,
            path,
            entries: Vec::new(),
            last_modified: None,
            last_size: 0,
        }
    }

    pub fn with_path(shell: Shell, path: PathBuf) -> Self {
        Self {
            shell,
            path,
            entries: Vec::new(),
            last_modified: None,
            last_size: 0,
        }
    }

    pub fn shell(&self) -> Shell {
        self.shell
    }

    /// Get all history entries (for context in other tiers like CloudTier)
    pub fn entries(&self) -> &[HistoryEntry] {
        &self.entries
    }

    /// Check if history file changed since last load, reload if so.
    /// Returns silently on any error (file locked, inaccessible, etc.) — uses cached results.
    ///
    /// Note: There is an inherent TOCTOU race between stat and read. This is acceptable
    /// because worst case we read newer data but record older metadata, which self-corrects
    /// on the next request.
    pub fn reload_if_changed(&mut self) {
        let meta = match std::fs::metadata(&self.path) {
            Ok(m) => m,
            Err(_) => return, // File inaccessible, use cached results
        };

        let modified = meta.modified().ok();
        let size = meta.len();

        // Detect change: mtime different OR size different
        let changed = self.last_modified != modified || self.last_size != size;

        if changed {
            if let Err(e) = self.load() {
                tracing::debug!(error = %e, "History reload failed, using stale data");
            }
        }
    }

    fn default_history_path(shell: Shell) -> PathBuf {
        let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
        match shell {
            Shell::Zsh => home.join(".zsh_history"),
            Shell::Bash => home.join(".bash_history"),
            Shell::Fish => dirs::data_dir()
                .unwrap_or_else(|| home.join(".local/share"))
                .join("fish/fish_history"),
            Shell::PowerShell => {
                // PSReadLine history path
                dirs::data_dir()
                    .unwrap_or_else(|| home.clone())
                    .join("Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt")
            }
            Shell::Nushell => dirs::config_dir()
                .unwrap_or_else(|| home.clone())
                .join("nushell/history.txt"),
        }
    }

    /// Return unique first-token command names from history, in frequency order.
    /// Used for fuzzy matching when prefix search fails.
    pub fn command_names(&self) -> Vec<&str> {
        let mut seen = std::collections::HashSet::new();
        self.entries
            .iter()
            .filter_map(|e| e.command.split_whitespace().next())
            .filter(|cmd| seen.insert(*cmd))
            .collect()
    }

    fn parse_line(&self, line: &str) -> Option<String> {
        match self.shell {
            Shell::Zsh => {
                // Extended format: ": 1234567890:0;actual command"
                if line.starts_with(": ") {
                    line.split_once(';').map(|(_, s)| s.to_string())
                } else {
                    Some(line.to_string())
                }
            }
            Shell::Bash | Shell::PowerShell | Shell::Nushell => Some(line.to_string()),
            Shell::Fish => {
                // Fish format: "- cmd: actual command"
                line.strip_prefix("- cmd: ").map(|cmd| cmd.to_string())
            }
        }
    }
}

/// Reverse zsh's history metafication.
///
/// zsh reserves the Meta byte 0x83 and the 0x80–0x9f token range internally, so
/// when it writes one of those bytes to `~/.zsh_history` it emits `Meta` (0x83)
/// followed by `original ^ 0x20`. A raw 0x83 in a metafied file is therefore
/// always a Meta marker — the literal 0x83 byte is itself escaped as `83 a3` —
/// which makes this scan unambiguous. (This holds only for zsh; a bare 0x83 in
/// other shells' files is a normal UTF-8 continuation byte and must be left alone.)
///
/// A trailing lone 0x83 with no following byte is passed through unchanged; it
/// degrades to U+FFFD on decode rather than reading past the end.
fn unmetafy(raw: &[u8]) -> Vec<u8> {
    const META: u8 = 0x83;
    let mut out = Vec::with_capacity(raw.len());
    let mut i = 0;
    while i < raw.len() {
        if raw[i] == META && i + 1 < raw.len() {
            out.push(raw[i + 1] ^ 0x20);
            i += 2;
        } else {
            out.push(raw[i]);
            i += 1;
        }
    }
    out
}

impl ShellHistory for FileHistory {
    fn load(&mut self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let raw = std::fs::read(&self.path)?;
        // zsh persists non-ASCII as *metafied* bytes (Meta 0x83 followed by
        // original ^ 0x20), which is not valid UTF-8. Reverse that first so the
        // real bytes can be decoded; other shells write plain bytes.
        let bytes = if self.shell == Shell::Zsh {
            unmetafy(&raw)
        } else {
            raw
        };
        // Decode tolerantly: a single invalid sequence becomes U+FFFD instead of
        // failing the whole file. read_to_string used to error here, which both
        // dropped every entry and silently froze reload_if_changed() on stale data.
        let contents = String::from_utf8_lossy(&bytes);
        let mut entries = Vec::new();

        for line in contents.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            if let Some(command) = self.parse_line(line) {
                if !command.is_empty() {
                    entries.push(HistoryEntry {
                        command,
                        timestamp: None,
                        frequency: 1,
                    });
                }
            }
        }

        // Deduplicate, keeping last occurrence and counting frequency
        let mut seen = std::collections::HashMap::new();
        for (i, entry) in entries.iter().enumerate() {
            let counter = seen.entry(entry.command.clone()).or_insert((0u32, 0usize));
            counter.0 += 1;
            counter.1 = i;
        }

        self.entries = seen
            .into_iter()
            .map(|(command, (frequency, _idx))| HistoryEntry {
                command,
                timestamp: None,
                frequency,
            })
            .collect();

        // Sort by frequency (most used first)
        self.entries.sort_by_key(|e| std::cmp::Reverse(e.frequency));

        // Track file state for change detection
        if let Ok(meta) = std::fs::metadata(&self.path) {
            self.last_modified = meta.modified().ok();
            self.last_size = meta.len();
        }

        tracing::debug!(
            shell = ?self.shell,
            count = self.entries.len(),
            "Loaded history entries"
        );

        Ok(())
    }

    fn search_prefix(&self, prefix: &str, limit: usize) -> Vec<HistoryEntry> {
        self.entries
            .iter()
            .filter(|e| e.command.starts_with(prefix) && e.command != prefix)
            .take(limit)
            .cloned()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn parse_bash_history() {
        let mut tmp = NamedTempFile::new().unwrap();
        writeln!(tmp, "git status").unwrap();
        writeln!(tmp, "git commit -m \"test\"").unwrap();
        writeln!(tmp, "git push").unwrap();
        writeln!(tmp, "git status").unwrap();

        let mut history = FileHistory::with_path(Shell::Bash, tmp.path().to_path_buf());
        history.load().unwrap();

        let results = history.search_prefix("git s", 5);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].command, "git status");
        assert_eq!(results[0].frequency, 2);
    }

    #[test]
    fn parse_zsh_history() {
        let mut tmp = NamedTempFile::new().unwrap();
        writeln!(tmp, ": 1234567890:0;git status").unwrap();
        writeln!(tmp, ": 1234567891:0;ls -la").unwrap();

        let mut history = FileHistory::with_path(Shell::Zsh, tmp.path().to_path_buf());
        history.load().unwrap();

        let results = history.search_prefix("git", 5);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].command, "git status");
    }

    #[test]
    fn command_names_extracts_unique_first_tokens() {
        let mut tmp = NamedTempFile::new().unwrap();
        // "git status" repeated 3 times → frequency 3
        // "cargo build" repeated 2 times → frequency 2
        // "ls -la" once → frequency 1
        // Note: FileHistory deduplicates by exact command string, not first token
        writeln!(tmp, "git status").unwrap();
        writeln!(tmp, "git status").unwrap();
        writeln!(tmp, "git status").unwrap();
        writeln!(tmp, "cargo build").unwrap();
        writeln!(tmp, "cargo build").unwrap();
        writeln!(tmp, "ls -la").unwrap();

        let mut history = FileHistory::with_path(Shell::Bash, tmp.path().to_path_buf());
        history.load().unwrap();

        let names = history.command_names();

        // Entries sorted by frequency: git (3), cargo (2), ls (1)
        // command_names() preserves entry order, extracts unique first tokens
        assert_eq!(names.len(), 3);
        assert_eq!(names[0], "git");
        assert_eq!(names[1], "cargo");
        assert_eq!(names[2], "ls");
    }

    #[test]
    fn command_names_empty_history() {
        let tmp = NamedTempFile::new().unwrap();
        let mut history = FileHistory::with_path(Shell::Bash, tmp.path().to_path_buf());
        history.load().unwrap();

        let names = history.command_names();
        assert!(names.is_empty());
    }

    #[test]
    fn unmetafy_recovers_emoji() {
        // ☕ U+2615 is UTF-8 e2 98 95; zsh metafies the 0x98 and 0x95 bytes
        // (both in the reserved 0x80–0x9f range) to 83 b8 and 83 b5.
        let metafied = [0xe2, 0x83, 0xb8, 0x83, 0xb5];
        assert_eq!(unmetafy(&metafied), vec![0xe2, 0x98, 0x95]);
        assert_eq!(String::from_utf8(unmetafy(&metafied)).unwrap(), "☕");
    }

    #[test]
    fn unmetafy_passes_through_plain_and_trailing_meta() {
        // ASCII and high bytes >= 0xa0 (e.g. é = c3 a9) are not metafied.
        assert_eq!(unmetafy(b"git"), b"git");
        assert_eq!(unmetafy(&[0xc3, 0xa9]), vec![0xc3, 0xa9]);
        // A dangling Meta at EOF is kept verbatim, not read past.
        assert_eq!(unmetafy(&[0x61, 0x83]), vec![0x61, 0x83]);
    }

    #[test]
    fn loads_metafied_zsh_history() {
        // ": <ts>:0;git commit -m "café ☕"" with ☕ metafied as zsh stores it.
        let mut bytes = b": 1234567890:0;git commit -m \"caf\xc3\xa9 ".to_vec();
        bytes.extend_from_slice(&[0xe2, 0x83, 0xb8, 0x83, 0xb5]); // metafied ☕
        bytes.extend_from_slice(b"\"\n");
        let mut tmp = NamedTempFile::new().unwrap();
        tmp.write_all(&bytes).unwrap();

        let mut history = FileHistory::with_path(Shell::Zsh, tmp.path().to_path_buf());
        history.load().unwrap();

        let results = history.search_prefix("git commit", 5);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].command, "git commit -m \"café ☕\"");
    }

    #[test]
    fn invalid_utf8_does_not_fail_whole_load() {
        // A stray invalid byte in one line must not drop the other entries
        // (the read_to_string regression that also froze reload_if_changed).
        let mut tmp = NamedTempFile::new().unwrap();
        tmp.write_all(b"git status\n").unwrap();
        tmp.write_all(&[0xff, 0xfe, b'\n']).unwrap(); // invalid UTF-8 line
        tmp.write_all(b"cargo build\n").unwrap();

        let mut history = FileHistory::with_path(Shell::Bash, tmp.path().to_path_buf());
        history
            .load()
            .expect("load must succeed despite invalid bytes");

        assert_eq!(history.search_prefix("git", 5).len(), 1);
        assert_eq!(history.search_prefix("cargo", 5).len(), 1);
    }

    #[test]
    fn non_zsh_keeps_0x83_continuation_byte() {
        // Ã U+00C3 is UTF-8 c3 83 — a legitimate 0x83 continuation byte that
        // must NOT be treated as a Meta marker for non-zsh shells.
        let mut tmp = NamedTempFile::new().unwrap();
        tmp.write_all("echo Ã".as_bytes()).unwrap();
        tmp.write_all(b"\n").unwrap();

        let mut history = FileHistory::with_path(Shell::Bash, tmp.path().to_path_buf());
        history.load().unwrap();

        let results = history.search_prefix("echo", 5);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].command, "echo Ã");
    }
}
