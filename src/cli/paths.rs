use std::path::PathBuf;

pub fn config_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("nighthawk")
}

pub fn pid_file() -> PathBuf {
    config_dir().join("nighthawk.pid")
}

pub fn log_file() -> PathBuf {
    config_dir().join("daemon.log")
}

pub fn specs_dir() -> PathBuf {
    std::env::var("NIGHTHAWK_SPECS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| config_dir().join("specs"))
}

pub fn plugin_dir() -> PathBuf {
    config_dir()
}

/// Check if any shell plugin is installed in the config directory.
/// Returns true if config_dir is invalid (fallback to ".") to avoid false positive hints.
pub fn has_any_plugin() -> bool {
    let dir = config_dir();
    // If config_dir fell back to ".", don't trust it
    if dir == PathBuf::from(".") {
        return true; // Assume setup done, avoid false positive hints
    }
    dir.join("nighthawk.zsh").exists() || dir.join("nighthawk.ps1").exists()
}

/// Standard install directory for nighthawk binaries.
/// Windows: %LOCALAPPDATA%\Programs\nighthawk\
/// Unix: ~/.local/bin/
pub fn bin_dir() -> PathBuf {
    #[cfg(windows)]
    {
        dirs::data_local_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("Programs")
            .join("nighthawk")
    }
    #[cfg(not(windows))]
    {
        dirs::home_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join(".local")
            .join("bin")
    }
}
