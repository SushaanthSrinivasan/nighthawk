pub mod fig;
pub mod helpparse;

use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

// --- Spec data structures ---

/// A parsed CLI completion spec.
#[derive(Debug, Clone, Serialize, Deserialize)]
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

#[derive(Debug, Clone, Serialize, Deserialize)]
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OptionSpec {
    pub names: Vec<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub takes_arg: bool,
    #[serde(default)]
    pub is_required: bool,
    #[serde(default)]
    pub arg: Option<ArgSpec>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
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

#[derive(Debug, Clone, Serialize, Deserialize)]
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

    /// If true, SpecRegistry will NOT cache None results from this provider.
    /// Used by providers that populate asynchronously (e.g., --help parser).
    fn is_fallback(&self) -> bool {
        false
    }
}

// --- SpecRegistry ---

/// Chains multiple SpecProviders with an in-memory cache.
/// Providers are queried in order; first match wins and gets cached.
/// Fallback providers (is_fallback() == true) should be registered last.
pub struct SpecRegistry {
    providers: Vec<Box<dyn SpecProvider>>,
    cache: RwLock<HashMap<String, Option<CliSpec>>>,
    /// Cached list of all known command names across providers.
    /// Populated lazily on first `fuzzy_lookup` call to avoid repeated
    /// filesystem scans (FigSpecProvider::known_commands does read_dir).
    /// TODO: invalidate when HelpParseProvider discovers new commands.
    known_commands_cache: RwLock<Option<Vec<String>>>,
}

impl SpecRegistry {
    pub fn new(providers: Vec<Box<dyn SpecProvider>>) -> Self {
        Self {
            providers,
            cache: RwLock::new(HashMap::new()),
            known_commands_cache: RwLock::new(None),
        }
    }

    /// Look up a spec by command name. Cached after first lookup.
    ///
    /// When all providers return None and the last queried provider is a
    /// fallback (may populate asynchronously), the None is NOT cached so
    /// the next request can retry.
    pub fn lookup(&self, command: &str) -> Option<CliSpec> {
        // Check cache first
        if let Some(cached) = self.cache.read().get(command) {
            return cached.clone();
        }

        // Query providers in order
        let mut result = None;
        let mut last_was_fallback = false;
        for provider in &self.providers {
            if let Some(spec) = provider.get_spec(command) {
                result = Some(spec);
                last_was_fallback = false;
                break;
            }
            last_was_fallback = provider.is_fallback();
        }

        // Cache the result — but NOT if it's None and the last queried
        // provider is a fallback (it may populate asynchronously)
        if result.is_some() || !last_was_fallback {
            self.cache
                .write()
                .insert(command.to_string(), result.clone());
        }

        result
    }

    /// Try fuzzy matching the command name against all known commands.
    ///
    /// Returns the best match (lowest edit distance) and its spec if one
    /// exists within the allowed distance threshold. Uses a lazily-cached
    /// command list to avoid repeated filesystem scans.
    ///
    /// Deterministic tiebreaking: alphabetically first among equidistant.
    pub fn fuzzy_lookup(&self, command: &str) -> Option<(CliSpec, usize)> {
        let commands = {
            let cache = self.known_commands_cache.read();
            if let Some(ref cached) = *cache {
                cached.clone()
            } else {
                drop(cache);
                let commands: Vec<String> = self
                    .providers
                    .iter()
                    .flat_map(|p| p.known_commands())
                    .collect();
                *self.known_commands_cache.write() = Some(commands.clone());
                commands
            }
        };

        let matches =
            crate::daemon::fuzzy::fuzzy_matches(command, commands.iter().map(|s| s.as_str()));

        let best = matches.first()?;
        let spec = self.lookup(&best.text)?;
        Some((spec, best.distance))
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

    #[test]
    fn registry_retries_when_fallback_returns_none() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;

        struct Inner {
            ready: AtomicBool,
        }
        struct DelayedFallback {
            inner: Arc<Inner>,
        }

        impl SpecProvider for DelayedFallback {
            fn get_spec(&self, command: &str) -> Option<CliSpec> {
                if self.inner.ready.load(Ordering::SeqCst) {
                    Some(CliSpec {
                        name: command.into(),
                        description: None,
                        subcommands: vec![],
                        options: vec![],
                        args: vec![],
                    })
                } else {
                    None
                }
            }
            fn known_commands(&self) -> Vec<String> {
                vec![]
            }
            fn is_fallback(&self) -> bool {
                true
            }
        }

        let inner = Arc::new(Inner {
            ready: AtomicBool::new(false),
        });
        let provider = DelayedFallback {
            inner: Arc::clone(&inner),
        };
        let registry = SpecRegistry::new(vec![Box::new(provider)]);

        // First lookup: fallback returns None, NOT cached
        assert!(registry.lookup("mycmd").is_none());

        // Simulate background task completing
        inner.ready.store(true, Ordering::SeqCst);

        // Second lookup: provider queried again (not cached), returns Some
        assert!(registry.lookup("mycmd").is_some());
    }

    #[test]
    fn registry_caches_none_from_non_fallback() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Arc;

        struct Inner {
            call_count: AtomicUsize,
        }
        struct CountingProvider {
            inner: Arc<Inner>,
        }

        impl SpecProvider for CountingProvider {
            fn get_spec(&self, _command: &str) -> Option<CliSpec> {
                self.inner.call_count.fetch_add(1, Ordering::SeqCst);
                None
            }
            fn known_commands(&self) -> Vec<String> {
                vec![]
            }
            // is_fallback() defaults to false
        }

        let inner = Arc::new(Inner {
            call_count: AtomicUsize::new(0),
        });
        let provider = CountingProvider {
            inner: Arc::clone(&inner),
        };
        let registry = SpecRegistry::new(vec![Box::new(provider)]);

        // First lookup queries the provider
        assert!(registry.lookup("unknown").is_none());
        assert_eq!(inner.call_count.load(Ordering::SeqCst), 1);

        // Second lookup hits cache, does NOT query provider again
        assert!(registry.lookup("unknown").is_none());
        assert_eq!(inner.call_count.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn two_providers_normal_miss_fallback_miss_not_cached() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;

        // Simulates real provider chain: FigSpecProvider (normal) + HelpParseProvider (fallback)
        struct NormalProvider;
        impl SpecProvider for NormalProvider {
            fn get_spec(&self, _command: &str) -> Option<CliSpec> {
                None
            }
            fn known_commands(&self) -> Vec<String> {
                vec![]
            }
        }

        struct Inner {
            ready: AtomicBool,
        }
        struct DelayedFallback {
            inner: Arc<Inner>,
        }
        impl SpecProvider for DelayedFallback {
            fn get_spec(&self, command: &str) -> Option<CliSpec> {
                if self.inner.ready.load(Ordering::SeqCst) {
                    Some(CliSpec {
                        name: command.into(),
                        description: None,
                        subcommands: vec![],
                        options: vec![],
                        args: vec![],
                    })
                } else {
                    None
                }
            }
            fn known_commands(&self) -> Vec<String> {
                vec![]
            }
            fn is_fallback(&self) -> bool {
                true
            }
        }

        let inner = Arc::new(Inner {
            ready: AtomicBool::new(false),
        });
        let registry = SpecRegistry::new(vec![
            Box::new(NormalProvider),
            Box::new(DelayedFallback {
                inner: Arc::clone(&inner),
            }),
        ]);

        // Both miss → None NOT cached (fallback is last queried)
        assert!(registry.lookup("rg").is_none());

        // Fallback populates asynchronously
        inner.ready.store(true, Ordering::SeqCst);

        // Next lookup retries and finds the result
        assert!(registry.lookup("rg").is_some());
    }

    #[test]
    fn fuzzy_lookup_finds_close_command() {
        let mut specs = HashMap::new();
        specs.insert(
            "git".into(),
            CliSpec {
                name: "git".into(),
                description: None,
                subcommands: vec![],
                options: vec![],
                args: vec![],
            },
        );
        specs.insert(
            "curl".into(),
            CliSpec {
                name: "curl".into(),
                description: None,
                subcommands: vec![],
                options: vec![],
                args: vec![],
            },
        );

        let registry = SpecRegistry::new(vec![Box::new(TestProvider { specs })]);

        let (spec, dist) = registry.fuzzy_lookup("gti").unwrap();
        assert_eq!(spec.name, "git");
        assert_eq!(dist, 1);
    }

    #[test]
    fn fuzzy_lookup_returns_none_for_distant() {
        let mut specs = HashMap::new();
        specs.insert(
            "git".into(),
            CliSpec {
                name: "git".into(),
                description: None,
                subcommands: vec![],
                options: vec![],
                args: vec![],
            },
        );

        let registry = SpecRegistry::new(vec![Box::new(TestProvider { specs })]);
        assert!(registry.fuzzy_lookup("xyz").is_none());
    }

    #[test]
    fn fuzzy_lookup_caches_command_list() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Arc;

        struct Inner {
            call_count: AtomicUsize,
        }
        struct CountingProvider {
            inner: Arc<Inner>,
        }

        impl SpecProvider for CountingProvider {
            fn get_spec(&self, command: &str) -> Option<CliSpec> {
                if command == "git" {
                    Some(CliSpec {
                        name: "git".into(),
                        description: None,
                        subcommands: vec![],
                        options: vec![],
                        args: vec![],
                    })
                } else {
                    None
                }
            }
            fn known_commands(&self) -> Vec<String> {
                self.inner.call_count.fetch_add(1, Ordering::SeqCst);
                vec!["git".into()]
            }
        }

        let inner = Arc::new(Inner {
            call_count: AtomicUsize::new(0),
        });
        let registry = SpecRegistry::new(vec![Box::new(CountingProvider {
            inner: Arc::clone(&inner),
        })]);

        // First fuzzy_lookup populates the cache
        let _ = registry.fuzzy_lookup("gti");
        assert_eq!(inner.call_count.load(Ordering::SeqCst), 1);

        // Second call reuses cached list — known_commands NOT called again
        let _ = registry.fuzzy_lookup("gti");
        assert_eq!(inner.call_count.load(Ordering::SeqCst), 1);
    }
}
