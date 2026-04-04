use super::{HistoryEntry, ShellHistory};
use crate::proto::Shell;
use std::path::PathBuf;

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
}

impl FileHistory {
    pub fn new(shell: Shell) -> Self {
        let path = Self::default_history_path(shell);
        Self {
            shell,
            path,
            entries: Vec::new(),
        }
    }

    pub fn with_path(shell: Shell, path: PathBuf) -> Self {
        Self {
            shell,
            path,
            entries: Vec::new(),
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

impl ShellHistory for FileHistory {
    fn load(&mut self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let contents = std::fs::read_to_string(&self.path)?;
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
        self.entries.sort_by(|a, b| b.frequency.cmp(&a.frequency));

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
}
