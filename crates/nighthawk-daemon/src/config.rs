use serde::Deserialize;
use std::path::PathBuf;

/// Top-level configuration loaded from ~/.config/nighthawk/config.toml
#[derive(Debug, Deserialize, Default)]
#[serde(default)]
pub struct Config {
    pub daemon: DaemonConfig,
    pub tiers: TierConfig,
    pub cloud: Option<CloudConfig>,
}

#[derive(Debug, Deserialize)]
#[serde(default)]
pub struct DaemonConfig {
    pub socket_path: Option<PathBuf>,
    pub log_level: String,
}

impl Default for DaemonConfig {
    fn default() -> Self {
        Self {
            socket_path: None,
            log_level: "info".into(),
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(default)]
pub struct TierConfig {
    pub enable_history: bool,
    pub enable_specs: bool,
    pub enable_local_llm: bool,
    pub enable_cloud: bool,
}

impl Default for TierConfig {
    fn default() -> Self {
        Self {
            enable_history: true,
            enable_specs: true,
            enable_local_llm: false,
            enable_cloud: false,
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct CloudConfig {
    pub provider: String,
    pub api_key: Option<String>,
    pub model: Option<String>,
    pub base_url: Option<String>,
}

/// Load config from the default path or a given override.
pub fn load_config(path: Option<&PathBuf>) -> Config {
    let config_path = path.cloned().unwrap_or_else(default_config_path);

    match std::fs::read_to_string(&config_path) {
        Ok(contents) => match toml::from_str(&contents) {
            Ok(config) => config,
            Err(e) => {
                tracing::warn!("Failed to parse config at {}: {e}", config_path.display());
                Config::default()
            }
        },
        Err(_) => Config::default(),
    }
}

fn default_config_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("nighthawk")
        .join("config.toml")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_is_sane() {
        let config = Config::default();
        assert!(config.tiers.enable_history);
        assert!(config.tiers.enable_specs);
        assert!(!config.tiers.enable_local_llm);
        assert!(!config.tiers.enable_cloud);
    }

    #[test]
    fn parse_minimal_toml() {
        let toml_str = r#"
[daemon]
log_level = "debug"

[tiers]
enable_specs = false
"#;
        let config: Config = toml::from_str(toml_str).unwrap();
        assert_eq!(config.daemon.log_level, "debug");
        assert!(!config.tiers.enable_specs);
        assert!(config.tiers.enable_history);
    }
}
