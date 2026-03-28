use super::{CliSpec, OptionSpec, SpecProvider, SubcommandSpec};
use std::collections::HashMap;
use std::path::PathBuf;

/// Parses --help output from CLIs to generate completion specs on the fly.
///
/// When a command isn't in the fig specs, we run `command --help`, parse
/// the output, and cache the result to disk for future use.
///
/// TODO: Implement parsers for common --help formats (GNU, clap, cobra, argparse).
pub struct HelpParseProvider {
    _cache_dir: PathBuf,
    cache: HashMap<String, CliSpec>,
}

impl HelpParseProvider {
    pub fn new(cache_dir: PathBuf) -> Self {
        Self {
            _cache_dir: cache_dir,
            cache: HashMap::new(),
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
        if name.contains(' ') || name.len() > 30 || !name.chars().all(|c| c.is_alphanumeric() || c == '-' || c == '_') {
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
        self.cache.get(command).cloned()
        // TODO: On cache miss, run `command --help`, parse output,
        // cache to self.cache and to disk at self.cache_dir
    }

    fn known_commands(&self) -> Vec<String> {
        self.cache.keys().cloned().collect()
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
        assert!(spec.options.iter().any(|o| o.names.contains(&"--force".to_string())));
        assert!(spec.options.iter().any(|o| o.names.contains(&"-v".to_string())));

        // --output should be marked as takes_arg
        let output_opt = spec.options.iter().find(|o| o.names.contains(&"--output".to_string()));
        assert!(output_opt.unwrap().takes_arg);

        // Should find subcommands
        assert!(spec.subcommands.iter().any(|s| s.name == "init"));
        assert!(spec.subcommands.iter().any(|s| s.name == "build"));
    }
}
