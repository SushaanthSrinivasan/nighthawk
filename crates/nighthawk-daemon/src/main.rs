use nighthawk_daemon::{config, engine, history, server, specs};
use nighthawk_daemon::engine::PredictionEngine;
use nighthawk_daemon::history::ShellHistory;
use std::sync::Arc;
use nighthawk_proto::Shell;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
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

    // Tier 0: History
    if config.tiers.enable_history {
        let shell = Shell::Zsh; // MVP default
        let mut file_history = history::file::FileHistory::new(shell);
        if let Err(e) = file_history.load() {
            tracing::warn!("Failed to load history for {}: {e}", shell.as_str());
        }
        let history: Arc<tokio::sync::RwLock<dyn history::ShellHistory>> =
            Arc::new(tokio::sync::RwLock::new(file_history));
        tiers.push(Box::new(engine::history::HistoryTier::new(history)));
        tracing::debug!("History tier enabled");
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
        let help_provider = specs::helpparse::HelpParseProvider::new(help_cache_dir);

        let registry = Arc::new(specs::SpecRegistry::new(vec![
            Box::new(fig_provider),
            Box::new(help_provider),
        ]));

        tiers.push(Box::new(engine::specs::SpecTier::new(registry)));
        tracing::debug!("Spec tier enabled");
    }

    // Build engine
    let engine = Arc::new(PredictionEngine::new(tiers));

    // Determine socket path
    let socket_path = config
        .daemon
        .socket_path
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|| {
            nighthawk_proto::default_socket_path()
                .to_string_lossy()
                .to_string()
        });

    // Run server
    server::run(engine, &socket_path).await?;

    Ok(())
}
