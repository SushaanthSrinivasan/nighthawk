use crate::paths;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

/// Find the nighthawk-daemon binary.
/// Checks next to the current exe first, then falls back to PATH.
fn find_daemon_binary() -> Result<PathBuf, String> {
    // Check sibling to current exe
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let candidate = if cfg!(windows) {
                dir.join("nighthawk-daemon.exe")
            } else {
                dir.join("nighthawk-daemon")
            };
            if candidate.exists() {
                return Ok(candidate);
            }
        }
    }

    // Fall back to PATH — just return the name and let Command resolve it
    Ok(PathBuf::from("nighthawk-daemon"))
}

/// Read PID from pidfile. Returns None if file missing or unreadable.
fn read_pid() -> Option<u32> {
    std::fs::read_to_string(paths::pid_file())
        .ok()?
        .trim()
        .parse()
        .ok()
}

/// Check if the daemon socket is responsive.
fn is_socket_alive() -> bool {
    let socket_path = nighthawk_proto::default_socket_path();
    let path_str = socket_path.to_string_lossy();

    // Just connect — if the socket accepts, the daemon is alive
    #[cfg(unix)]
    {
        use std::os::unix::net::UnixStream;
        UnixStream::connect(&*path_str).is_ok()
    }

    #[cfg(windows)]
    {
        // On Windows, try to connect to the named pipe
        use std::fs::OpenOptions;
        OpenOptions::new()
            .read(true)
            .write(true)
            .open(&*path_str)
            .is_ok()
    }
}

/// Check if a process with the given PID is alive.
fn is_process_alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        Command::new("kill")
            .args(["-0", &pid.to_string()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }

    #[cfg(windows)]
    {
        Command::new("tasklist")
            .args(["/FI", &format!("PID eq {pid}"), "/NH"])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).contains(&pid.to_string()))
            .unwrap_or(false)
    }
}

/// Clean up stale PID file and socket.
fn clean_stale() {
    let _ = std::fs::remove_file(paths::pid_file());
    #[cfg(unix)]
    {
        let socket_path = nighthawk_proto::default_socket_path();
        let _ = std::fs::remove_file(&socket_path);
    }
}

pub fn start() -> Result<(), Box<dyn std::error::Error>> {
    // Check if already running
    if let Some(pid) = read_pid() {
        if is_process_alive(pid) {
            println!("Daemon already running (PID {pid})");
            return Ok(());
        }
        // Stale PID file — clean up
        eprintln!("Removing stale PID file (PID {pid} is dead)");
        clean_stale();
    }

    let daemon_path = find_daemon_binary().map_err(|e| format!("Cannot find daemon: {e}"))?;

    // Ensure config dir exists
    let config_dir = paths::config_dir();
    std::fs::create_dir_all(&config_dir)?;

    // Open log file in append mode
    let log_file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(paths::log_file())?;

    let log_stderr = log_file.try_clone()?;

    // Spawn detached
    let mut cmd = Command::new(&daemon_path);
    cmd.stdout(log_file).stderr(log_stderr);

    // Pass through NIGHTHAWK_SPECS_DIR if set, otherwise point to config dir specs
    if std::env::var("NIGHTHAWK_SPECS_DIR").is_err() {
        let specs = paths::specs_dir();
        if specs.exists() {
            cmd.env("NIGHTHAWK_SPECS_DIR", &specs);
        }
    }

    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }

    let child = cmd
        .spawn()
        .map_err(|e| format!("Failed to start daemon ({}): {e}", daemon_path.display()))?;

    let pid = child.id();

    // Write PID file
    std::fs::write(paths::pid_file(), pid.to_string())?;

    // Wait briefly for daemon to bind socket
    std::thread::sleep(std::time::Duration::from_millis(300));

    let socket_path = nighthawk_proto::default_socket_path();
    if is_socket_alive() {
        println!("Daemon started (PID {pid})");
        println!("  Socket: {}", socket_path.display());
        println!("  Logs:   {}", paths::log_file().display());
    } else {
        println!("Daemon spawned (PID {pid}) but socket not yet ready");
        println!("  Check logs: {}", paths::log_file().display());
    }

    Ok(())
}

pub fn stop() -> Result<(), Box<dyn std::error::Error>> {
    let pid = match read_pid() {
        Some(pid) => pid,
        None => {
            println!("Daemon is not running (no PID file)");
            return Ok(());
        }
    };

    if !is_process_alive(pid) {
        println!("Daemon is not running (PID {pid} is dead)");
        clean_stale();
        return Ok(());
    }

    println!("Stopping daemon (PID {pid})...");

    // Send graceful stop signal (suppress OS output)
    #[cfg(unix)]
    {
        let _ = Command::new("kill")
            .arg(pid.to_string())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }

    #[cfg(windows)]
    {
        let _ = Command::new("taskkill")
            .args(["/PID", &pid.to_string()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }

    // Wait for process to exit (up to 3 seconds)
    for _ in 0..30 {
        if !is_process_alive(pid) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }

    if is_process_alive(pid) {
        // Escalate to force kill
        #[cfg(unix)]
        {
            let _ = Command::new("kill")
                .args(["-9", &pid.to_string()])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
        #[cfg(windows)]
        {
            let _ = Command::new("taskkill")
                .args(["/F", "/PID", &pid.to_string()])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
        println!("Daemon did not stop gracefully, force killed (PID {pid})");
    } else {
        println!("Daemon stopped (PID {pid})");
    }

    clean_stale();
    Ok(())
}

pub fn status() -> Result<(), Box<dyn std::error::Error>> {
    let socket_path = nighthawk_proto::default_socket_path();

    match read_pid() {
        Some(pid) => {
            if is_process_alive(pid) && is_socket_alive() {
                println!("Daemon is running");
                println!("  PID:    {pid}");
                println!("  Socket: {}", socket_path.display());
                println!("  Logs:   {}", paths::log_file().display());
            } else if is_process_alive(pid) {
                println!("Daemon process alive (PID {pid}) but socket not responding");
            } else {
                println!("Daemon is not running (stale PID file)");
                clean_stale();
            }
        }
        None => {
            // No PID file, but maybe daemon was started manually
            if is_socket_alive() {
                println!("Daemon is running (started outside `nh`)");
                println!("  Socket: {}", socket_path.display());
            } else {
                println!("Daemon is not running");
            }
        }
    }

    Ok(())
}

pub fn complete(input: &str) -> Result<(), Box<dyn std::error::Error>> {
    let socket_path = nighthawk_proto::default_socket_path();
    let path_str = socket_path.to_string_lossy();

    let req = nighthawk_proto::CompletionRequest {
        input: input.to_string(),
        cursor: input.len(),
        cwd: std::env::current_dir().unwrap_or_default(),
        shell: nighthawk_proto::Shell::detect_default(),
    };

    let req_json = serde_json::to_string(&req)?;

    #[cfg(unix)]
    {
        use std::os::unix::net::UnixStream;
        use std::time::Duration;

        let mut stream = UnixStream::connect(&*path_str)
            .map_err(|_| "Cannot connect to daemon. Is it running? Try: nh start")?;
        stream.set_read_timeout(Some(Duration::from_secs(2)))?;
        stream.set_write_timeout(Some(Duration::from_secs(1)))?;

        writeln!(stream, "{req_json}")?;

        let mut response = String::new();
        let mut reader = std::io::BufReader::new(&stream);
        std::io::BufRead::read_line(&mut reader, &mut response)?;

        let resp: nighthawk_proto::CompletionResponse = serde_json::from_str(response.trim())?;
        for s in &resp.suggestions {
            let desc = s.description.as_deref().unwrap_or("");
            println!(
                "  {} {}",
                s.text,
                if desc.is_empty() {
                    String::new()
                } else {
                    format!("— {desc}")
                }
            );
        }
        if resp.suggestions.is_empty() {
            println!("  (no suggestions)");
        }
    }

    #[cfg(windows)]
    {
        let mut file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&*path_str)
            .map_err(|_| "Cannot connect to daemon. Is it running? Try: nh start")?;

        writeln!(file, "{req_json}")?;

        let mut response = String::new();
        let mut reader = std::io::BufReader::new(&file);
        std::io::BufRead::read_line(&mut reader, &mut response)?;

        let resp: nighthawk_proto::CompletionResponse = serde_json::from_str(response.trim())?;
        for s in &resp.suggestions {
            let desc = s.description.as_deref().unwrap_or("");
            println!(
                "  {} {}",
                s.text,
                if desc.is_empty() {
                    String::new()
                } else {
                    format!("— {desc}")
                }
            );
        }
        if resp.suggestions.is_empty() {
            println!("  (no suggestions)");
        }
    }

    Ok(())
}
