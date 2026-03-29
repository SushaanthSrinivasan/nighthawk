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
            // PowerShell profile path varies; just print instructions
            Err("PowerShell setup: add this to your $PROFILE:\n  . ~/.config/nighthawk/nighthawk.ps1".into())
        }
        _ => Err(format!(
            "Unknown shell: {shell}\nSupported: zsh, bash, fish, powershell"
        )),
    }
}

/// Find the shells/ directory (next to the binary, or in the repo).
fn find_shells_dir() -> Option<PathBuf> {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            // Installed layout: {bin_dir}/../share/nighthawk/shells/
            let share = dir.join("../share/nighthawk/shells");
            if share.exists() {
                return Some(share);
            }

            // Dev layout: binary is in target/debug/, shells/ is at repo root
            // Go up from target/debug/ to repo root
            let repo_root = dir.join("../../shells");
            if repo_root.exists() {
                return Some(repo_root);
            }
        }
    }
    None
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

/// Copy a file, creating parent dirs as needed.
/// Normalizes line endings to LF so shell plugins work on Linux/macOS
/// even when copied from a Windows checkout.
fn copy_file(src: &Path, dst: &Path) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(parent) = dst.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let content = std::fs::read_to_string(src)?;
    let normalized = content.replace("\r\n", "\n");
    std::fs::write(dst, normalized)?;
    Ok(())
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

pub fn setup_shell(shell: &str) -> Result<(), Box<dyn std::error::Error>> {
    let (plugin_filename, rc_path) =
        shell_info(shell).map_err(|e| -> Box<dyn std::error::Error> { e.into() })?;

    // 1. Find and copy plugin file
    let shells_dir = find_shells_dir().ok_or(
        "Cannot find shell plugins directory. Make sure nighthawk is installed or run from the repo.",
    )?;

    let plugin_src = shells_dir.join(plugin_filename);
    if !plugin_src.exists() {
        return Err(format!("Plugin file not found: {}", plugin_src.display()).into());
    }

    let plugin_dest = paths::plugin_dir().join(plugin_filename);
    copy_file(&plugin_src, &plugin_dest)?;
    println!("Copied plugin to {}", plugin_dest.display());

    // 2. Copy specs if needed
    let specs_dest = paths::specs_dir();
    match ensure_specs(&specs_dest) {
        Ok(true) => println!("Copied specs to {}", specs_dest.display()),
        Ok(false) => {} // Already there or source not found
        Err(e) => eprintln!("Warning: could not copy specs: {e}"),
    }

    // 3. Add source line to rc file
    let source_line = if shell == "fish" {
        // Fish uses conf.d — just copying the file IS the setup
        println!("Fish plugin installed to {}", rc_path.display());
        return Ok(());
    } else {
        format!(
            "\n# nighthawk — terminal autocomplete\nsource \"{}\"\n",
            plugin_dest.display()
        )
    };

    if rc_path.exists() {
        let contents = std::fs::read_to_string(&rc_path)?;
        if contents.contains(plugin_filename) {
            println!("Already configured in {}", rc_path.display());
            return Ok(());
        }
    }

    // Append source line
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&rc_path)?;
    std::io::Write::write_all(&mut file, source_line.as_bytes())?;

    println!("Added to {}", rc_path.display());
    println!("\nRestart your shell or run:");
    println!("  source {}", rc_path.display());

    Ok(())
}
