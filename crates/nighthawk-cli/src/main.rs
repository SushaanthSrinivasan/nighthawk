use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "nh", about = "nighthawk — AI terminal autocomplete")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the daemon in the foreground
    Daemon,

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

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Commands::Daemon => {
            println!("Use `nighthawk-daemon` to start the daemon directly.");
            println!("Integrated daemon management coming soon.");
        }
        Commands::Status => {
            let socket_path = nighthawk_proto::default_socket_path();
            // TODO: Try connecting to the socket to check if daemon is running
            println!("Socket path: {}", socket_path.display());
            println!("Status check not yet implemented.");
        }
        Commands::Setup { shell } => {
            println!("Shell plugin setup for '{shell}' not yet implemented.");
            println!("For now, source the plugin manually:");
            println!("  zsh:        source shells/nighthawk.zsh");
            println!("  bash:       source shells/nighthawk.bash");
            println!("  fish:       source shells/nighthawk.fish");
            println!("  powershell: . shells/nighthawk.ps1");
        }
        Commands::Complete { input } => {
            // TODO: Connect to daemon socket, send CompletionRequest, print response
            println!("Requesting completions for: {input}");
            println!("Daemon connection not yet implemented.");
        }
    }
}
