use super::{CliSpec, SpecProvider};
use std::path::PathBuf;

/// Loads JSON spec files from a directory on disk.
///
/// Each file is named `<command>.json` and deserializes directly into `CliSpec`.
/// Caching is handled by SpecRegistry — this provider just reads from disk.
pub struct FigSpecProvider {
    specs_dir: PathBuf,
}

impl FigSpecProvider {
    pub fn new(specs_dir: PathBuf) -> Self {
        Self { specs_dir }
    }
}

impl SpecProvider for FigSpecProvider {
    fn get_spec(&self, command: &str) -> Option<CliSpec> {
        let spec_path = self.specs_dir.join(format!("{command}.json"));
        if !spec_path.exists() {
            return None;
        }

        match std::fs::read_to_string(&spec_path) {
            Ok(contents) => match serde_json::from_str::<CliSpec>(&contents) {
                Ok(spec) => {
                    tracing::debug!(command, "Loaded spec from {}", spec_path.display());
                    Some(spec)
                }
                Err(e) => {
                    tracing::warn!(command, error = %e, "Failed to parse spec JSON");
                    None
                }
            },
            Err(e) => {
                tracing::warn!(command, error = %e, "Failed to read spec file");
                None
            }
        }
    }

    fn known_commands(&self) -> Vec<String> {
        std::fs::read_dir(&self.specs_dir)
            .ok()
            .into_iter()
            .flatten()
            .filter_map(|entry| {
                let path = entry.ok()?.path();
                if path.extension()?.to_str()? == "json" {
                    path.file_stem()?.to_str().map(String::from)
                } else {
                    None
                }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::TempDir;

    #[test]
    fn load_json_spec() {
        let dir = TempDir::new().unwrap();
        let spec_json = r#"{
            "name": "git",
            "description": "Version control",
            "subcommands": [
                {
                    "name": "checkout",
                    "aliases": ["co"],
                    "description": "Switch branches"
                }
            ],
            "options": [
                {
                    "names": ["--version"],
                    "description": "Print version"
                }
            ]
        }"#;

        let mut f = std::fs::File::create(dir.path().join("git.json")).unwrap();
        f.write_all(spec_json.as_bytes()).unwrap();

        let provider = FigSpecProvider::new(dir.path().to_path_buf());
        let spec = provider.get_spec("git").unwrap();
        assert_eq!(spec.name, "git");
        assert_eq!(spec.subcommands[0].name, "checkout");
        assert_eq!(spec.subcommands[0].aliases, vec!["co"]);
        assert_eq!(spec.options[0].names, vec!["--version"]);

        // Unknown command
        assert!(provider.get_spec("unknown").is_none());

        // known_commands lists files
        let commands = provider.known_commands();
        assert!(commands.contains(&"git".to_string()));
    }

    /// Validate all converted specs in the specs/ directory deserialize correctly.
    /// This catches any JSON format mismatches from the fig converter.
    #[test]
    fn validate_converted_specs() {
        let specs_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("specs");

        if !specs_dir.exists() {
            // Skip if specs dir doesn't exist (CI without converted specs)
            return;
        }

        let provider = FigSpecProvider::new(specs_dir.clone());
        let commands = provider.known_commands();
        if commands.is_empty() {
            println!("No specs found, skipping validation");
            return;
        }

        let mut success = 0;
        let mut failures = Vec::new();

        for cmd in &commands {
            match provider.get_spec(cmd) {
                Some(spec) => {
                    assert_eq!(spec.name, *cmd, "Spec name mismatch for {cmd}");
                    success += 1;
                }
                None => {
                    failures.push(cmd.clone());
                }
            }
        }

        assert!(
            failures.is_empty(),
            "Failed to deserialize {} specs: {:?}",
            failures.len(),
            &failures[..failures.len().min(10)]
        );

        eprintln!("Validated {success}/{} specs successfully", commands.len());
    }
}
