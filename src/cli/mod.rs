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

    /// Install shell plugin for the given shell
    Setup {
        /// Shell to set up (zsh, bash, fish, powershell)
        shell: String,
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
        Commands::Setup { shell } => setup::setup_shell(&shell),
        Commands::Complete { input } => daemon_ctl::complete(&input),
    };

    if let Err(e) = result {
        eprintln!("Error: {e}");
        std::process::exit(1);
    }
}
