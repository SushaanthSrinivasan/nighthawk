use super::paths;
use crate::proto::{DetectionSource, Shell};
use dialoguer::{Confirm, Select};
use std::io::IsTerminal;
use std::path::{Path, PathBuf};

/// Every shell the setup flow can install, in menu order.
/// `(menu label, setup id)` — the id is exactly what `setup_shell` / `shell_info` accept.
/// Single source of truth: the wizard menu and the `shell_info` error both derive from this.
const SETUP_TARGETS: &[(&str, &str)] = &[
    ("zsh", "zsh"),
    ("bash", "bash"),
    ("fish", "fish"),
    ("Windows PowerShell 5.1", "powershell"),
    ("PowerShell 7+ (pwsh)", "pwsh"),
];

/// Supported setup ids joined by `sep`, for usage/error messages
/// (e.g. `"|"` for `<a|b|c>` usage, `", "` for prose).
fn supported_shells(sep: &str) -> String {
    SETUP_TARGETS
        .iter()
        .map(|(_, id)| *id)
        .collect::<Vec<_>>()
        .join(sep)
}

/// Index of a setup id within `SETUP_TARGETS` (its menu position), if present.
fn target_index(id: &str) -> Option<usize> {
    SETUP_TARGETS.iter().position(|(_, t)| *t == id)
}

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
        "powershell" => {
            // Windows PowerShell 5.1 uses Documents\WindowsPowerShell\
            let docs = dirs::document_dir().unwrap_or_else(|| home.join("Documents"));
            Ok((
                "nighthawk.ps1",
                docs.join("WindowsPowerShell")
                    .join("Microsoft.PowerShell_profile.ps1"),
            ))
        }
        "pwsh" => {
            // PowerShell 7+ uses Documents\PowerShell\
            let docs = dirs::document_dir().unwrap_or_else(|| home.join("Documents"));
            Ok((
                "nighthawk.ps1",
                docs.join("PowerShell")
                    .join("Microsoft.PowerShell_profile.ps1"),
            ))
        }
        _ => Err(format!(
            "Unknown shell: {shell}\nSupported: {}",
            supported_shells(", ")
        )),
    }
}

/// Return the embedded shell plugin content for a given filename.
/// Plugins are compiled into the binary so setup works from anywhere.
fn plugin_content(filename: &str) -> Option<&'static str> {
    match filename {
        "nighthawk.zsh" => Some(include_str!("../../shells/nighthawk.zsh")),
        "nighthawk.bash" => Some(include_str!("../../shells/nighthawk.bash")),
        "nighthawk.fish" => Some(include_str!("../../shells/nighthawk.fish")),
        "nighthawk.ps1" => Some(include_str!("../../shells/nighthawk.ps1")),
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

/// Extract embedded specs or copy from dev layout as fallback.
fn ensure_specs(dest_specs_dir: &Path) -> Result<bool, Box<dyn std::error::Error>> {
    // Try embedded specs first (works after cargo install)
    match super::embedded_specs::extract_specs(dest_specs_dir) {
        Ok(super::embedded_specs::ExtractResult::Extracted { .. }) => {
            return Ok(true);
        }
        Ok(super::embedded_specs::ExtractResult::AlreadyCurrent) => {
            return Ok(false);
        }
        Ok(super::embedded_specs::ExtractResult::NoEmbeddedSpecs) => {
            // Fall through to dev-layout fallback
        }
        Err(e) => {
            eprintln!("Warning: could not extract embedded specs: {e}");
            // Fall through to dev-layout fallback
        }
    }

    // Dev-layout fallback: copy from repo specs/ directory
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

/// Default config.toml content with documented options.
const DEFAULT_CONFIG: &str = r#"# nighthawk configuration
# See: https://github.com/SushaanthSrinivasan/nighthawk

[daemon]
# log_level = "info"          # trace, debug, info, warn, error

[tiers]
# enable_history = true       # Tier 0: shell history prefix match
# enable_specs = true         # Tier 1: CLI spec lookup
# enable_local_llm = false    # Tier 2: local LLM (requires --features local-llm)
# enable_cloud = false        # Tier 3: cloud API (not yet implemented)

# Uncomment and configure to enable local LLM completions.
# Requires: cargo install nighthawk --features local-llm
# [local_llm]
# endpoint = "http://localhost:11434/v1"  # ollama default
# model = "qwen2.5-coder:1.5b"
# budget_ms = 500
# temperature = 0.0
# max_tokens = 64
"#;

/// Create a default config.toml if one doesn't exist yet.
fn ensure_config() -> Result<bool, Box<dyn std::error::Error>> {
    let config_path = paths::config_dir().join("config.toml");
    if config_path.exists() {
        return Ok(false);
    }
    if let Some(parent) = config_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&config_path, DEFAULT_CONFIG)?;
    Ok(true)
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

    println!("Installed binaries to {}", bin_dir.display());

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
        Ok(true) => println!("Installed specs to {}", specs_dest.display()),
        Ok(false) => {} // Already there or source not found
        Err(e) => eprintln!("Warning: could not copy specs: {e}"),
    }

    // 3. Create default config.toml if missing
    match ensure_config() {
        Ok(true) => println!(
            "Created config at {}",
            paths::config_dir().join("config.toml").display()
        ),
        Ok(false) => {} // Already exists
        Err(e) => eprintln!("Warning: could not create config: {e}"),
    }

    // 4. Install binaries to standard location
    let installed_bin_dir = match install_binaries() {
        Ok(dir) => dir,
        Err(e) => {
            eprintln!("Warning: could not install binaries: {e}");
            None
        }
    };

    // 4. Build rc file additions: source line + PATH line
    if shell == "fish" {
        // Fish auto-sources every *.fish in ~/.config/fish/conf.d, so the plugin
        // must live THERE — not just in config_dir like the step-1 copy. `rc_path`
        // (from shell_info) already points at conf.d/nighthawk.fish; write the
        // plugin to it so fish actually loads it on startup.
        if let Some(conf_dir) = rc_path.parent() {
            std::fs::create_dir_all(conf_dir)?;

            std::fs::write(&rc_path, content.replace("\r\n", "\n"))?;
            println!("Installed fish plugin to {}", rc_path.display());

            // Drop a PATH entry for the install dir alongside it.
            if let Some(ref bin_dir) = installed_bin_dir {
                let path_conf = conf_dir.join("nighthawk_path.fish");
                if !path_conf.exists() {
                    std::fs::write(&path_conf, path_line("fish", bin_dir))?;
                    println!("Added PATH config to {}", path_conf.display());
                }
            }
        }

        // Start the daemon so it's ready when the user opens a new shell.
        if let Err(e) = super::daemon_ctl::start() {
            eprintln!("Warning: could not start daemon: {e}");
        }

        println!("\nRestart your shell to activate nighthawk.");
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
    match super::daemon_ctl::start() {
        Ok(()) => {}
        Err(e) => eprintln!("Warning: could not start daemon: {e}"),
    }

    println!("\nRestart your shell to activate nighthawk.");

    Ok(())
}

/// Map a detected shell to its setup id, or `None` when the wizard must ask.
///
/// `PowerShell` → `None`: the `Shell` enum collapses Windows PowerShell 5.1 and
/// PowerShell 7 into one variant, but they install to different profiles, so the
/// user must disambiguate. `Nushell` → `None`: not a supported setup target.
fn detected_target(shell: Shell) -> Option<&'static str> {
    match shell {
        Shell::PowerShell | Shell::Nushell => None,
        other => Some(other.as_str()),
    }
}

/// Interactive `nh setup` (invoked with no shell argument).
///
/// Detects the current shell, confirms with the user, and delegates the actual
/// install to [`setup_shell`]. `nh setup <shell>` remains the non-interactive path.
pub fn setup_wizard() -> Result<(), Box<dyn std::error::Error>> {
    // 0. Explicit NIGHTHAWK_SHELL override — honored verbatim, no prompt.
    //    Passed as a raw string (not via the Shell enum) so the powershell(5.1)
    //    vs pwsh(7) distinction survives; other aliases (sh, bash-5.2) are
    //    normalized the same way detection does.
    if let Ok(raw) = std::env::var("NIGHTHAWK_SHELL") {
        let t = raw.trim().to_lowercase();
        if !t.is_empty() {
            let id = match t.as_str() {
                "powershell" | "pwsh" => Some(t.clone()),
                other => other.parse::<Shell>().ok().map(|s| s.as_str().to_string()),
            };
            // Only honor the override verbatim if it names an installable target.
            if let Some(id) = id.filter(|id| target_index(id).is_some()) {
                return setup_shell(&id);
            }
            // Unparseable (e.g. "ksh") or unsupported (e.g. "nu" → nushell): fall
            // through to detection + menu, matching the lenient behavior of
            // Shell::detect_* rather than dead-ending on a misleading error.
        }
    }

    // 1. Detect the shell and how we know it.
    let (shell, source) = Shell::detect_default_with_source();
    let target = detected_target(shell);

    // 2. Only a *current-shell* signal is confident enough to auto-run / skip the
    //    menu. $SHELL (login shell) and the platform default are not.
    let confident = matches!(
        source,
        DetectionSource::ParentProcess | DetectionSource::VersionVar
    );

    // 3. dialoguer renders to stderr and reads keys from the tty, so require both
    //    stdin and stderr to be terminals before prompting.
    let interactive = std::io::stdin().is_terminal() && std::io::stderr().is_terminal();

    if !interactive {
        return match (confident, target) {
            (true, Some(id)) => setup_shell(id),
            _ => Err(format!(
                "Could not confidently detect your shell in a non-interactive session.\n\
                 Re-run with an explicit shell: nh setup <{}>\n\
                 or set the NIGHTHAWK_SHELL environment variable.",
                supported_shells("|")
            )
            .into()),
        };
    }

    // 4. Interactive + confident: confirm the detected shell (Enter = yes).
    if let (true, Some(id)) = (confident, target) {
        match Confirm::new()
            .with_prompt(format!("Detected {id}. Is this correct?"))
            .default(true)
            .interact_opt()?
        {
            Some(true) => return setup_shell(id),
            Some(false) => {} // fall through to the menu
            None => {
                println!("Setup cancelled.");
                return Ok(());
            }
        }
    }

    // 5. Menu. Pre-select the detected target, else a platform-appropriate default
    //    (powershell on Windows, zsh on Unix) — never preselect zsh on Windows.
    let fallback = if cfg!(windows) { "powershell" } else { "zsh" };
    let default_idx = target
        .and_then(target_index)
        .or_else(|| target_index(fallback))
        .unwrap_or(0);

    let labels: Vec<&str> = SETUP_TARGETS.iter().map(|(label, _)| *label).collect();
    match Select::new()
        .with_prompt("Select your shell")
        .items(&labels)
        .default(default_idx)
        .interact_opt()?
    {
        Some(i) => setup_shell(SETUP_TARGETS[i].1),
        None => {
            println!("Setup cancelled.");
            Ok(())
        }
    }
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
    fn powershell_and_pwsh_use_same_plugin_file() {
        let (file1, _) = shell_info("powershell").unwrap();
        let (file2, _) = shell_info("pwsh").unwrap();
        assert_eq!(file1, file2);
    }

    #[test]
    fn powershell_and_pwsh_use_different_profile_dirs() {
        let (_, ps51_path) = shell_info("powershell").unwrap();
        let (_, pwsh_path) = shell_info("pwsh").unwrap();
        let ps51_str = ps51_path.to_string_lossy();
        let pwsh_str = pwsh_path.to_string_lossy();
        assert!(
            ps51_str.contains("WindowsPowerShell"),
            "PS 5.1 should use WindowsPowerShell, got: {ps51_str}"
        );
        assert!(
            pwsh_str.contains("PowerShell") && !pwsh_str.contains("WindowsPowerShell"),
            "pwsh should use PowerShell (not WindowsPowerShell), got: {pwsh_str}"
        );
    }

    #[test]
    fn powershell_profile_path_ends_correctly() {
        let (_, path) = shell_info("powershell").unwrap();
        let path_str = path.to_string_lossy();
        assert!(
            path_str.contains("WindowsPowerShell")
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
        let line = path_line(
            "powershell",
            Path::new(r"C:\Users\test\AppData\Local\Programs\nighthawk"),
        );
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
            assert!(
                dir_str.contains("Programs") && dir_str.contains("nighthawk"),
                "Expected Windows install path, got: {dir_str}"
            );
        } else {
            assert!(
                dir_str.contains(".local") && dir_str.contains("bin"),
                "Expected Unix install path, got: {dir_str}"
            );
        }
    }

    // --- Wizard / setup-target tests (issue #37) ---

    #[test]
    fn detected_target_maps_plain_shells_to_ids() {
        assert_eq!(detected_target(Shell::Zsh), Some("zsh"));
        assert_eq!(detected_target(Shell::Bash), Some("bash"));
        assert_eq!(detected_target(Shell::Fish), Some("fish"));
    }

    #[test]
    fn detected_target_powershell_is_none() {
        // 5.1 vs 7 is ambiguous from the enum — the wizard must ask.
        assert_eq!(detected_target(Shell::PowerShell), None);
    }

    #[test]
    fn detected_target_nushell_is_none() {
        // Nushell is not a supported setup target.
        assert_eq!(detected_target(Shell::Nushell), None);
    }

    #[test]
    fn setup_targets_ids_are_accepted_by_shell_info() {
        // Every id the wizard can offer must be installable.
        for (_, id) in SETUP_TARGETS {
            assert!(
                shell_info(id).is_ok(),
                "SETUP_TARGETS id {id:?} rejected by shell_info"
            );
        }
    }

    #[test]
    fn detected_target_ids_are_valid_setup_targets() {
        for shell in [Shell::Zsh, Shell::Bash, Shell::Fish] {
            let id = detected_target(shell).unwrap();
            assert!(
                SETUP_TARGETS.iter().any(|(_, t)| *t == id),
                "{id:?} not in SETUP_TARGETS"
            );
        }
    }

    #[test]
    fn shell_info_error_lists_pwsh() {
        // Regression: the supported-shells error must include pwsh (was stale).
        let err = shell_info("definitely_not_a_shell").unwrap_err();
        assert!(err.contains("pwsh"), "error should list pwsh: {err}");
    }

    #[test]
    fn platform_default_menu_index_is_sensible() {
        // The menu fallback must never preselect zsh on Windows.
        let fallback = if cfg!(windows) { "powershell" } else { "zsh" };
        let idx = target_index(fallback).unwrap();
        assert_eq!(SETUP_TARGETS[idx].1, fallback);
    }

    #[test]
    fn target_index_finds_known_and_rejects_unknown() {
        assert_eq!(target_index("zsh"), Some(0));
        assert_eq!(target_index("pwsh"), Some(SETUP_TARGETS.len() - 1));
        assert_eq!(target_index("nushell"), None);
        assert_eq!(target_index("ksh"), None);
    }

    #[test]
    fn override_filter_rejects_nushell_so_it_falls_through() {
        // Step-0 honors an override only when it names an installable target.
        // "nu" normalizes to "nushell", which is NOT a target, so the wizard
        // must fall through to the menu rather than dead-end on setup_shell.
        let normalized = "nu".parse::<Shell>().unwrap().as_str(); // "nushell"
        assert!(
            target_index(normalized).is_none(),
            "nushell must not be an installable target"
        );
    }

    #[test]
    fn supported_shells_joins_with_separator() {
        assert_eq!(supported_shells("|"), "zsh|bash|fish|powershell|pwsh");
        assert!(supported_shells(", ").contains("pwsh"));
    }
}
