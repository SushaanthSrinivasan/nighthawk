pub mod config;
pub mod engine;
pub mod fuzzy;
pub mod history;
pub mod server;
pub mod specs;

use engine::PredictionEngine;
use std::sync::Arc;
use tracing_subscriber::EnvFilter;

/// Entry point for the nighthawk daemon process.
pub async fn run() -> Result<(), Box<dyn std::error::Error>> {
    // Load config
    let config = config::load_config(None);

    // Initialize tracing
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new(&config.daemon.log_level)),
        )
        .init();

    tracing::info!("Starting nighthawk daemon");

    // Build prediction tiers
    let mut tiers: Vec<Box<dyn engine::tier::PredictionTier>> = Vec::new();

    // Create shared history storage (used by HistoryTier and optionally CloudTier)
    let shared_histories: std::sync::Arc<tokio::sync::RwLock<[history::file::FileHistory; 5]>> = {
        use crate::proto::Shell;
        use history::file::FileHistory;
        use history::ShellHistory;
        let shells = [
            Shell::Zsh,
            Shell::Bash,
            Shell::Fish,
            Shell::PowerShell,
            Shell::Nushell,
        ];
        let histories: [FileHistory; 5] = std::array::from_fn(|i| {
            let mut h = FileHistory::new(shells[i]);
            if let Err(e) = h.load() {
                tracing::debug!(shell = shells[i].as_str(), error = %e, "No history file");
            }
            h
        });
        std::sync::Arc::new(tokio::sync::RwLock::new(histories))
    };

    // Tier 0: History (uses shared history storage)
    if config.tiers.enable_history {
        tiers.push(Box::new(
            engine::history::HistoryTier::with_shared_histories(std::sync::Arc::clone(
                &shared_histories,
            )),
        ));
        tracing::debug!("History tier enabled (multi-shell)");
    }

    // Tier 1: Specs
    if config.tiers.enable_specs {
        let specs_dir = std::env::var("NIGHTHAWK_SPECS_DIR")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| {
                dirs::config_dir()
                    .unwrap_or_else(|| std::path::PathBuf::from("."))
                    .join("nighthawk")
                    .join("specs")
            });

        tracing::info!("Loading specs from {}", specs_dir.display());

        let fig_provider = specs::fig::FigSpecProvider::new(specs_dir.clone());
        let help_cache_dir = specs_dir.join("help_cache");
        if let Err(e) = std::fs::create_dir_all(&help_cache_dir) {
            tracing::warn!("Failed to create help cache dir: {e}");
        }
        let help_provider = specs::helpparse::HelpParseProvider::new(
            help_cache_dir,
            tokio::runtime::Handle::current(),
        );

        let registry = Arc::new(specs::SpecRegistry::new(vec![
            Box::new(fig_provider),
            Box::new(help_provider),
        ]));

        tiers.push(Box::new(engine::specs::SpecTier::new(registry)));
        tracing::debug!("Spec tier enabled");
    }

    // Tier 2: Local LLM
    #[cfg(feature = "local-llm")]
    if config.tiers.enable_local_llm {
        let llm_config = config.local_llm.unwrap_or_default();
        tracing::info!(
            endpoint = %llm_config.endpoint,
            model = %llm_config.model,
            budget_ms = llm_config.budget_ms,
            "Local LLM tier enabled"
        );
        tiers.push(Box::new(engine::llm::LlmTier::new(llm_config)));
    }

    #[cfg(not(feature = "local-llm"))]
    if config.tiers.enable_local_llm {
        tracing::warn!(
            "enable_local_llm is set but nighthawk was compiled without the 'local-llm' feature. \
             Reinstall with: cargo install nighthawk --features local-llm"
        );
    }

    // Tier 3: Cloud LLM (independent of local-llm, shares history with HistoryTier)
    #[cfg(feature = "cloud-llm")]
    if config.tiers.enable_cloud {
        let cloud_config = config.cloud.clone().unwrap_or_default();
        match engine::cloud::CloudTier::new(
            cloud_config.clone(),
            std::sync::Arc::clone(&shared_histories),
        ) {
            Some(tier) => {
                tracing::info!(
                    provider = ?cloud_config.provider,
                    model = %cloud_config.model.clone().unwrap_or_else(|| cloud_config.default_model().to_string()),
                    "Cloud LLM tier enabled"
                );
                tiers.push(Box::new(tier));
            }
            None => {
                // Warning already logged by CloudTier::new()
            }
        }
    }

    #[cfg(not(feature = "cloud-llm"))]
    if config.tiers.enable_cloud {
        tracing::warn!(
            "enable_cloud is set but nighthawk was compiled without the 'cloud-llm' feature. \
             Reinstall with: cargo install nighthawk --features cloud-llm"
        );
    }

    // Build engine
    let engine = Arc::new(PredictionEngine::new(tiers));

    // Determine socket path
    let socket_path = config
        .daemon
        .socket_path
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|| {
            crate::proto::default_socket_path()
                .to_string_lossy()
                .to_string()
        });

    // Run server
    server::run(engine, &socket_path).await?;

    Ok(())
}
