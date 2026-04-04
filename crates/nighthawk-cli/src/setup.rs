use crate::paths;
use std::path::{Path, PathBuf};

/// Map shell name to plugin filename and rc file path.
fn shell_info(shell: &str) -> Result<(&str, PathBuf), String> {
    let home = dirs::home_dir().ok_or("Cannot determine home directory")?;
    match shell {
        "zsh" => Ok(("nighthawk.zsh", home.join(".zshrc"))),
        "bash" => Ok(("nighthawk.bash", home.join(".bashrc"))),
        "fish" => Ok((
            "nighthawk.fish",
            dirs::config_dir()
                .unwrap_or_else(|| home.join(".config"))
                .join("fish")
                .join("conf.d")
                .join("nighthawk.fish"),
        )),
        "powershell" | "pwsh" => {
            let docs = dirs::document_dir().unwrap_or_else(|| home.join("Documents"));
            Ok((
                "nighthawk.ps1",
                docs.join("PowerShell")
                    .join("Microsoft.PowerShell_profile.ps1"),
            ))
        }
        _ => Err(format!(
            "Unknown shell: {shell}\nSupported: zsh, bash, fish, powershell"
        )),
    }
}

/// Return the embedded shell plugin content for a given filename.
/// Plugins are compiled into the binary so setup works from anywhere.
fn plugin_content(filename: &str) -> Option<&'static str> {
    match filename {
        "nighthawk.zsh" => Some(include_str!("../../../shells/nighthawk.zsh")),
        "nighthawk.bash" => Some(include_str!("../../../shells/nighthawk.bash")),
        "nighthawk.fish" => Some(include_str!("../../../shells/nighthawk.fish")),
        "nighthawk.ps1" => Some(include_str!("../../../shells/nighthawk.ps1")),
        _ => None,
    }
}

/// Find the specs/ directory in the repo (for copying to config dir).
fn find_specs_dir() -> Option<PathBuf> {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            // Dev layout: target/debug/ → repo root specs/
            let repo_specs = dir.join("../../specs");
            if repo_specs.exists() {
                return Some(repo_specs);
            }
        }
    }
    None
}


/// Copy specs directory to config dir if not already populated.
fn ensure_specs(dest_specs_dir: &Path) -> Result<bool, Box<dyn std::error::Error>> {
    // If dest already has specs, skip
    if dest_specs_dir.exists() {
        let count = std::fs::read_dir(dest_specs_dir)?
            .filter_map(|e| e.ok())
            .filter(|e| {
                e.path()
                    .extension()
                    .map(|ext| ext == "json")
                    .unwrap_or(false)
            })
            .count();
        if count > 10 {
            return Ok(false); // Already populated
        }
    }

    let source = match find_specs_dir() {
        Some(d) => d,
        None => return Ok(false),
    };

    std::fs::create_dir_all(dest_specs_dir)?;

    let mut copied = 0;
    for entry in std::fs::read_dir(&source)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().map(|e| e == "json").unwrap_or(false) {
            let dest = dest_specs_dir.join(entry.file_name());
            std::fs::copy(&path, &dest)?;
            copied += 1;
        }
    }

    if copied > 0 {
        Ok(true)
    } else {
        Ok(false)
    }
}

/// Platform-appropriate binary names for nh and nighthawk-daemon.
fn binary_names() -> (&'static str, &'static str) {
    if cfg!(windows) {
        ("nh.exe", "nighthawk-daemon.exe")
    } else {
        ("nh", "nighthawk-daemon")
    }
}

/// Find all nighthawk binaries next to the current exe.
/// Returns (nh_path, daemon_path) if both exist.
fn find_own_binaries() -> Option<(PathBuf, PathBuf)> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    let (nh_name, daemon_name) = binary_names();
    let nh = dir.join(nh_name);
    let daemon = dir.join(daemon_name);
    if nh.exists() && daemon.exists() {
        Some((nh, daemon))
    } else {
        None
    }
}

/// Copy nighthawk binaries to the standard install directory.
/// Returns the install directory path, or None if binaries weren't found.
fn install_binaries() -> Result<Option<PathBuf>, Box<dyn std::error::Error>> {
    let (nh_src, daemon_src) = match find_own_binaries() {
        Some(pair) => pair,
        None => {
            eprintln!("Note: could not find binaries next to nh, skipping install to PATH");
            return Ok(None);
        }
    };

    let bin_dir = paths::bin_dir();

    // If we're already running from the install dir, skip the copy
    if let Ok(exe) = std::env::current_exe() {
        if let Ok(exe_canon) = exe.canonicalize() {
            if let Ok(bin_canon) = bin_dir.canonicalize() {
                if exe_canon.starts_with(&bin_canon) {
                    return Ok(Some(bin_dir));
                }
            }
        }
    }

    std::fs::create_dir_all(&bin_dir)?;

    let (nh_name, daemon_name) = binary_names();
    std::fs::copy(&nh_src, bin_dir.join(nh_name))?;
    std::fs::copy(&daemon_src, bin_dir.join(daemon_name))?;

    println!(
        "Installed binaries to {}",
        bin_dir.display()
    );

    Ok(Some(bin_dir))
}

/// Generate the PATH addition line for a given shell and directory.
fn path_line(shell: &str, bin_dir: &Path) -> String {
    let dir_str = bin_dir.to_string_lossy();
    match shell {
        "powershell" | "pwsh" => format!(
            "\n# nighthawk — add to PATH\n\
             if ($env:Path -notlike \"*{}*\") {{ $env:Path = \"{};$env:Path\" }}\n",
            dir_str, dir_str
        ),
        "fish" => format!(
            "\n# nighthawk — add to PATH\nfish_add_path \"{}\"\n",
            dir_str
        ),
        _ => format!(
            "\n# nighthawk — add to PATH\nexport PATH=\"{}:$PATH\"\n",
            dir_str
        ),
    }
}

pub fn setup_shell(shell: &str) -> Result<(), Box<dyn std::error::Error>> {
    let (plugin_filename, rc_path) =
        shell_info(shell).map_err(|e| -> Box<dyn std::error::Error> { e.into() })?;

    // 1. Write embedded plugin file
    let content = plugin_content(plugin_filename)
        .ok_or(format!("No embedded plugin for: {plugin_filename}"))?;

    let plugin_dest = paths::plugin_dir().join(plugin_filename);
    if let Some(parent) = plugin_dest.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&plugin_dest, content.replace("\r\n", "\n"))?;
    println!("Installed plugin to {}", plugin_dest.display());

    // 2. Copy specs if needed
    let specs_dest = paths::specs_dir();
    match ensure_specs(&specs_dest) {
        Ok(true) => println!("Copied specs to {}", specs_dest.display()),
        Ok(false) => {} // Already there or source not found
        Err(e) => eprintln!("Warning: could not copy specs: {e}"),
    }

    // 3. Install binaries to standard location
    let installed_bin_dir = match install_binaries() {
        Ok(dir) => dir,
        Err(e) => {
            eprintln!("Warning: could not install binaries: {e}");
            None
        }
    };

    // 4. Build rc file additions: source line + PATH line
    if shell == "fish" {
        // Fish uses conf.d — copying the file IS the plugin setup
        // But we still need PATH for the install dir
        if let Some(ref bin_dir) = installed_bin_dir {
            let fish_path_line = path_line("fish", bin_dir);
            let fish_conf_dir = dirs::config_dir()
                .unwrap_or_else(|| {
                    dirs::home_dir()
                        .unwrap_or_else(|| PathBuf::from("."))
                        .join(".config")
                })
                .join("fish")
                .join("conf.d");
            let path_conf = fish_conf_dir.join("nighthawk_path.fish");
            if !path_conf.exists() {
                std::fs::create_dir_all(&fish_conf_dir)?;
                std::fs::write(&path_conf, fish_path_line)?;
                println!("Added PATH config to {}", path_conf.display());
            }
        }
        println!("Fish plugin installed to {}", rc_path.display());
        return Ok(());
    }

    let source_line = if shell == "powershell" || shell == "pwsh" {
        format!(
            "\n# nighthawk — terminal autocomplete\n. \"{}\"\n",
            plugin_dest.display()
        )
    } else {
        format!(
            "\n# nighthawk — terminal autocomplete\nsource \"{}\"\n",
            plugin_dest.display()
        )
    };

    // Read rc file once to check existing config
    let rc_contents = if rc_path.exists() {
        std::fs::read_to_string(&rc_path).unwrap_or_default()
    } else {
        String::new()
    };

    let already_configured = rc_path.exists() && rc_contents.contains(plugin_filename);

    let needs_path = installed_bin_dir
        .as_ref()
        .is_some_and(|bin_dir| !rc_contents.contains(&bin_dir.to_string_lossy().to_string()));

    if already_configured && !needs_path {
        println!("Already configured in {}", rc_path.display());
        return Ok(());
    }

    // Ensure parent directory exists (e.g. Documents/PowerShell/ on fresh systems)
    if let Some(parent) = rc_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&rc_path)?;

    if !already_configured {
        std::io::Write::write_all(&mut file, source_line.as_bytes())?;
    }

    if needs_path {
        if let Some(ref bin_dir) = installed_bin_dir {
            let pl = path_line(shell, bin_dir);
            std::io::Write::write_all(&mut file, pl.as_bytes())?;
        }
    }

    if already_configured {
        println!("Added PATH to {}", rc_path.display());
    } else {
        println!("Added to {}", rc_path.display());
    }

    // Start the daemon so it's ready when the user opens a new shell
    match crate::daemon_ctl::start() {
        Ok(()) => {}
        Err(e) => eprintln!("Warning: could not start daemon: {e}"),
    }

    println!("\nRestart your shell to activate nighthawk.");

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn powershell_shell_info_returns_ps1_plugin() {
        let (filename, _) = shell_info("powershell").unwrap();
        assert_eq!(filename, "nighthawk.ps1");
    }

    #[test]
    fn pwsh_shell_info_returns_ps1_plugin() {
        let (filename, _) = shell_info("pwsh").unwrap();
        assert_eq!(filename, "nighthawk.ps1");
    }

    #[test]
    fn powershell_and_pwsh_return_same_result() {
        let (file1, path1) = shell_info("powershell").unwrap();
        let (file2, path2) = shell_info("pwsh").unwrap();
        assert_eq!(file1, file2);
        assert_eq!(path1, path2);
    }

    #[test]
    fn powershell_profile_path_ends_correctly() {
        let (_, path) = shell_info("powershell").unwrap();
        let path_str = path.to_string_lossy();
        assert!(
            path_str.contains("PowerShell")
                && path_str.contains("Microsoft.PowerShell_profile.ps1"),
            "Unexpected profile path: {path_str}"
        );
    }

    #[test]
    fn powershell_source_line_uses_dot_source() {
        let plugin_path = PathBuf::from(r"C:\Users\test\nighthawk.ps1");
        let source_line = format!(
            "\n# nighthawk — terminal autocomplete\n. \"{}\"\n",
            plugin_path.display()
        );
        assert!(source_line.contains(". \""), "Should use dot-source syntax");
        assert!(
            !source_line.contains("source "),
            "Should not use bash source syntax"
        );
    }

    #[test]
    fn unknown_shell_returns_error() {
        assert!(shell_info("nushell_unknown").is_err());
    }

    #[test]
    fn zsh_still_works() {
        let (filename, _) = shell_info("zsh").unwrap();
        assert_eq!(filename, "nighthawk.zsh");
    }

    // --- PATH line tests ---

    #[test]
    fn path_line_zsh_exports_path() {
        let line = path_line("zsh", Path::new("/home/user/.local/bin"));
        assert!(line.contains("export PATH=\"/home/user/.local/bin:$PATH\""));
    }

    #[test]
    fn path_line_bash_exports_path() {
        let line = path_line("bash", Path::new("/home/user/.local/bin"));
        assert!(line.contains("export PATH=\"/home/user/.local/bin:$PATH\""));
    }

    #[test]
    fn path_line_powershell_uses_env_path() {
        let line = path_line("powershell", Path::new(r"C:\Users\test\AppData\Local\Programs\nighthawk"));
        assert!(line.contains("$env:Path"));
        assert!(line.contains("-notlike"));
    }

    #[test]
    fn path_line_pwsh_same_as_powershell() {
        let dir = Path::new("/some/dir");
        assert_eq!(path_line("pwsh", dir), path_line("powershell", dir));
    }

    #[test]
    fn path_line_fish_uses_fish_add_path() {
        let line = path_line("fish", Path::new("/home/user/.local/bin"));
        assert!(line.contains("fish_add_path"));
    }

    #[test]
    fn bin_dir_returns_valid_path() {
        let dir = paths::bin_dir();
        let dir_str = dir.to_string_lossy();
        if cfg!(windows) {
            assert!(dir_str.contains("Programs") && dir_str.contains("nighthawk"),
                "Expected Windows install path, got: {dir_str}");
        } else {
            assert!(dir_str.contains(".local") && dir_str.contains("bin"),
                "Expected Unix install path, got: {dir_str}");
        }
    }
}
