use super::{CliSpec, OptionSpec, SpecProvider, SubcommandSpec};
use parking_lot::RwLock;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;

/// Maximum bytes to read from --help output before truncating.
const MAX_HELP_OUTPUT_BYTES: usize = 256 * 1024;

/// Timeout for running `command --help`.
const HELP_TIMEOUT_SECS: u64 = 5;

/// Parses --help output from CLIs to generate completion specs on the fly.
///
/// When a command isn't in the fig specs, we run `command --help`, parse
/// the output, and cache the result to disk for future use. The first
/// request for an unknown command returns None (triggering a background
/// parse); subsequent requests return the cached result.
pub struct HelpParseProvider {
    cache_dir: PathBuf,
    cache: Arc<RwLock<HashMap<String, CliSpec>>>,
    pending: Arc<RwLock<HashSet<String>>>,
    failed: Arc<RwLock<HashSet<String>>>,
    runtime_handle: tokio::runtime::Handle,
}

impl HelpParseProvider {
    pub fn new(cache_dir: PathBuf, runtime_handle: tokio::runtime::Handle) -> Self {
        let cache = Self::load_disk_cache(&cache_dir);
        tracing::info!(
            count = cache.len(),
            "Loaded --help cache entries from {}",
            cache_dir.display()
        );
        Self {
            cache_dir,
            cache: Arc::new(RwLock::new(cache)),
            pending: Arc::new(RwLock::new(HashSet::new())),
            failed: Arc::new(RwLock::new(HashSet::new())),
            runtime_handle,
        }
    }

    fn load_disk_cache(cache_dir: &Path) -> HashMap<String, CliSpec> {
        let mut cache = HashMap::new();
        let entries = match std::fs::read_dir(cache_dir) {
            Ok(entries) => entries,
            Err(_) => return cache,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            // Clean up stale .tmp files from interrupted writes
            if path.extension().and_then(|e| e.to_str()) == Some("tmp") {
                let _ = std::fs::remove_file(&path);
                continue;
            }
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let command = match path.file_stem().and_then(|s| s.to_str()) {
                Some(name) => name.to_string(),
                None => continue,
            };
            match std::fs::read_to_string(&path) {
                Ok(contents) => match serde_json::from_str::<CliSpec>(&contents) {
                    Ok(spec) => {
                        cache.insert(command, spec);
                    }
                    Err(e) => {
                        tracing::warn!(path = %path.display(), error = %e, "Bad help cache file");
                    }
                },
                Err(e) => {
                    tracing::warn!(path = %path.display(), error = %e, "Failed to read help cache");
                }
            }
        }
        cache
    }

    fn spawn_help_parse(&self, command: &str) {
        let command = command.to_string();

        // Mark as pending to prevent duplicate spawns
        {
            let mut pending = self.pending.write();
            if !pending.insert(command.clone()) {
                return;
            }
        }

        let cache = Arc::clone(&self.cache);
        let pending = Arc::clone(&self.pending);
        let failed = Arc::clone(&self.failed);
        let cache_dir = self.cache_dir.clone();

        self.runtime_handle.spawn(async move {
            let result = Self::run_help_parse(&command).await;

            // Remove from pending
            pending.write().remove(&command);

            match result {
                Some(spec) => {
                    Self::write_disk_cache(&cache_dir, &command, &spec);
                    cache.write().insert(command, spec);
                }
                None => {
                    // Negative cache: don't retry this command
                    failed.write().insert(command);
                }
            }
        });
    }

    async fn run_help_parse(command: &str) -> Option<CliSpec> {
        if !Self::is_safe_command_name(command) {
            tracing::debug!(command, "Rejected unsafe command name");
            return None;
        }

        if !Self::command_exists_in_path(command).await {
            tracing::debug!(command, "Command not found in PATH");
            return None;
        }

        // Try --help first, then -h as fallback
        if let Some(spec) = Self::try_help_flag(command, "--help").await {
            return Some(spec);
        }
        Self::try_help_flag(command, "-h").await
    }

    async fn try_help_flag(command: &str, flag: &str) -> Option<CliSpec> {
        let output = match tokio::time::timeout(
            std::time::Duration::from_secs(HELP_TIMEOUT_SECS),
            tokio::process::Command::new(command)
                .arg(flag)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .kill_on_drop(true)
                .output(),
        )
        .await
        {
            Ok(Ok(output)) => output,
            Ok(Err(e)) => {
                tracing::debug!(command, flag, error = %e, "Failed to run help command");
                return None;
            }
            Err(_) => {
                tracing::debug!(command, flag, "Help command timed out");
                return None;
            }
        };

        // Use stdout; some commands write help to stderr
        let raw = if !output.stdout.is_empty() {
            &output.stdout
        } else {
            &output.stderr
        };

        if raw.is_empty() {
            return None;
        }

        // Cap output size to prevent memory bloat
        let truncated = &raw[..raw.len().min(MAX_HELP_OUTPUT_BYTES)];
        let text = String::from_utf8_lossy(truncated);

        let spec = Self::parse_help_text(command, &text);

        // Reject garbage: must have at least one option or subcommand
        if spec.options.is_empty() && spec.subcommands.is_empty() {
            tracing::debug!(
                command,
                flag,
                "Parsed help but found no options/subcommands"
            );
            return None;
        }

        tracing::info!(
            command,
            flag,
            options = spec.options.len(),
            subcommands = spec.subcommands.len(),
            "Parsed help output"
        );
        Some(spec)
    }

    fn is_safe_command_name(command: &str) -> bool {
        if command.is_empty() || command.len() > 255 {
            return false;
        }
        if command.contains('/') || command.contains('\\') {
            return false;
        }
        !command.chars().any(|c| {
            matches!(
                c,
                '\0' | ';'
                    | '&'
                    | '|'
                    | '$'
                    | '`'
                    | '('
                    | ')'
                    | '{'
                    | '}'
                    | '<'
                    | '>'
                    | '!'
                    | '\n'
                    | '\r'
                    | ' '
                    | '\t'
                    | '"'
                    | '\''
            )
        })
    }

    async fn command_exists_in_path(command: &str) -> bool {
        #[cfg(unix)]
        let check = tokio::process::Command::new("which")
            .arg(command)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await;

        #[cfg(windows)]
        let check = tokio::process::Command::new("where")
            .arg(command)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await;

        matches!(check, Ok(status) if status.success())
    }

    fn write_disk_cache(cache_dir: &Path, command: &str, spec: &CliSpec) {
        if let Err(e) = std::fs::create_dir_all(cache_dir) {
            tracing::warn!(error = %e, "Failed to create help cache dir");
            return;
        }
        let final_path = cache_dir.join(format!("{command}.json"));
        let tmp_path = cache_dir.join(format!("{command}.json.tmp"));

        let json = match serde_json::to_string_pretty(spec) {
            Ok(json) => json,
            Err(e) => {
                tracing::warn!(command, error = %e, "Failed to serialize spec");
                return;
            }
        };

        // Atomic write: write to .tmp then rename
        if let Err(e) = std::fs::write(&tmp_path, &json) {
            tracing::warn!(path = %tmp_path.display(), error = %e, "Failed to write temp cache file");
            return;
        }
        if let Err(e) = std::fs::rename(&tmp_path, &final_path) {
            tracing::warn!(error = %e, "Failed to rename temp cache file");
            // Clean up temp file
            let _ = std::fs::remove_file(&tmp_path);
        }
    }

    /// Parse --help output text into a CliSpec.
    /// Handles common formats: GNU-style, clap, cobra, argparse.
    pub fn parse_help_text(command: &str, help_text: &str) -> CliSpec {
        let mut options = Vec::new();
        let mut subcommands = Vec::new();

        for line in help_text.lines() {
            let trimmed = line.trim();

            // Parse option lines like "  -f, --force    Force operation"
            if let Some(opt) = Self::parse_option_line(trimmed) {
                options.push(opt);
            }

            // Parse subcommand lines like "  checkout   Switch branches"
            if let Some(sub) = Self::parse_subcommand_line(trimmed) {
                subcommands.push(sub);
            }
        }

        CliSpec {
            name: command.to_string(),
            description: None,
            subcommands,
            options,
            args: vec![],
        }
    }

    fn parse_option_line(line: &str) -> Option<OptionSpec> {
        if !line.starts_with('-') {
            return None;
        }

        let mut names = Vec::new();
        let mut description = None;

        // Split on multiple spaces to separate flags from description
        let parts: Vec<&str> = line.splitn(2, "  ").collect();
        let flags_part = parts[0].trim();

        if parts.len() > 1 {
            description = Some(parts[1].trim().to_string());
        }

        // Parse comma-separated flags like "-f, --force"
        for flag in flags_part.split(',') {
            let flag = flag.split_whitespace().next().unwrap_or("");
            if flag.starts_with('-') {
                names.push(flag.to_string());
            }
        }

        if names.is_empty() {
            return None;
        }

        let takes_arg = flags_part.contains('<') || flags_part.contains('=');

        Some(OptionSpec {
            names,
            description,
            takes_arg,
            is_required: false,
            arg: None,
        })
    }

    fn parse_subcommand_line(line: &str) -> Option<SubcommandSpec> {
        // Heuristic: subcommand lines are indented, don't start with -,
        // and have a description separated by multiple spaces
        if line.starts_with('-') || line.is_empty() {
            return None;
        }

        let parts: Vec<&str> = line.splitn(2, "  ").collect();
        if parts.len() < 2 {
            return None;
        }

        let name = parts[0].trim().to_string();
        let desc = parts[1].trim().to_string();

        // Subcommand names are typically short, alphabetic tokens
        if name.contains(' ')
            || name.len() > 30
            || !name
                .chars()
                .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
        {
            return None;
        }

        Some(SubcommandSpec {
            name,
            aliases: vec![],
            description: Some(desc),
            subcommands: vec![],
            options: vec![],
            args: vec![],
        })
    }
}

impl SpecProvider for HelpParseProvider {
    fn get_spec(&self, command: &str) -> Option<CliSpec> {
        // Check in-memory cache
        if let Some(spec) = self.cache.read().get(command) {
            return Some(spec.clone());
        }

        // Don't retry known failures
        if self.failed.read().contains(command) {
            return None;
        }

        // Don't double-spawn
        if self.pending.read().contains(command) {
            return None;
        }

        // Spawn background task to run --help
        self.spawn_help_parse(command);
        None
    }

    fn known_commands(&self) -> Vec<String> {
        self.cache.read().keys().cloned().collect()
    }

    fn is_fallback(&self) -> bool {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_gnu_style_options() {
        let help = r#"
Usage: myapp [OPTIONS] [COMMAND]

Options:
  -f, --force          Force the operation
  -v, --verbose        Enable verbose output
  -o, --output <FILE>  Output file path
  -h, --help           Print help

Commands:
  init       Initialize a new project
  build      Build the project
  test       Run tests
"#;

        let spec = HelpParseProvider::parse_help_text("myapp", help);
        assert_eq!(spec.name, "myapp");

        // Should find options
        assert!(spec
            .options
            .iter()
            .any(|o| o.names.contains(&"--force".to_string())));
        assert!(spec
            .options
            .iter()
            .any(|o| o.names.contains(&"-v".to_string())));

        // --output should be marked as takes_arg
        let output_opt = spec
            .options
            .iter()
            .find(|o| o.names.contains(&"--output".to_string()));
        assert!(output_opt.unwrap().takes_arg);

        // Should find subcommands
        assert!(spec.subcommands.iter().any(|s| s.name == "init"));
        assert!(spec.subcommands.iter().any(|s| s.name == "build"));
    }

    #[test]
    fn reject_empty_parse_result() {
        let spec = HelpParseProvider::parse_help_text(
            "bad",
            "This is not help output.\nJust random text with no flags.",
        );
        assert!(spec.options.is_empty());
        assert!(spec.subcommands.is_empty());
    }

    #[test]
    fn disk_cache_round_trip() {
        let dir = tempfile::TempDir::new().unwrap();
        let spec = HelpParseProvider::parse_help_text(
            "myapp",
            "  -f, --force  Force\n  init  Initialize\n",
        );

        HelpParseProvider::write_disk_cache(dir.path(), "myapp", &spec);

        // Verify .tmp file is cleaned up
        assert!(!dir.path().join("myapp.json.tmp").exists());
        assert!(dir.path().join("myapp.json").exists());

        let cache = HelpParseProvider::load_disk_cache(dir.path());
        assert!(cache.contains_key("myapp"));
        let loaded = &cache["myapp"];
        assert_eq!(loaded.name, "myapp");
        assert!(!loaded.options.is_empty());
        assert!(!loaded.subcommands.is_empty());
    }

    #[test]
    fn corrupt_cache_file_skipped() {
        let dir = tempfile::TempDir::new().unwrap();
        std::fs::write(dir.path().join("bad.json"), "not valid json{{{").unwrap();
        std::fs::write(
            dir.path().join("good.json"),
            r#"{"name":"good","subcommands":[],"options":[],"args":[]}"#,
        )
        .unwrap();

        let cache = HelpParseProvider::load_disk_cache(dir.path());
        assert!(!cache.contains_key("bad"));
        assert!(cache.contains_key("good"));
    }

    #[test]
    fn tmp_files_cleaned_up_by_cache_loader() {
        let dir = tempfile::TempDir::new().unwrap();
        let tmp_path = dir.path().join("leftover.json.tmp");
        std::fs::write(
            &tmp_path,
            r#"{"name":"leftover","subcommands":[],"options":[],"args":[]}"#,
        )
        .unwrap();

        let cache = HelpParseProvider::load_disk_cache(dir.path());
        assert!(cache.is_empty());
        // Stale .tmp file should be cleaned up
        assert!(!tmp_path.exists());
    }

    #[test]
    fn command_validation_rejects_metacharacters() {
        assert!(!HelpParseProvider::is_safe_command_name(""));
        assert!(!HelpParseProvider::is_safe_command_name("cmd;rm"));
        assert!(!HelpParseProvider::is_safe_command_name("cmd|pipe"));
        assert!(!HelpParseProvider::is_safe_command_name("cmd&bg"));
        assert!(!HelpParseProvider::is_safe_command_name("/usr/bin/ls"));
        assert!(!HelpParseProvider::is_safe_command_name("cmd with spaces"));
        assert!(!HelpParseProvider::is_safe_command_name("$(evil)"));
        assert!(!HelpParseProvider::is_safe_command_name("cmd\ninjection"));
        assert!(!HelpParseProvider::is_safe_command_name("cmd\0null"));

        assert!(HelpParseProvider::is_safe_command_name("ls"));
        assert!(HelpParseProvider::is_safe_command_name("git"));
        assert!(HelpParseProvider::is_safe_command_name("cargo-clippy"));
        assert!(HelpParseProvider::is_safe_command_name("python3.11"));
    }

    #[test]
    fn negative_cache_prevents_retry() {
        let dir = tempfile::TempDir::new().unwrap();
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let handle = rt.handle().clone();

        let provider = HelpParseProvider::new(dir.path().to_path_buf(), handle);

        // Simulate a failed command by inserting into failed set
        provider.failed.write().insert("badcmd".to_string());

        // get_spec should return None without spawning
        assert!(provider.get_spec("badcmd").is_none());

        // Verify it's not in pending (no spawn happened)
        assert!(!provider.pending.read().contains("badcmd"));
    }
}
