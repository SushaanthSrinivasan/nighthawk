pub mod config_ui;
pub mod daemon_ctl;
pub mod embedded_specs;
pub mod paths;
pub mod setup;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "nh", about = "nighthawk — AI terminal autocomplete")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the daemon in the background
    Start,

    /// Stop the daemon
    Stop,

    /// Check if the daemon is running
    Status,

    /// Install shell plugin. With no argument, launches an interactive wizard
    /// that auto-detects your shell; pass a shell name to skip the prompts.
    Setup {
        /// Shell to set up (zsh, bash, fish, powershell, pwsh). Omit for the wizard.
        shell: Option<String>,
    },

    /// View or edit settings. With no argument, launches an interactive editor;
    /// use `get`/`set` for scripting.
    Config {
        #[command(subcommand)]
        action: Option<ConfigAction>,
    },

    /// Test completions from the command line
    Complete {
        /// Input to complete
        input: String,
    },
}

#[derive(Subcommand)]
enum ConfigAction {
    /// Print a setting's value (e.g. `nh config get cloud.provider`)
    Get {
        /// Setting key as `section.key`
        key: String,
    },
    /// Change a setting (e.g. `nh config set daemon.log_level debug`)
    Set {
        /// Setting key as `section.key`
        key: String,
        /// New value. `allow_hyphen_values` lets negatives (e.g. `-1`) reach our
        /// validator for a clear rejection instead of clap treating them as flags.
        #[arg(allow_hyphen_values = true)]
        value: String,
    },
}

pub fn run() {
    let cli = Cli::parse();

    let result = match cli.command {
        Commands::Start => daemon_ctl::start(),
        Commands::Stop => daemon_ctl::stop(),
        Commands::Status => daemon_ctl::status(),
        Commands::Setup { shell } => match shell {
            Some(s) => setup::setup_shell(&s),
            None => setup::setup_wizard(),
        },
        Commands::Config { action } => match action {
            Some(ConfigAction::Get { key }) => config_ui::get(&key),
            Some(ConfigAction::Set { key, value }) => config_ui::set(&key, &value),
            None => config_ui::wizard(),
        },
        Commands::Complete { input } => daemon_ctl::complete(&input),
    };

    if let Err(e) = result {
        eprintln!("Error: {e}");
        std::process::exit(1);
    }
}
