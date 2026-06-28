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

    /// Test completions from the command line
    Complete {
        /// Input to complete
        input: String,
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
        Commands::Complete { input } => daemon_ctl::complete(&input),
    };

    if let Err(e) = result {
        eprintln!("Error: {e}");
        std::process::exit(1);
    }
}
