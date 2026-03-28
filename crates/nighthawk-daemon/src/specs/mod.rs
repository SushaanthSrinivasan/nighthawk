pub mod fig;
pub mod helpparse;

use serde::Deserialize;
use std::collections::HashMap;
use std::sync::RwLock;

// --- Spec data structures ---

/// A parsed CLI completion spec.
#[derive(Debug, Clone, Deserialize)]
pub struct CliSpec {
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub subcommands: Vec<SubcommandSpec>,
    #[serde(default)]
    pub options: Vec<OptionSpec>,
    #[serde(default)]
    pub args: Vec<ArgSpec>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SubcommandSpec {
    pub name: String,
    #[serde(default)]
    pub aliases: Vec<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub subcommands: Vec<SubcommandSpec>,
    #[serde(default)]
    pub options: Vec<OptionSpec>,
    #[serde(default)]
    pub args: Vec<ArgSpec>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct OptionSpec {
    pub names: Vec<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub takes_arg: bool,
    #[serde(default)]
    pub is_required: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ArgSpec {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub is_variadic: bool,
    #[serde(default)]
    pub suggestions: Vec<String>,
    #[serde(default)]
    pub template: Option<ArgTemplate>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ArgTemplate {
    Filepaths,
    Folders,
}

// --- SpecProvider trait ---

/// A source of CLI completion specs.
pub trait SpecProvider: Send + Sync {
    /// Load a spec for the given command name. Returns None if unknown.
    fn get_spec(&self, command: &str) -> Option<CliSpec>;

    /// List all known command names.
    fn known_commands(&self) -> Vec<String>;
}

// --- SpecRegistry ---

/// Chains multiple SpecProviders with an in-memory cache.
/// Providers are queried in order; first match wins and gets cached.
pub struct SpecRegistry {
    providers: Vec<Box<dyn SpecProvider>>,
    cache: RwLock<HashMap<String, Option<CliSpec>>>,
}

impl SpecRegistry {
    pub fn new(providers: Vec<Box<dyn SpecProvider>>) -> Self {
        Self {
            providers,
            cache: RwLock::new(HashMap::new()),
        }
    }

    /// Look up a spec by command name. Cached after first lookup.
    pub fn lookup(&self, command: &str) -> Option<CliSpec> {
        // Check cache first
        if let Ok(cache) = self.cache.read() {
            if let Some(cached) = cache.get(command) {
                return cached.clone();
            }
        }

        // Query providers in order
        let mut result = None;
        for provider in &self.providers {
            if let Some(spec) = provider.get_spec(command) {
                result = Some(spec);
                break;
            }
        }

        // Cache the result (even None, to avoid repeated lookups)
        if let Ok(mut cache) = self.cache.write() {
            cache.insert(command.to_string(), result.clone());
        }

        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestProvider {
        specs: HashMap<String, CliSpec>,
    }

    impl SpecProvider for TestProvider {
        fn get_spec(&self, command: &str) -> Option<CliSpec> {
            self.specs.get(command).cloned()
        }
        fn known_commands(&self) -> Vec<String> {
            self.specs.keys().cloned().collect()
        }
    }

    #[test]
    fn registry_lookup_and_cache() {
        let mut specs = HashMap::new();
        specs.insert(
            "git".into(),
            CliSpec {
                name: "git".into(),
                description: Some("Version control".into()),
                subcommands: vec![SubcommandSpec {
                    name: "checkout".into(),
                    aliases: vec!["co".into()],
                    description: Some("Switch branches".into()),
                    subcommands: vec![],
                    options: vec![],
                    args: vec![],
                }],
                options: vec![],
                args: vec![],
            },
        );

        let registry = SpecRegistry::new(vec![Box::new(TestProvider { specs })]);

        let spec = registry.lookup("git").unwrap();
        assert_eq!(spec.name, "git");
        assert_eq!(spec.subcommands[0].name, "checkout");

        // Second lookup should hit cache
        let spec2 = registry.lookup("git").unwrap();
        assert_eq!(spec2.name, "git");

        // Unknown command returns None
        assert!(registry.lookup("unknown").is_none());
    }
}
