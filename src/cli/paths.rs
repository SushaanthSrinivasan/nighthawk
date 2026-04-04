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
