use serde::Deserialize;
use std::path::PathBuf;

/// Top-level configuration loaded from ~/.config/nighthawk/config.toml
#[derive(Debug, Deserialize, Default)]
#[serde(default)]
pub struct Config {
    pub daemon: DaemonConfig,
    pub tiers: TierConfig,
    pub local_llm: Option<LlmConfig>,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum CloudProvider {
    #[default]
    OpenAI,
    Anthropic,
    Groq,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(default)]
pub struct CloudConfig {
    pub provider: CloudProvider,
    pub api_key: Option<String>,
    pub model: Option<String>,
    pub base_url: Option<String>,
    pub budget_ms: u32,
    pub history_context_size: usize,
    pub max_tokens: u32,
    pub temperature: f32,
}

impl Default for CloudConfig {
    fn default() -> Self {
        Self {
            provider: CloudProvider::OpenAI,
            api_key: None,
            model: None,
            base_url: None,
            budget_ms: 2000,
            history_context_size: 10,
            max_tokens: 150,
            temperature: 0.2,
        }
    }
}

impl CloudConfig {
    /// Get API key from config or environment variable
    pub fn api_key(&self) -> Option<String> {
        self.api_key.clone().or_else(|| {
            let var = match self.provider {
                CloudProvider::OpenAI => "OPENAI_API_KEY",
                CloudProvider::Anthropic => "ANTHROPIC_API_KEY",
                CloudProvider::Groq => "GROQ_API_KEY",
            };
            std::env::var(var).ok()
        })
    }

    pub fn default_model(&self) -> &'static str {
        match self.provider {
            CloudProvider::OpenAI => "gpt-4o-mini",
            CloudProvider::Anthropic => "claude-3-5-haiku-latest",
            CloudProvider::Groq => "llama-3.3-70b-versatile",
        }
    }

    pub fn default_base_url(&self) -> &'static str {
        match self.provider {
            CloudProvider::OpenAI => "https://api.openai.com/v1",
            CloudProvider::Anthropic => "https://api.anthropic.com",
            CloudProvider::Groq => "https://api.groq.com/openai/v1",
        }
    }
}

/// Configuration for the local LLM tier (Tier 2).
/// All fields have sensible defaults via the explicit `Default` impl.
#[derive(Debug, Deserialize, Clone)]
#[serde(default)]
pub struct LlmConfig {
    /// Base URL for the OpenAI-compatible API endpoint.
    pub endpoint: String,
    /// Model name to request.
    pub model: String,
    /// Timeout budget in milliseconds.
    pub budget_ms: u32,
    /// Override the default system prompt sent to the model.
    pub system_prompt: Option<String>,
    /// Sampling temperature. 0.0 = deterministic.
    pub temperature: f32,
    /// Maximum tokens to generate.
    pub max_tokens: u32,
}

impl Default for LlmConfig {
    fn default() -> Self {
        Self {
            endpoint: "http://localhost:11434/v1".into(),
            model: "qwen2.5-coder:1.5b".into(),
            budget_ms: 500,
            system_prompt: None,
            temperature: 0.0,
            max_tokens: 64,
        }
    }
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

    #[test]
    fn parse_local_llm_config() {
        let toml_str = r#"
[tiers]
enable_local_llm = true

[local_llm]
endpoint = "http://localhost:8080/v1"
model = "codellama:7b"
budget_ms = 300
temperature = 0.1
max_tokens = 128
"#;
        let config: Config = toml::from_str(toml_str).unwrap();
        assert!(config.tiers.enable_local_llm);
        let llm = config.local_llm.unwrap();
        assert_eq!(llm.endpoint, "http://localhost:8080/v1");
        assert_eq!(llm.model, "codellama:7b");
        assert_eq!(llm.budget_ms, 300);
        assert!((llm.temperature - 0.1).abs() < f32::EPSILON);
        assert_eq!(llm.max_tokens, 128);
    }

    #[test]
    fn default_local_llm_config() {
        let llm = LlmConfig::default();
        assert_eq!(llm.endpoint, "http://localhost:11434/v1");
        assert_eq!(llm.model, "qwen2.5-coder:1.5b");
        assert_eq!(llm.budget_ms, 500);
        assert_eq!(llm.temperature, 0.0);
        assert_eq!(llm.max_tokens, 64);
        assert!(llm.system_prompt.is_none());
    }

    #[test]
    fn enable_llm_without_section() {
        let toml_str = r#"
[tiers]
enable_local_llm = true
"#;
        let config: Config = toml::from_str(toml_str).unwrap();
        assert!(config.tiers.enable_local_llm);
        // local_llm section absent → Option is None, unwrap_or_default() at wiring
        assert!(config.local_llm.is_none());
        let llm = config.local_llm.unwrap_or_default();
        assert_eq!(llm.endpoint, "http://localhost:11434/v1");
    }

    #[test]
    fn temperature_integer_coercion() {
        // TOML distinguishes integers from floats, but the toml crate
        // auto-coerces integers to f32 fields. Verify this works so
        // users can write `temperature = 0` instead of `temperature = 0.0`.
        let toml_str = r#"
[local_llm]
temperature = 0
"#;
        let config: Config = toml::from_str(toml_str).unwrap();
        let llm = config.local_llm.unwrap();
        assert_eq!(llm.temperature, 0.0);
    }

    #[test]
    fn parse_cloud_config() {
        let toml_str = r#"
[tiers]
enable_cloud = true

[cloud]
provider = "anthropic"
budget_ms = 1500
"#;
        let config: Config = toml::from_str(toml_str).unwrap();
        assert!(config.tiers.enable_cloud);
        let cloud = config.cloud.unwrap();
        assert_eq!(cloud.provider, CloudProvider::Anthropic);
        assert_eq!(cloud.budget_ms, 1500);
    }

    #[test]
    fn default_cloud_config() {
        let cloud = CloudConfig::default();
        assert_eq!(cloud.provider, CloudProvider::OpenAI);
        assert_eq!(cloud.budget_ms, 2000);
        assert_eq!(cloud.history_context_size, 10);
        assert_eq!(cloud.max_tokens, 150);
    }

    #[test]
    fn cloud_config_default_model() {
        let cloud = CloudConfig::default();
        assert_eq!(cloud.default_model(), "gpt-4o-mini");

        let anthropic = CloudConfig {
            provider: CloudProvider::Anthropic,
            ..Default::default()
        };
        assert_eq!(anthropic.default_model(), "claude-3-5-haiku-latest");

        let groq = CloudConfig {
            provider: CloudProvider::Groq,
            ..Default::default()
        };
        assert_eq!(groq.default_model(), "llama-3.3-70b-versatile");
    }
}
