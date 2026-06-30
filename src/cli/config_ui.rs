//! `nh config` — interactive settings editor + non-interactive `get`/`set`.
//!
//! There are two config surfaces in nighthawk, both living in
//! `~/.config/nighthawk/config.toml`:
//!   - **Daemon** settings (`[daemon]`, `[tiers]`, `[local_llm]`, `[cloud]`) —
//!     deserialized by `src/daemon/config.rs` via serde.
//!   - **Plugin** settings (`[plugin]`) — read by the four shell plugins'
//!     hand-rolled parsers (shells/nighthawk.{zsh,bash,fish,ps1}); the daemon
//!     ignores this section entirely.
//!
//! The [`SECTIONS`] field registry below is the single source of truth for the
//! editor: it drives the interactive menu, `get`/`set`, and validation. The
//! `default_hint`s here MUST stay in sync with the authoritative `Default` impls
//! in `src/daemon/config.rs` (and the four shell-plugin defaults for `[plugin]`);
//! there is no compiler check tying them together, so update both together.

use super::paths;
use console::{Key, Term};
use dialoguer::Select;
use std::error::Error;
use std::io::{IsTerminal, Write};
use std::path::PathBuf;
use tempfile::NamedTempFile;
use toml_edit::{value, DocumentMut, Item, Table};

/// What a setting accepts — drives validation and how the interactive editor
/// prompts for it (`Select` for `Bool`/`Enum`, free text for the rest).
#[derive(Clone, Copy)]
enum FieldKind {
    Bool,
    /// Fixed set of allowed string values. MUST match the serde wire format
    /// (e.g. `CloudProvider` is `rename_all = "lowercase"`, so `"openai"` not
    /// `"OpenAI"`) — a mismatch writes valid TOML that the daemon then rejects,
    /// silently falling back to `Config::default()`.
    Enum(&'static [&'static str]),
    /// Free-form string (non-empty).
    Str,
    /// Non-negative integer that fits in u32.
    UInt,
    /// Floating point.
    Float,
}

/// A single editable setting. `section` + `key` address it in the TOML document.
struct Field {
    section: &'static str,
    key: &'static str,
    /// Menu label. Carries applicability notes that aren't about defaults
    /// (e.g. `tab_accept` is bash/fish-only).
    label: &'static str,
    kind: FieldKind,
    /// Mask the value in the interactive list (API keys). `get` still prints the
    /// real value so it stays scriptable.
    masked: bool,
    /// The default the daemon/plugins use when the key is absent, for display.
    /// `None` for keys with no single shared default (`hint_arrow` is
    /// shell-dependent; `cloud.api_key`/`model`/`base_url` are provider/env-derived).
    default_hint: Option<&'static str>,
}

const LOG_LEVELS: &[&str] = &["trace", "debug", "info", "warn", "error"];
const PROVIDERS: &[&str] = &["openai", "anthropic", "groq"];

/// The registry. Order here is the menu order.
#[rustfmt::skip]
const SECTIONS: &[(&str, &[Field])] = &[
    ("daemon", &[
        Field { section: "daemon", key: "log_level", label: "log_level", kind: FieldKind::Enum(LOG_LEVELS), masked: false, default_hint: Some("info") },
    ]),
    ("tiers", &[
        Field { section: "tiers", key: "enable_history",   label: "enable_history",   kind: FieldKind::Bool, masked: false, default_hint: Some("true") },
        Field { section: "tiers", key: "enable_specs",     label: "enable_specs",     kind: FieldKind::Bool, masked: false, default_hint: Some("true") },
        Field { section: "tiers", key: "enable_local_llm", label: "enable_local_llm", kind: FieldKind::Bool, masked: false, default_hint: Some("false") },
        Field { section: "tiers", key: "enable_cloud",     label: "enable_cloud",     kind: FieldKind::Bool, masked: false, default_hint: Some("false") },
    ]),
    ("local_llm", &[
        Field { section: "local_llm", key: "endpoint",    label: "endpoint",    kind: FieldKind::Str,   masked: false, default_hint: Some("http://localhost:11434/v1") },
        Field { section: "local_llm", key: "model",       label: "model",       kind: FieldKind::Str,   masked: false, default_hint: Some("qwen2.5-coder:1.5b") },
        Field { section: "local_llm", key: "budget_ms",   label: "budget_ms",   kind: FieldKind::UInt,  masked: false, default_hint: Some("500") },
        Field { section: "local_llm", key: "temperature", label: "temperature", kind: FieldKind::Float, masked: false, default_hint: Some("0.0") },
        Field { section: "local_llm", key: "max_tokens",  label: "max_tokens",  kind: FieldKind::UInt,  masked: false, default_hint: Some("64") },
    ]),
    ("cloud", &[
        Field { section: "cloud", key: "provider",             label: "provider",                          kind: FieldKind::Enum(PROVIDERS), masked: false, default_hint: Some("openai") },
        Field { section: "cloud", key: "api_key",              label: "api_key (else OPENAI/ANTHROPIC/GROQ_API_KEY env)", kind: FieldKind::Str, masked: true,  default_hint: None },
        Field { section: "cloud", key: "model",                label: "model (provider default if unset)", kind: FieldKind::Str,   masked: false, default_hint: None },
        Field { section: "cloud", key: "base_url",             label: "base_url (provider default if unset)", kind: FieldKind::Str, masked: false, default_hint: None },
        Field { section: "cloud", key: "budget_ms",            label: "budget_ms",            kind: FieldKind::UInt,  masked: false, default_hint: Some("2000") },
        Field { section: "cloud", key: "temperature",          label: "temperature",          kind: FieldKind::Float, masked: false, default_hint: Some("0.2") },
        Field { section: "cloud", key: "max_tokens",           label: "max_tokens",           kind: FieldKind::UInt,  masked: false, default_hint: Some("150") },
        Field { section: "cloud", key: "history_context_size", label: "history_context_size", kind: FieldKind::UInt,  masked: false, default_hint: Some("10") },
    ]),
    ("plugin", &[
        Field { section: "plugin", key: "hint_arrow",  label: "hint_arrow",              kind: FieldKind::Str,  masked: false, default_hint: None },
        Field { section: "plugin", key: "debounce_ms", label: "debounce_ms",             kind: FieldKind::UInt, masked: false, default_hint: Some("200") },
        Field { section: "plugin", key: "debug",       label: "debug",                   kind: FieldKind::Bool, masked: false, default_hint: Some("false") },
        Field { section: "plugin", key: "tab_accept",  label: "tab_accept (bash/fish only)", kind: FieldKind::Bool, masked: false, default_hint: Some("false") },
    ]),
];

/// Sections consumed by the daemon (read once at startup, no live reload), so a
/// change needs a daemon restart. `[plugin]` is read fresh by each new shell.
fn is_daemon_section(section: &str) -> bool {
    // `[plugin]` is the only section read by the shells rather than the daemon;
    // everything else is daemon-owned. Phrasing it as the complement keeps this
    // from drifting when a new daemon section is added to the registry.
    section != "plugin"
}

/// Resolve a `section.key` string to its registry entry.
fn find_field(dotted: &str) -> Option<&'static Field> {
    let (section, key) = dotted.split_once('.')?;
    SECTIONS
        .iter()
        .find(|(s, _)| *s == section)
        .and_then(|(_, fields)| fields.iter().find(|f| f.key == key))
}

/// Build the "unknown key" error, listing every valid `section.key`.
fn unknown_key_msg(dotted: &str) -> String {
    let mut keys = Vec::new();
    for (section, fields) in SECTIONS {
        for f in *fields {
            keys.push(format!("{section}.{}", f.key));
        }
    }
    format!(
        "unknown key '{dotted}'\nValid keys:\n  {}",
        keys.join("\n  ")
    )
}

/// Validate `raw` against `field`'s kind and produce the typed TOML item to
/// write. Rejects (with a human message) anything the daemon would choke on:
/// negatives/floats/overflow for `UInt`, out-of-range temperature, wrong-case
/// enum tokens, and `hint_arrow` values the shells' double-quoted-only regex
/// can't parse (embedded quote / backslash / control char).
fn parse_item(field: &Field, raw: &str) -> Result<Item, String> {
    let v = raw.trim();
    match field.kind {
        FieldKind::Bool => match v {
            "true" => Ok(value(true)),
            "false" => Ok(value(false)),
            _ => Err(format!("expected `true` or `false`, got '{v}'")),
        },
        FieldKind::Enum(opts) => {
            if opts.contains(&v) {
                Ok(value(v))
            } else {
                Err(format!("expected one of [{}], got '{v}'", opts.join(", ")))
            }
        }
        FieldKind::UInt => match v.parse::<u32>() {
            Ok(n) => Ok(value(n as i64)),
            Err(_) => Err(format!(
                "expected a non-negative integer (0..={}), got '{v}'",
                u32::MAX
            )),
        },
        // Parse and store as f64 so the user's decimal round-trips cleanly.
        // Casting an f32 to f64 would surface the f32 rounding error in the file
        // (e.g. 0.3 -> 0.30000001192092896); the daemon reads temperature as f32
        // and coerces the f64 back down on load.
        FieldKind::Float => match v.parse::<f64>() {
            Ok(f) => {
                // `parse::<f64>()` accepts "inf"/"nan"; reject them for every float
                // so a non-finite value can never reach the daemon (the range check
                // below only guards `temperature`).
                if !f.is_finite() {
                    return Err(format!("expected a finite number, got '{v}'"));
                }
                if field.key == "temperature" && !(0.0..=2.0).contains(&f) {
                    return Err(format!("temperature must be in 0.0..=2.0, got {f}"));
                }
                Ok(value(f))
            }
            Err(_) => Err(format!("expected a number, got '{v}'")),
        },
        FieldKind::Str => {
            if v.is_empty() {
                return Err("value cannot be empty".into());
            }
            // The shell plugins parse hint_arrow with a double-quoted-only regex
            // (`"([^"]*)"`) that has no escape handling, so a quote/backslash that
            // toml_edit writes correctly would be mis-captured, and a control char
            // could corrupt the rendered prompt. Reject those here.
            if field.key == "hint_arrow"
                && (v.contains('"') || v.contains('\\') || v.chars().any(|c| c.is_control()))
            {
                return Err(
                    "hint_arrow cannot contain quotes, backslashes, or control characters".into(),
                );
            }
            Ok(value(v))
        }
    }
}

/// Validate `raw` for `field` and write the typed value into `doc`.
///
/// Ensures the section is a real (explicit) table so a `[section]` header is
/// emitted. This matters most for `[plugin]`: the shells detect the section by a
/// literal header line, so a freshly-created or previously-dotted table rendered
/// as `plugin.key = ...` dotted keys (no header) would be silently invisible to
/// every plugin. `set_implicit(false)` forces the header on every write.
fn apply_to_doc(doc: &mut DocumentMut, field: &Field, raw: &str) -> Result<(), String> {
    let item = parse_item(field, raw)?;
    if !doc.get(field.section).map(Item::is_table).unwrap_or(false) {
        doc[field.section] = Item::Table(Table::new());
    }
    if let Some(table) = doc[field.section].as_table_mut() {
        // `set_implicit(false)` forces a header for an otherwise-empty/implicit
        // table; `set_dotted(false)` un-does the `plugin.key = ...` dotted display
        // that toml_edit uses for a section parsed from (or created as) dotted keys.
        // Both are needed so a real `[section]` header is always emitted.
        table.set_implicit(false);
        table.set_dotted(false);
        table[field.key] = item;
    }
    Ok(())
}

/// Render a TOML item as a plain display string (no quotes/decoration).
fn render_value(item: &Item) -> String {
    if let Some(s) = item.as_str() {
        s.to_string()
    } else if let Some(b) = item.as_bool() {
        b.to_string()
    } else if let Some(i) = item.as_integer() {
        i.to_string()
    } else if let Some(f) = item.as_float() {
        f.to_string()
    } else {
        item.to_string().trim().to_string()
    }
}

/// Mask a secret for display: `…` plus the last 4 chars (all dots if very short).
fn mask(s: &str) -> String {
    let n = s.chars().count();
    if n <= 4 {
        "•".repeat(n)
    } else {
        let last4: String = s.chars().skip(n - 4).collect();
        format!("…{last4}")
    }
}

/// A loaded `config.toml`, edited in place and written back atomically while
/// preserving comments.
struct ConfigDocument {
    doc: DocumentMut,
    path: PathBuf,
}

impl ConfigDocument {
    /// Load the config document. A missing file yields an empty document (every
    /// key reads as its default). A *present but unparseable* file is a hard
    /// error — we refuse to write rather than clobber a recoverable file (unlike
    /// the daemon's `load_config`, which silently falls back to defaults).
    fn load() -> Result<Self, String> {
        let path = paths::config_dir().join("config.toml");
        let doc = match std::fs::read_to_string(&path) {
            Ok(text) => text.parse::<DocumentMut>().map_err(|e| {
                format!(
                    "{} is not valid TOML: {e}\n\
                     Refusing to write so your file isn't clobbered. \
                     Fix or remove it and retry.",
                    path.display()
                )
            })?,
            Err(_) => DocumentMut::new(),
        };
        Ok(Self { doc, path })
    }

    /// Current on-disk value for a key, if set.
    fn get(&self, section: &str, key: &str) -> Option<String> {
        self.doc
            .get(section)
            .and_then(|t| t.get(key))
            .map(render_value)
    }

    /// Validate and write one key, then persist the whole document.
    fn set(&mut self, field: &Field, raw: &str) -> Result<(), String> {
        apply_to_doc(&mut self.doc, field, raw)?;
        self.save()
    }

    /// Write the document atomically: temp file in the same directory, then
    /// rename over the target (`persist` uses ReplaceFile/MoveFileEx on Windows).
    /// A crash mid-write leaves the original intact — important because every new
    /// shell re-reads this file, and a torn read snaps the plugin back to defaults.
    fn save(&self) -> Result<(), String> {
        let dir = self
            .path
            .parent()
            .ok_or_else(|| "config path has no parent directory".to_string())?;
        // The config dir may not exist yet if `nh config` runs before `nh setup`.
        std::fs::create_dir_all(dir).map_err(|e| format!("creating {}: {e}", dir.display()))?;

        let mut tmp = NamedTempFile::new_in(dir).map_err(|e| format!("creating temp file: {e}"))?;
        tmp.write_all(self.doc.to_string().as_bytes())
            .map_err(|e| format!("writing config: {e}"))?;

        // The file can hold a cleartext api_key; keep it owner-only on Unix.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = tmp
                .as_file()
                .metadata()
                .map_err(|e| e.to_string())?
                .permissions();
            perms.set_mode(0o600);
            tmp.as_file()
                .set_permissions(perms)
                .map_err(|e| e.to_string())?;
        }

        tmp.persist(&self.path)
            .map_err(|e| format!("saving {}: {e}", self.path.display()))?;
        Ok(())
    }
}

/// What to show for a field in the interactive list: the masked/real value, or
/// the default annotation when unset.
fn current_display(doc: &ConfigDocument, field: &Field) -> String {
    match doc.get(field.section, field.key) {
        Some(v) if field.masked => mask(&v),
        Some(v) => v,
        None => {
            if field.section == "plugin" && field.key == "hint_arrow" {
                "(unset — shell-specific default)".to_string()
            } else if let Some(h) = field.default_hint {
                format!("{h} (default)")
            } else {
                "(unset)".to_string()
            }
        }
    }
}

/// Print the after-save notice appropriate to the section.
fn print_saved_notice(section: &str) {
    if is_daemon_section(section) {
        println!("Saved. Restart the daemon to apply: nh stop && nh start");
    } else {
        println!("Saved. Open a new shell to apply plugin changes.");
    }
}

// ---------------------------------------------------------------------------
// Non-interactive `get` / `set`
// ---------------------------------------------------------------------------

/// `nh config get <section.key>` — print the real value (scriptable, including
/// api_key). Prints the default when unset; nothing if there is no single default.
pub fn get(dotted: &str) -> Result<(), Box<dyn Error>> {
    let field = find_field(dotted).ok_or_else(|| unknown_key_msg(dotted))?;
    let doc = ConfigDocument::load()?;
    match doc.get(field.section, field.key) {
        Some(v) => println!("{v}"),
        None => {
            if let Some(h) = field.default_hint {
                println!("{h}");
            }
        }
    }
    Ok(())
}

/// `nh config set <section.key> <value>` — validate, write, and persist.
pub fn set(dotted: &str, value: &str) -> Result<(), Box<dyn Error>> {
    let field = find_field(dotted).ok_or_else(|| unknown_key_msg(dotted))?;
    let mut doc = ConfigDocument::load()?;
    // Validation errors echo the raw input; for a masked field, replace the
    // message so an invalid secret isn't printed to stderr (mod.rs prints `e`).
    // NB: lower-cased because mod.rs wraps this as "Error: {e}"; `edit_field`
    // prints its own title-cased standalone variant — keep both as they are.
    doc.set(field, value).map_err(|e| {
        if field.masked {
            "invalid value (hidden — masked field)".to_string()
        } else {
            e
        }
    })?;
    let shown = if field.masked {
        mask(value)
    } else {
        value.to_string()
    };
    println!("{dotted} = {shown}");
    print_saved_notice(field.section);
    Ok(())
}

// ---------------------------------------------------------------------------
// Interactive editor
// ---------------------------------------------------------------------------

/// Read a single line of input with **Esc-to-cancel**: returns `Ok(None)` on Esc,
/// `Ok(Some(text))` on Enter.
///
/// dialoguer's `Input`/`Password` can't cancel on Esc (only its `Select` menus
/// can), so we drive the terminal directly for the editable fields. Ctrl-C is
/// handled explicitly so the "get me out" key is deterministic on every platform:
/// on Unix `read_key` re-raises SIGINT (the process dies cleanly), but on Windows
/// it surfaces as `Key::CtrlC`, which without an arm would fall into the catch-all
/// and be silently ignored. We map it to an `Interrupted` error that unwinds out
/// of the wizard and exits `nh config`.
///
/// Deliberately minimal — typing, Backspace, Enter, Esc. Other keys (arrows,
/// etc.) are ignored; config values are short single-line strings. `mask` echoes
/// `*` per char instead of the literal text (API-key entry).
fn read_line_cancelable(
    prompt: &str,
    initial: &str,
    mask: bool,
) -> std::io::Result<Option<String>> {
    let term = Term::stderr();
    let mut buf: Vec<char> = initial.chars().collect();

    let draw = |buf: &[char]| -> std::io::Result<()> {
        term.clear_line()?;
        let shown: String = if mask {
            "*".repeat(buf.len())
        } else {
            buf.iter().collect()
        };
        term.write_str(&format!("{prompt}: {shown}"))
    };
    draw(&buf)?;

    loop {
        match term.read_key()? {
            Key::Enter => {
                term.write_line("")?;
                return Ok(Some(buf.into_iter().collect()));
            }
            Key::Escape => {
                term.write_line("")?;
                return Ok(None);
            }
            Key::CtrlC => {
                term.write_line("")?;
                return Err(std::io::Error::new(
                    std::io::ErrorKind::Interrupted,
                    "cancelled",
                ));
            }
            Key::Backspace => {
                buf.pop();
                draw(&buf)?;
            }
            Key::Char(c) if !c.is_control() => {
                buf.push(c);
                draw(&buf)?;
            }
            _ => {}
        }
    }
}

/// Prompt for a new value for `field`. Returns the raw string the user entered,
/// or `None` if they backed out (Esc) without entering anything.
fn prompt_value(doc: &ConfigDocument, field: &Field) -> Result<Option<String>, Box<dyn Error>> {
    let current = doc.get(field.section, field.key);
    let chosen = match field.kind {
        FieldKind::Bool => {
            let opts = ["true", "false"];
            let default_idx = if current.as_deref() == Some("true") {
                0
            } else {
                1
            };
            Select::new()
                .with_prompt(field.label)
                .items(&opts)
                .default(default_idx)
                .interact_opt()?
                .map(|i| opts[i].to_string())
        }
        FieldKind::Enum(opts) => {
            let default_idx = current
                .as_deref()
                .and_then(|c| opts.iter().position(|o| *o == c))
                .unwrap_or(0);
            Select::new()
                .with_prompt(field.label)
                .items(opts)
                .default(default_idx)
                .interact_opt()?
                .map(|i| opts[i].to_string())
        }
        FieldKind::Str if field.masked => {
            // Don't prefill a secret. Esc cancels; empty Enter is treated as
            // "no change" (no field accepts an empty value anyway).
            read_line_cancelable(field.label, "", true)?.filter(|s| !s.is_empty())
        }
        _ => {
            // Prefill the current value so the user can edit it. Esc cancels back
            // to the menu; empty Enter = no change.
            let initial = current.as_deref().unwrap_or("");
            read_line_cancelable(field.label, initial, false)?.filter(|s| !s.is_empty())
        }
    };
    Ok(chosen)
}

/// Edit a single field: prompt, validate, write. Returns whether a value was saved.
fn edit_field(doc: &mut ConfigDocument, field: &Field) -> Result<bool, Box<dyn Error>> {
    let raw = match prompt_value(doc, field)? {
        Some(r) => r,
        None => return Ok(false),
    };
    match doc.set(field, &raw) {
        Ok(()) => Ok(true),
        Err(e) => {
            // Validation errors echo the raw input (`got '...'`); never surface a
            // masked field's value, even when it's invalid. NB: title-cased here
            // (standalone line) vs lower-cased in `set()` (wrapped by mod.rs as
            // "Error: {e}") — the casing divergence is deliberate, keep both.
            if field.masked {
                eprintln!("Invalid value (hidden — masked field)");
            } else {
                eprintln!("Invalid value: {e}");
            }
            Ok(false)
        }
    }
}

/// `nh config` with no arguments — the two-level interactive editor.
pub fn wizard() -> Result<(), Box<dyn Error>> {
    // dialoguer renders to stderr and reads keys from the tty.
    if !std::io::stdin().is_terminal() || !std::io::stderr().is_terminal() {
        return Err("`nh config` (interactive) needs a terminal.\n\
                    For scripting use: nh config get <key> / nh config set <key> <value>"
            .into());
    }

    let mut doc = ConfigDocument::load()?;

    loop {
        let mut labels: Vec<String> = SECTIONS.iter().map(|(s, _)| format!("[{s}]")).collect();
        labels.push("Done".to_string());

        let section_idx = match Select::new()
            .with_prompt("nighthawk settings")
            .items(&labels)
            .default(0)
            .interact_opt()?
        {
            Some(i) => i,
            None => break, // Esc at top level = quit
        };
        if section_idx == SECTIONS.len() {
            break; // "Done"
        }

        let (section, fields) = SECTIONS[section_idx];

        loop {
            let mut rows: Vec<String> = fields
                .iter()
                .map(|f| format!("{}: {}", f.label, current_display(&doc, f)))
                .collect();
            rows.push("← Back".to_string());

            let key_idx = match Select::new()
                .with_prompt(format!("[{section}]"))
                .items(&rows)
                .default(0)
                .interact_opt()?
            {
                Some(i) => i,
                None => break, // Esc = back to section list
            };
            if key_idx == fields.len() {
                break; // "← Back"
            }

            if edit_field(&mut doc, &fields[key_idx])? {
                print_saved_notice(section);
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::config::{CloudConfig, CloudProvider, DaemonConfig, LlmConfig, TierConfig};

    // --- registry lookup ---

    #[test]
    fn find_field_resolves_known_keys() {
        assert!(find_field("cloud.api_key").is_some());
        assert!(find_field("plugin.tab_accept").is_some());
        assert!(find_field("daemon.log_level").is_some());
    }

    #[test]
    fn find_field_rejects_unknown() {
        assert!(find_field("cloud.nope").is_none());
        assert!(find_field("bogus.key").is_none());
        assert!(find_field("no_dot").is_none());
    }

    #[test]
    fn plugin_registry_has_four_keys() {
        let (_, fields) = SECTIONS.iter().find(|(s, _)| *s == "plugin").unwrap();
        let keys: Vec<_> = fields.iter().map(|f| f.key).collect();
        assert_eq!(keys, ["hint_arrow", "debounce_ms", "debug", "tab_accept"]);
    }

    // --- validation ---

    #[test]
    fn uint_rejects_negative_float_and_overflow() {
        let f = find_field("local_llm.budget_ms").unwrap();
        assert!(parse_item(f, "500").is_ok());
        assert!(parse_item(f, "-1").is_err());
        assert!(parse_item(f, "0.5").is_err());
        assert!(parse_item(f, "4294967296").is_err()); // u32::MAX + 1
        assert!(parse_item(f, "abc").is_err());
    }

    #[test]
    fn float_writes_clean_decimal_no_f32_noise() {
        // Regression: storing as f32-cast-to-f64 produced 0.30000001192092896.
        let item = parse_item(find_field("cloud.temperature").unwrap(), "0.3").unwrap();
        assert_eq!(render_value(&item), "0.3");
    }

    #[test]
    fn temperature_range_enforced() {
        let f = find_field("cloud.temperature").unwrap();
        assert!(parse_item(f, "0.2").is_ok());
        assert!(parse_item(f, "2.0").is_ok());
        assert!(parse_item(f, "2.1").is_err());
        assert!(parse_item(f, "-0.1").is_err());
    }

    #[test]
    fn float_rejects_non_finite() {
        // `f64::parse` accepts these; the daemon must never see inf/nan.
        // Use a SYNTHETIC non-"temperature" float field: every real Float field is
        // keyed "temperature", whose 0.0..=2.0 range check would also reject
        // inf/nan and mask whether the `is_finite` guard is doing the work. This
        // field has no range check, so only `is_finite` can reject these.
        let f = Field {
            section: "test",
            key: "x",
            label: "x",
            kind: FieldKind::Float,
            masked: false,
            default_hint: None,
        };
        assert!(parse_item(&f, "inf").is_err());
        assert!(parse_item(&f, "-inf").is_err());
        assert!(parse_item(&f, "nan").is_err());
        // A finite value with no range constraint must still pass — proving it's
        // `is_finite`, not a range check, that rejected the above.
        assert!(parse_item(&f, "5.0").is_ok());
    }

    #[test]
    fn enum_must_match_serde_wire_case() {
        let f = find_field("cloud.provider").unwrap();
        assert!(parse_item(f, "openai").is_ok());
        // Wrong case must be rejected: it would write valid TOML that the daemon
        // then fails to deserialize, wiping the whole config to defaults.
        assert!(parse_item(f, "OpenAI").is_err());
        assert!(parse_item(f, "gpt4").is_err());
    }

    #[test]
    fn bool_rejects_non_lowercase() {
        let f = find_field("plugin.debug").unwrap();
        assert!(parse_item(f, "true").is_ok());
        assert!(parse_item(f, "false").is_ok());
        assert!(parse_item(f, "True").is_err());
        assert!(parse_item(f, "1").is_err());
    }

    #[test]
    fn hint_arrow_rejects_chars_the_plugin_regex_cant_parse() {
        let f = find_field("plugin.hint_arrow").unwrap();
        assert!(parse_item(f, "->").is_ok());
        assert!(parse_item(f, "→").is_ok());
        assert!(parse_item(f, "a\"b").is_err()); // embedded quote
        assert!(parse_item(f, "a\\b").is_err()); // backslash
        assert!(parse_item(f, "a\nb").is_err()); // control char
    }

    // --- toml_edit round-trip behavior ---

    #[test]
    fn writing_creates_a_real_plugin_header() {
        // Start from a doc with NO [plugin] section.
        let mut doc = DocumentMut::new();
        apply_to_doc(&mut doc, find_field("plugin.hint_arrow").unwrap(), "->").unwrap();
        let out = doc.to_string();
        assert!(
            out.contains("[plugin]"),
            "expected a real [plugin] header, got:\n{out}"
        );
        assert!(out.contains("hint_arrow = \"->\""), "got:\n{out}");
    }

    #[test]
    fn dotted_plugin_is_promoted_to_a_header() {
        // A pre-existing dotted-form [plugin] (from a hand-edit) must come back
        // out with a real header after a write — else all plugin parsers go blind.
        let mut doc: DocumentMut = "plugin.debug = true\n".parse().unwrap();
        apply_to_doc(&mut doc, find_field("plugin.debounce_ms").unwrap(), "250").unwrap();
        let out = doc.to_string();
        assert!(
            out.contains("[plugin]"),
            "dotted [plugin] should be promoted to a header, got:\n{out}"
        );
    }

    #[test]
    fn write_preserves_existing_comments() {
        let mut doc: DocumentMut = "# keep me\n[daemon]\nlog_level = \"info\"\n"
            .parse()
            .unwrap();
        apply_to_doc(&mut doc, find_field("daemon.log_level").unwrap(), "debug").unwrap();
        let out = doc.to_string();
        assert!(out.contains("# keep me"), "comment dropped:\n{out}");
        assert!(out.contains("log_level = \"debug\""), "got:\n{out}");
    }

    #[test]
    fn load_rejects_malformed_toml() {
        // The parse step that load() relies on must error on bad TOML so the
        // caller refuses to write rather than clobber a recoverable file.
        assert!("this is = = not toml".parse::<DocumentMut>().is_err());
    }

    // --- masking ---

    #[test]
    fn mask_shows_only_last_four() {
        assert_eq!(mask("sk-1234567890abcd"), "…abcd");
        assert_eq!(mask("abcd"), "••••");
        assert_eq!(mask(""), "");
    }

    // --- provider enum stays in sync with the daemon (end-to-end) ---

    #[test]
    fn provider_options_deserialize_into_cloud_provider() {
        // Each registry option, written to disk, must deserialize in the daemon.
        for opt in PROVIDERS {
            let toml = format!("[cloud]\nprovider = \"{opt}\"\n");
            let cfg: crate::daemon::config::Config =
                toml::from_str(&toml).expect("registry provider option must parse");
            assert!(
                cfg.cloud.is_some(),
                "provider '{opt}' produced no cloud section"
            );
        }
    }

    #[test]
    fn set_provider_roundtrips_through_daemon_config() {
        // The full path: registry validate -> toml_edit write -> daemon deserialize.
        let item = parse_item(find_field("cloud.provider").unwrap(), "anthropic").unwrap();
        let mut doc = DocumentMut::new();
        doc["cloud"] = Item::Table(Table::new());
        doc["cloud"].as_table_mut().unwrap().set_implicit(false);
        doc["cloud"]["provider"] = item;
        let cfg: crate::daemon::config::Config = toml::from_str(&doc.to_string()).unwrap();
        assert_eq!(cfg.cloud.unwrap().provider, CloudProvider::Anthropic);
    }

    // --- default_hint drift guard against the serde Defaults (daemon sections) ---

    #[test]
    fn default_hints_match_daemon_defaults() {
        let hint = |dotted: &str| find_field(dotted).unwrap().default_hint.unwrap();

        // [daemon]
        assert_eq!(hint("daemon.log_level"), DaemonConfig::default().log_level);

        // [tiers] — every bool
        let t = TierConfig::default();
        assert_eq!(hint("tiers.enable_history") == "true", t.enable_history);
        assert_eq!(hint("tiers.enable_specs") == "true", t.enable_specs);
        assert_eq!(hint("tiers.enable_local_llm") == "true", t.enable_local_llm);
        assert_eq!(hint("tiers.enable_cloud") == "true", t.enable_cloud);

        // [local_llm]
        let l = LlmConfig::default();
        assert_eq!(hint("local_llm.endpoint"), l.endpoint);
        assert_eq!(hint("local_llm.model"), l.model);
        assert_eq!(
            hint("local_llm.budget_ms").parse::<u32>().unwrap(),
            l.budget_ms
        );
        assert_eq!(
            hint("local_llm.max_tokens").parse::<u32>().unwrap(),
            l.max_tokens
        );
        // Floats compared numerically (string-compare of an f32 default is fragile).
        assert!(
            (hint("local_llm.temperature").parse::<f32>().unwrap() - l.temperature).abs()
                < f32::EPSILON
        );

        // [cloud]
        let c = CloudConfig::default();
        assert_eq!(hint("cloud.budget_ms").parse::<u32>().unwrap(), c.budget_ms);
        assert_eq!(
            hint("cloud.max_tokens").parse::<u32>().unwrap(),
            c.max_tokens
        );
        assert_eq!(
            hint("cloud.history_context_size").parse::<usize>().unwrap(),
            c.history_context_size
        );
        assert!(
            (hint("cloud.temperature").parse::<f32>().unwrap() - c.temperature).abs()
                < f32::EPSILON
        );
        // provider hint is compared through the real deserialize path: the wire
        // token must round-trip to the daemon's default CloudProvider.
        let provider_toml = format!("[cloud]\nprovider = \"{}\"\n", hint("cloud.provider"));
        let cfg: crate::daemon::config::Config = toml::from_str(&provider_toml).unwrap();
        assert_eq!(cfg.cloud.unwrap().provider, CloudProvider::default());
    }
}
