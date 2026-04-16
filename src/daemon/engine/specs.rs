use crate::proto::{CompletionRequest, Suggestion, SuggestionSource};
use async_trait::async_trait;
use std::collections::HashSet;

use super::tier::PredictionTier;
use crate::daemon::specs::{CliSpec, OptionSpec, SpecRegistry, SubcommandSpec};
use std::sync::Arc;

/// Confidence value for fuzzy command corrections (e.g., "gti" → "git").
const FUZZY_CORRECTION_CONFIDENCE: f32 = 0.85;

/// Tier 1: Static spec lookup.
/// Matches current input against CLI specs (withfig/autocomplete, --help parsed).
/// Must complete in under 1ms.
pub struct SpecTier {
    registry: Arc<SpecRegistry>,
}

impl SpecTier {
    pub fn new(registry: Arc<SpecRegistry>) -> Self {
        Self { registry }
    }
}

/// True if `name` is a single-char POSIX flag like "-l" or "-a".
fn is_single_char_flag(name: &str) -> bool {
    name.len() == 2 && name.starts_with('-') && name.as_bytes()[1] != b'-'
}

/// Decompose a stacked flag token like "-la" into individual chars ['l', 'a'].
/// Returns None if the token isn't a valid stacked-flag format (must be `-` + 2..n ASCII chars).
fn decompose_stacked_flags(token: &str) -> Option<Vec<char>> {
    if token.starts_with('-') && !token.starts_with("--") && token.len() > 2 {
        Some(token[1..].chars().collect())
    } else {
        None
    }
}

/// Collect all flag names already present in `tokens`.
/// Handles both individual flags (`-l`) and stacked flags (`-la` → `-l`, `-a`).
fn collect_used_flags(tokens: &[&str], options: &[OptionSpec]) -> HashSet<String> {
    let single_char_set: HashSet<char> = options
        .iter()
        .flat_map(|opt| opt.names.iter())
        .filter(|n| is_single_char_flag(n))
        .filter_map(|n| n.chars().nth(1))
        .collect();

    let mut used = HashSet::new();

    for &token in tokens {
        // Direct match — if any name of an option matches, mark ALL its names as used
        for opt in options {
            if opt.names.iter().any(|name| name == token) {
                for name in &opt.names {
                    used.insert(name.clone());
                }
            }
        }
        // Decompose stacked flags: "-la" → mark "-l", "-a", and their siblings as used
        if let Some(chars) = decompose_stacked_flags(token) {
            for ch in chars {
                if single_char_set.contains(&ch) {
                    let short = format!("-{}", ch);
                    for opt in options {
                        if opt.names.contains(&short) {
                            for name in &opt.names {
                                used.insert(name.clone());
                            }
                        }
                    }
                }
            }
        }
    }

    used
}

/// Check whether `prev` is a flag (or ends with a stacked flag) that takes an argument.
/// Returns the matching OptionSpec if found, so callers can access its arg suggestions.
fn prev_consumes_next_token<'a>(prev: &str, options: &'a [OptionSpec]) -> Option<&'a OptionSpec> {
    // Case 1: direct match (e.g., "-p", "--prompt", "-X")
    for opt in options {
        if opt.takes_arg && opt.names.iter().any(|n| n == prev) {
            return Some(opt);
        }
    }
    // Case 2: stacked flag where last char takes arg (e.g., "-lT" → -T takes arg)
    if let Some(chars) = decompose_stacked_flags(prev) {
        if let Some(&last_ch) = chars.last() {
            let short = format!("-{}", last_ch);
            for opt in options {
                if opt.takes_arg && opt.names.contains(&short) {
                    return Some(opt);
                }
            }
        }
    }
    None
}

/// Return single-char flags that don't take an argument (safe to stack).
fn stackable_flags(options: &[OptionSpec]) -> Vec<(char, &OptionSpec)> {
    options
        .iter()
        .filter(|opt| !opt.takes_arg)
        .filter_map(|opt| {
            opt.names
                .iter()
                .find(|n| is_single_char_flag(n))
                .and_then(|n| n.chars().nth(1))
                .map(|ch| (ch, opt))
        })
        .collect()
}

/// Result of navigating through previous_tokens in a spec tree.
/// Used to find the correct subcommand context for suggestions.
struct NavigatedContext<'a> {
    subcommands: &'a [SubcommandSpec],
    options: &'a [OptionSpec],
    navigated_names: Vec<&'a str>, // Canonical subcommand names (not input tokens)
}

/// Navigate through previous_tokens, descending into nested SubcommandSpecs.
/// Skips flags and their argument values. Stops at positional args.
fn navigate_to_context<'a>(root: &'a CliSpec, previous_tokens: &[&str]) -> NavigatedContext<'a> {
    let mut subcommands = root.subcommands.as_slice();
    let mut options = root.options.as_slice();
    let mut navigated_names = Vec::new();
    let mut skip_next = false; // For flags that consume an argument

    for token in previous_tokens {
        // Skip argument value of a flag that consumes one (e.g., -C /path)
        if skip_next {
            skip_next = false;
            continue;
        }

        // Skip flags — they don't affect subcommand navigation
        if token.starts_with('-') {
            // Check if this flag consumes the next token
            if let Some(opt) = options.iter().find(|o| o.names.iter().any(|n| n == token)) {
                if opt.takes_arg {
                    skip_next = true;
                }
            }
            continue;
        }

        // Find matching subcommand by name or alias
        let found = subcommands
            .iter()
            .find(|sub| sub.name == *token || sub.aliases.iter().any(|a| a == *token));

        match found {
            Some(sub) => {
                navigated_names.push(sub.name.as_str()); // Track CANONICAL name
                subcommands = &sub.subcommands;
                options = &sub.options;
            }
            None => break, // Positional arg or unknown — stop navigation
        }
    }

    NavigatedContext {
        subcommands,
        options,
        navigated_names,
    }
}

#[async_trait]
impl PredictionTier for SpecTier {
    fn name(&self) -> &str {
        "specs"
    }

    fn budget_ms(&self) -> u32 {
        1
    }

    async fn predict(&self, req: &CompletionRequest) -> Vec<Suggestion> {
        let input = &req.input[..req.cursor];
        let parts: Vec<&str> = input.split_whitespace().collect();

        let command = match parts.first() {
            Some(cmd) => *cmd,
            None => return vec![],
        };

        // Change A: try fuzzy command-name lookup when exact lookup fails
        let (spec, command_was_fuzzy) = match self.registry.lookup(command) {
            Some(spec) => (spec, false),
            None => match self.registry.fuzzy_lookup(command) {
                Some((spec, _dist)) => (spec, true),
                None => return vec![],
            },
        };

        // If we only have the command name (no trailing space)
        if parts.len() == 1 && !input.ends_with(' ') {
            // If command was fuzzy-resolved, suggest the correction
            if command_was_fuzzy {
                // CRITICAL: Must include diff_ops for shell plugin rendering.
                // Without it, when typed_len == text.len (e.g., "gti" -> "git"),
                // the prefix-match ghost text path fails silently.
                let ops = crate::daemon::fuzzy::diff_ops(command, &spec.name);
                return vec![Suggestion {
                    text: spec.name.clone(),
                    replace_start: 0,
                    replace_end: input.len(),
                    confidence: FUZZY_CORRECTION_CONFIDENCE,
                    source: SuggestionSource::Spec,
                    description: Some(format!("Did you mean '{}'?", spec.name)),
                    diff_ops: Some(ops),
                }];
            }
            return vec![];
        }

        let current_token = if input.ends_with(' ') {
            ""
        } else {
            parts.last().copied().unwrap_or("")
        };

        // Tokens before the cursor token — already committed by the user
        let previous_tokens: Vec<&str> = if input.ends_with(' ') {
            parts[1..].to_vec()
        } else if parts.len() > 1 {
            parts[1..parts.len() - 1].to_vec()
        } else {
            vec![]
        };

        // Handles "gti " (with trailing space) - command only, no subcommand started.
        // Suggest only the corrected command (not full commands with subcommands).
        if command_was_fuzzy && current_token.is_empty() && previous_tokens.is_empty() {
            let ops = crate::daemon::fuzzy::diff_ops(command, &spec.name);
            return vec![Suggestion {
                text: spec.name.clone(),
                replace_start: 0,
                replace_end: command.len(),
                confidence: FUZZY_CORRECTION_CONFIDENCE,
                source: SuggestionSource::Spec,
                description: Some(format!("Did you mean '{}'?", spec.name)),
                diff_ops: Some(ops),
            }];
        }

        // Navigate into nested subcommands based on previous_tokens
        let ctx = navigate_to_context(&spec, &previous_tokens);

        // Include current_token so we don't re-suggest the exact flag being typed
        let mut all_committed = previous_tokens.clone();
        if !current_token.is_empty() {
            all_committed.push(current_token);
        }
        let used_flags = collect_used_flags(&all_committed, ctx.options);

        let mut suggestions = Vec::new();

        // If previous token is a flag that takes an argument, the cursor position
        // expects a flag argument value — not subcommands or other flags.
        if let Some(&prev) = previous_tokens.last() {
            if let Some(opt) = prev_consumes_next_token(prev, ctx.options) {
                // Offer arg-value suggestions if the option defines them
                if let Some(arg) = &opt.arg {
                    for val in &arg.suggestions {
                        if val.starts_with(current_token) {
                            let (replace_start, replace_end) = if current_token.is_empty() {
                                (req.cursor, req.cursor)
                            } else {
                                (input.len() - current_token.len(), req.cursor)
                            };
                            suggestions.push(Suggestion {
                                text: val.clone(),
                                replace_start,
                                replace_end,
                                confidence: 0.85,
                                source: SuggestionSource::Spec,
                                description: arg.name.clone(),
                                diff_ops: None,
                            });
                        }
                    }
                }
                // Always return — even if suggestions is empty. The next token
                // belongs to this flag; do NOT fall through to subcommand/flag matching.
                suggestions.truncate(5);
                // Change C: fix suggestions when command was fuzzy-resolved
                if command_was_fuzzy {
                    let prefix = if ctx.navigated_names.is_empty() {
                        spec.name.clone()
                    } else {
                        format!("{} {}", spec.name, ctx.navigated_names.join(" "))
                    };
                    for s in &mut suggestions {
                        s.diff_ops = None;
                        s.text = format!("{} {}", prefix, s.text);
                        s.replace_start = 0;
                    }
                }
                return suggestions;
            }
        }

        // Match subcommands
        for sub in ctx.subcommands {
            if sub.name.starts_with(current_token) && sub.name != current_token {
                let (replace_start, replace_end) = if current_token.is_empty() {
                    (req.cursor, req.cursor)
                } else {
                    let token_start = input.len() - current_token.len();
                    (token_start, req.cursor)
                };

                suggestions.push(Suggestion {
                    text: sub.name.clone(),
                    replace_start,
                    replace_end,
                    confidence: 0.9,
                    source: SuggestionSource::Spec,
                    description: sub.description.clone(),
                    diff_ops: None,
                });
            }
        }

        // Match options by prefix
        for opt in ctx.options {
            for name in &opt.names {
                if name.starts_with(current_token) && name != current_token {
                    if used_flags.contains(name) {
                        continue;
                    }
                    let (replace_start, replace_end) = if current_token.is_empty() {
                        (req.cursor, req.cursor)
                    } else {
                        let token_start = input.len() - current_token.len();
                        (token_start, req.cursor)
                    };

                    suggestions.push(Suggestion {
                        text: name.clone(),
                        replace_start,
                        replace_end,
                        confidence: 0.85,
                        source: SuggestionSource::Spec,
                        description: opt.description.clone(),
                        diff_ops: None,
                    });
                }
            }
        }

        // --- Fuzzy fallback for subcommands and options ---
        // Only when prefix matching found nothing and current_token is non-empty.
        if suggestions.is_empty() && !current_token.is_empty() {
            let token_start = input.len() - current_token.len();

            // Fuzzy match subcommand names and aliases
            let mut sub_candidates: Vec<&str> = Vec::new();
            for sub in ctx.subcommands {
                sub_candidates.push(&sub.name);
                for alias in &sub.aliases {
                    sub_candidates.push(alias);
                }
            }
            let fuzzy_subs =
                crate::daemon::fuzzy::fuzzy_matches(current_token, sub_candidates.into_iter());

            for fm in &fuzzy_subs {
                let desc = ctx
                    .subcommands
                    .iter()
                    .find(|s| s.name == fm.text || s.aliases.iter().any(|a| a == &fm.text))
                    .and_then(|s| s.description.clone());

                let confidence = if fm.distance == 1 { 0.70 } else { 0.55 };
                let ops = crate::daemon::fuzzy::diff_ops(current_token, &fm.text);
                suggestions.push(Suggestion {
                    text: fm.text.clone(),
                    replace_start: token_start,
                    replace_end: req.cursor,
                    confidence,
                    source: SuggestionSource::Spec,
                    description: desc,
                    diff_ops: Some(ops),
                });
            }

            // Fuzzy match long option names only (--prefixed).
            // Short flags (-x) are excluded to avoid interfering with flag stacking.
            if current_token.starts_with("--") {
                let opt_names: Vec<&str> = ctx
                    .options
                    .iter()
                    .flat_map(|opt| opt.names.iter())
                    .filter(|n| n.starts_with("--"))
                    .map(|n| n.as_str())
                    .collect();
                let fuzzy_opts =
                    crate::daemon::fuzzy::fuzzy_matches(current_token, opt_names.into_iter());

                for fm in &fuzzy_opts {
                    if used_flags.contains(&fm.text) {
                        continue;
                    }
                    let desc = ctx
                        .options
                        .iter()
                        .find(|opt| opt.names.iter().any(|n| n == &fm.text))
                        .and_then(|opt| opt.description.clone());

                    let confidence = if fm.distance == 1 { 0.65 } else { 0.50 };
                    let ops = crate::daemon::fuzzy::diff_ops(current_token, &fm.text);
                    suggestions.push(Suggestion {
                        text: fm.text.clone(),
                        replace_start: token_start,
                        replace_end: req.cursor,
                        confidence,
                        source: SuggestionSource::Spec,
                        description: desc,
                        diff_ops: Some(ops),
                    });
                }
            }
        }

        // --- Flag stacking ---
        // Only attempt stacking when prefix matching found nothing.

        if suggestions.is_empty() {
            let token_start = input.len() - current_token.len();

            // Case 1: current_token is an exact single-char flag ("-l")
            // → suggest extending into a stack: "-la", "-lh", etc.
            let exact_flag_no_arg = ctx.options.iter().any(|opt| {
                !opt.takes_arg
                    && opt
                        .names
                        .iter()
                        .any(|n| n == current_token && is_single_char_flag(n))
            });

            if exact_flag_no_arg {
                for (ch, opt) in stackable_flags(ctx.options) {
                    let flag_name = format!("-{}", ch);
                    if !used_flags.contains(&flag_name) {
                        suggestions.push(Suggestion {
                            text: format!("{}{}", current_token, ch),
                            replace_start: token_start,
                            replace_end: req.cursor,
                            confidence: 0.8,
                            source: SuggestionSource::Spec,
                            description: opt.description.clone(),
                            diff_ops: None,
                        });
                    }
                }
            }

            // Case 2: current_token is a stacked prefix ("-la")
            // → validate all chars, suggest extensions: "-lah", "-laR", etc.
            if suggestions.is_empty() {
                if let Some(chars) = decompose_stacked_flags(current_token) {
                    let used_in_stack: HashSet<char> = chars.iter().copied().collect();
                    // Reject stacks with duplicate chars (e.g., "-ll")
                    if used_in_stack.len() == chars.len() {
                        let stackable = stackable_flags(ctx.options);
                        let stackable_chars: HashSet<char> =
                            stackable.iter().map(|(ch, _)| *ch).collect();

                        let all_valid = chars.iter().all(|c| stackable_chars.contains(c));
                        if all_valid {
                            for (ch, opt) in &stackable {
                                if !used_in_stack.contains(ch)
                                    && !used_flags.contains(&format!("-{}", ch))
                                {
                                    suggestions.push(Suggestion {
                                        text: format!("{}{}", current_token, ch),
                                        replace_start: token_start,
                                        replace_end: req.cursor,
                                        confidence: 0.8,
                                        source: SuggestionSource::Spec,
                                        description: opt.description.clone(),
                                        diff_ops: None,
                                    });
                                }
                            }
                        }
                    }
                }
            }
        }

        suggestions.sort_by(|a, b| b.confidence.partial_cmp(&a.confidence).unwrap());
        suggestions.truncate(5);
        // Change C: fix suggestions when command was fuzzy-resolved
        if command_was_fuzzy {
            let prefix = if ctx.navigated_names.is_empty() {
                spec.name.clone()
            } else {
                format!("{} {}", spec.name, ctx.navigated_names.join(" "))
            };
            for s in &mut suggestions {
                s.diff_ops = None; // no inline diff for command-level correction
                s.text = format!("{} {}", prefix, s.text);
                s.replace_start = 0;
            }
        }
        suggestions
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::specs::{
        ArgSpec, CliSpec, OptionSpec, SpecProvider, SpecRegistry, SubcommandSpec,
    };
    use crate::proto::{Shell, SuggestionSource};
    use std::collections::HashMap;
    use std::path::PathBuf;

    struct TestProvider {
        specs: HashMap<String, CliSpec>,
    }

    impl SpecProvider for TestProvider {
        fn get_spec(&self, command: &str) -> Option<CliSpec> {
            self.specs.get(command).cloned()
        }
        fn known_commands(&self) -> Vec<String> {
            self.specs.keys().cloned().collect()
        }
    }

    /// Build an `ls`-like spec with single-char flags, one arg-taking flag, and a subcommand-free layout.
    fn ls_spec() -> CliSpec {
        CliSpec {
            name: "ls".into(),
            description: Some("List directory contents".into()),
            subcommands: vec![],
            options: vec![
                OptionSpec {
                    names: vec!["-l".into()],
                    description: Some("Long format".into()),
                    takes_arg: false,
                    is_required: false,
                    arg: None,
                },
                OptionSpec {
                    names: vec!["-a".into()],
                    description: Some("Show hidden".into()),
                    takes_arg: false,
                    is_required: false,
                    arg: None,
                },
                OptionSpec {
                    names: vec!["-h".into()],
                    description: Some("Human sizes".into()),
                    takes_arg: false,
                    is_required: false,
                    arg: None,
                },
                OptionSpec {
                    names: vec!["-R".into()],
                    description: Some("Recursive".into()),
                    takes_arg: false,
                    is_required: false,
                    arg: None,
                },
                OptionSpec {
                    names: vec!["-t".into()],
                    description: Some("Sort by time".into()),
                    takes_arg: false,
                    is_required: false,
                    arg: None,
                },
                OptionSpec {
                    names: vec!["-T".into()],
                    description: Some("Tab size".into()),
                    takes_arg: true,
                    is_required: false,
                    arg: None,
                },
                OptionSpec {
                    names: vec!["--color".into()],
                    description: Some("Colorize output".into()),
                    takes_arg: true,
                    is_required: false,
                    arg: None,
                },
            ],
            args: vec![],
        }
    }

    fn git_spec() -> CliSpec {
        CliSpec {
            name: "git".into(),
            description: Some("Version control".into()),
            subcommands: vec![
                SubcommandSpec {
                    name: "checkout".into(),
                    aliases: vec![],
                    description: Some("Switch branches".into()),
                    subcommands: vec![],
                    options: vec![],
                    args: vec![],
                },
                SubcommandSpec {
                    name: "cherry-pick".into(),
                    aliases: vec![],
                    description: Some("Apply commits".into()),
                    subcommands: vec![],
                    options: vec![],
                    args: vec![],
                },
            ],
            options: vec![OptionSpec {
                names: vec!["-v".into(), "--verbose".into()],
                description: Some("Verbose".into()),
                takes_arg: false,
                is_required: false,
                arg: None,
            }],
            args: vec![],
        }
    }

    /// Git spec with nested options on checkout subcommand for testing navigation.
    fn git_spec_with_nested_options() -> CliSpec {
        CliSpec {
            name: "git".into(),
            description: Some("Version control".into()),
            subcommands: vec![
                SubcommandSpec {
                    name: "checkout".into(),
                    aliases: vec!["co".into()],
                    description: Some("Switch branches".into()),
                    subcommands: vec![],
                    options: vec![
                        OptionSpec {
                            names: vec!["-b".into()],
                            description: Some("Create branch".into()),
                            takes_arg: true,
                            is_required: false,
                            arg: None,
                        },
                        OptionSpec {
                            names: vec!["--force".into(), "-f".into()],
                            description: Some("Force checkout".into()),
                            takes_arg: false,
                            is_required: false,
                            arg: None,
                        },
                    ],
                    args: vec![],
                },
                SubcommandSpec {
                    name: "cherry-pick".into(),
                    aliases: vec![],
                    description: Some("Apply commits".into()),
                    subcommands: vec![],
                    options: vec![],
                    args: vec![],
                },
            ],
            options: vec![
                OptionSpec {
                    names: vec!["-v".into(), "--verbose".into()],
                    description: Some("Verbose".into()),
                    takes_arg: false,
                    is_required: false,
                    arg: None,
                },
                OptionSpec {
                    names: vec!["-C".into()],
                    description: Some("Run as if started in path".into()),
                    takes_arg: true,
                    is_required: false,
                    arg: None,
                },
            ],
            args: vec![],
        }
    }

    fn make_registry(spec: CliSpec) -> Arc<SpecRegistry> {
        let mut specs = HashMap::new();
        specs.insert(spec.name.clone(), spec);
        Arc::new(SpecRegistry::new(vec![Box::new(TestProvider { specs })]))
    }

    fn req(input: &str) -> CompletionRequest {
        CompletionRequest {
            input: input.into(),
            cursor: input.len(),
            cwd: PathBuf::from("/tmp"),
            shell: Shell::Zsh,
        }
    }

    // --- Helper function tests ---

    #[test]
    fn test_is_single_char_flag() {
        assert!(is_single_char_flag("-l"));
        assert!(is_single_char_flag("-a"));
        assert!(!is_single_char_flag("--long"));
        assert!(!is_single_char_flag("-"));
        assert!(!is_single_char_flag("-la")); // stacked, not single-char
        assert!(!is_single_char_flag("--"));
    }

    #[test]
    fn test_decompose_stacked_flags() {
        assert_eq!(decompose_stacked_flags("-la"), Some(vec!['l', 'a']));
        assert_eq!(
            decompose_stacked_flags("-lahR"),
            Some(vec!['l', 'a', 'h', 'R'])
        );
        assert_eq!(decompose_stacked_flags("-l"), None); // single flag, not stacked
        assert_eq!(decompose_stacked_flags("--long"), None); // long option
        assert_eq!(decompose_stacked_flags("-"), None);
    }

    #[test]
    fn test_prev_consumes_next_token() {
        let options = ls_spec().options;
        // -T takes_arg → Some
        assert!(prev_consumes_next_token("-T", &options).is_some());
        // --color takes_arg → Some
        assert!(prev_consumes_next_token("--color", &options).is_some());
        // -l does NOT take arg → None
        assert!(prev_consumes_next_token("-l", &options).is_none());
        // Stacked: -lT last char T takes_arg → Some
        assert!(prev_consumes_next_token("-lT", &options).is_some());
        // Stacked: -Tl last char l does NOT take arg → None
        assert!(prev_consumes_next_token("-Tl", &options).is_none());
        // Unknown flag → None
        assert!(prev_consumes_next_token("-z", &options).is_none());
        // Not a flag → None
        assert!(prev_consumes_next_token("foo", &options).is_none());
    }

    #[test]
    fn test_collect_used_flags_direct() {
        let options = ls_spec().options;
        let used = collect_used_flags(&["-l", "-a"], &options);
        assert!(used.contains("-l"));
        assert!(used.contains("-a"));
        assert!(!used.contains("-h"));
    }

    #[test]
    fn test_collect_used_flags_stacked() {
        let options = ls_spec().options;
        let used = collect_used_flags(&["-la"], &options);
        assert!(used.contains("-l"));
        assert!(used.contains("-a"));
        assert!(!used.contains("-h"));
    }

    // --- SpecTier prediction tests ---

    #[tokio::test]
    async fn exact_flag_suggests_stacking() {
        // "ls -l" (no space) → should suggest "-la", "-lh", "-lR", "-lt"
        let tier = SpecTier::new(make_registry(ls_spec()));
        let suggestions = tier.predict(&req("ls -l")).await;
        assert!(!suggestions.is_empty(), "should suggest stacked flags");
        assert!(suggestions.iter().all(|s| s.text.starts_with("-l")));
        assert!(suggestions.iter().any(|s| s.text == "-la"));
        assert!(suggestions.iter().any(|s| s.text == "-lh"));
        // -T takes_arg, must NOT appear in stacking suggestions
        assert!(!suggestions.iter().any(|s| s.text == "-lT"));
        // Replace range should cover the "-l" token
        let first = &suggestions[0];
        assert_eq!(first.replace_start, 3); // "ls " = 3 bytes
        assert_eq!(first.replace_end, 5); // "ls -l" = 5 bytes
        assert_eq!(first.source, SuggestionSource::Spec);
    }

    #[tokio::test]
    async fn stacked_prefix_suggests_extension() {
        // "ls -la" → should suggest "-lah", "-laR", "-lat"
        let tier = SpecTier::new(make_registry(ls_spec()));
        let suggestions = tier.predict(&req("ls -la")).await;
        assert!(!suggestions.is_empty());
        assert!(suggestions.iter().all(|s| s.text.starts_with("-la")));
        assert!(suggestions.iter().any(|s| s.text == "-lah"));
        // -l and -a already in stack, must not re-appear
        assert!(!suggestions.iter().any(|s| s.text == "-lal"));
        assert!(!suggestions.iter().any(|s| s.text == "-laa"));
    }

    #[tokio::test]
    async fn trailing_space_suggests_unused_flags() {
        // "ls -l " (trailing space) → suggest unused flags as new tokens
        let tier = SpecTier::new(make_registry(ls_spec()));
        let suggestions = tier.predict(&req("ls -l ")).await;
        assert!(!suggestions.is_empty());
        // Should not re-suggest -l
        assert!(!suggestions.iter().any(|s| s.text == "-l"));
        // Should suggest -a, -h, etc.
        assert!(suggestions.iter().any(|s| s.text == "-a"));
    }

    #[tokio::test]
    async fn trailing_space_after_stack_filters_used() {
        // "ls -la " → -l and -a both used, suggest -h, -R, -t but not -l or -a
        let tier = SpecTier::new(make_registry(ls_spec()));
        let suggestions = tier.predict(&req("ls -la ")).await;
        assert!(!suggestions.iter().any(|s| s.text == "-l"));
        assert!(!suggestions.iter().any(|s| s.text == "-a"));
        assert!(suggestions.iter().any(|s| s.text == "-h"));
    }

    #[tokio::test]
    async fn takes_arg_flag_no_stacking() {
        // "-T" takes an arg → should NOT suggest stacking after it
        let tier = SpecTier::new(make_registry(ls_spec()));
        let suggestions = tier.predict(&req("ls -T")).await;
        assert!(
            suggestions.is_empty(),
            "-T takes an arg, no stacking should be suggested"
        );
    }

    #[tokio::test]
    async fn invalid_stack_no_suggestions() {
        // "-lz" where 'z' is not a known flag → no stacking suggestions
        let tier = SpecTier::new(make_registry(ls_spec()));
        let suggestions = tier.predict(&req("ls -lz")).await;
        assert!(suggestions.is_empty());
    }

    #[tokio::test]
    async fn prefix_match_still_works() {
        // "git ch" → subcommand prefix match: "checkout", "cherry-pick"
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("git ch")).await;
        assert!(suggestions.iter().any(|s| s.text == "checkout"));
        assert!(suggestions.iter().any(|s| s.text == "cherry-pick"));
    }

    #[tokio::test]
    async fn option_prefix_match_still_works() {
        // "git --ver" → "--verbose"
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("git --ver")).await;
        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].text, "--verbose");
    }

    #[tokio::test]
    async fn unknown_command_returns_empty() {
        let tier = SpecTier::new(make_registry(ls_spec()));
        let suggestions = tier.predict(&req("unknown -l")).await;
        assert!(suggestions.is_empty());
    }

    #[tokio::test]
    async fn already_used_flag_filtered_from_prefix() {
        // "ls -a -" → prefix match for "-", should not include "-a"
        let tier = SpecTier::new(make_registry(ls_spec()));
        let suggestions = tier.predict(&req("ls -a -")).await;
        assert!(!suggestions.iter().any(|s| s.text == "-a"));
        assert!(suggestions.iter().any(|s| s.text == "-l"));
    }

    #[tokio::test]
    async fn multi_name_option_sibling_filtered() {
        // "git -v --" → -v and --verbose are the same option, both should be filtered
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("git -v --")).await;
        assert!(
            !suggestions.iter().any(|s| s.text == "--verbose"),
            "--verbose should be filtered since -v (its sibling) is already used"
        );
    }

    #[tokio::test]
    async fn repeated_char_stack_rejected() {
        // "ls -ll" → duplicate chars, not a valid stack
        let tier = SpecTier::new(make_registry(ls_spec()));
        let suggestions = tier.predict(&req("ls -ll")).await;
        assert!(
            suggestions.is_empty(),
            "duplicate chars in stack should be rejected"
        );
    }

    #[tokio::test]
    async fn stacked_flag_filters_sibling_long_name() {
        // Spec with -v/--verbose and -x (two stackable flags)
        let spec = CliSpec {
            name: "cmd".into(),
            description: None,
            subcommands: vec![],
            options: vec![
                OptionSpec {
                    names: vec!["-v".into(), "--verbose".into()],
                    description: Some("Verbose".into()),
                    takes_arg: false,
                    is_required: false,
                    arg: None,
                },
                OptionSpec {
                    names: vec!["-x".into()],
                    description: Some("X flag".into()),
                    takes_arg: false,
                    is_required: false,
                    arg: None,
                },
            ],
            args: vec![],
        };
        let tier = SpecTier::new(make_registry(spec));
        // "-vx" is a stack containing -v. Trailing space → suggest unused flags.
        // --verbose should be filtered since -v was used in the stack.
        let suggestions = tier.predict(&req("cmd -vx --")).await;
        assert!(
            !suggestions.iter().any(|s| s.text == "--verbose"),
            "--verbose should be filtered when -v appears in a stacked flag"
        );
    }

    #[tokio::test]
    async fn mid_cursor_position() {
        // Cursor in the middle: "ls -l foo" with cursor at 5 (after "-l")
        let tier = SpecTier::new(make_registry(ls_spec()));
        let r = CompletionRequest {
            input: "ls -l foo".into(),
            cursor: 5,
            cwd: PathBuf::from("/tmp"),
            shell: Shell::Zsh,
        };
        let suggestions = tier.predict(&r).await;
        // Should suggest stacking on "-l" (ignoring "foo" after cursor)
        assert!(!suggestions.is_empty());
        assert!(suggestions.iter().any(|s| s.text == "-la"));
    }

    /// Build a `curl`-like spec with an option that has arg suggestions.
    fn curl_spec() -> CliSpec {
        CliSpec {
            name: "curl".into(),
            description: Some("Transfer data".into()),
            subcommands: vec![],
            options: vec![
                OptionSpec {
                    names: vec!["-X".into(), "--request".into()],
                    description: Some("HTTP method".into()),
                    takes_arg: true,
                    is_required: false,
                    arg: Some(ArgSpec {
                        name: Some("method".into()),
                        description: None,
                        is_variadic: false,
                        suggestions: vec![
                            "GET".into(),
                            "POST".into(),
                            "PUT".into(),
                            "DELETE".into(),
                        ],
                        template: None,
                    }),
                },
                OptionSpec {
                    names: vec!["-o".into(), "--output".into()],
                    description: Some("Output file".into()),
                    takes_arg: true,
                    is_required: false,
                    arg: None,
                },
                OptionSpec {
                    names: vec!["-v".into(), "--verbose".into()],
                    description: Some("Verbose".into()),
                    takes_arg: false,
                    is_required: false,
                    arg: None,
                },
            ],
            args: vec![],
        }
    }

    #[tokio::test]
    async fn option_value_suggestion() {
        // "curl -X " → suggest GET, POST, PUT, DELETE
        let tier = SpecTier::new(make_registry(curl_spec()));
        let suggestions = tier.predict(&req("curl -X ")).await;
        assert!(!suggestions.is_empty(), "should suggest arg values");
        assert!(suggestions.iter().any(|s| s.text == "GET"));
        assert!(suggestions.iter().any(|s| s.text == "POST"));
        assert!(suggestions.iter().any(|s| s.text == "PUT"));
        assert!(suggestions.iter().any(|s| s.text == "DELETE"));
        // description should be the arg name
        assert_eq!(suggestions[0].description, Some("method".into()));
    }

    #[tokio::test]
    async fn option_value_prefix_filter() {
        // "curl -X P" → suggest POST, PUT (not GET, DELETE)
        let tier = SpecTier::new(make_registry(curl_spec()));
        let suggestions = tier.predict(&req("curl -X P")).await;
        assert_eq!(suggestions.len(), 2);
        assert!(suggestions.iter().any(|s| s.text == "POST"));
        assert!(suggestions.iter().any(|s| s.text == "PUT"));
        assert!(!suggestions.iter().any(|s| s.text == "GET"));
    }

    #[tokio::test]
    async fn option_value_no_suggestions_returns_empty() {
        // "curl -o " → -o takes_arg but has no arg suggestions → return empty
        // The next token belongs to -o; do NOT suggest flags/subcommands.
        let tier = SpecTier::new(make_registry(curl_spec()));
        let suggestions = tier.predict(&req("curl -o ")).await;
        assert!(
            suggestions.is_empty(),
            "should return empty when option takes arg but has no suggestions"
        );
    }

    // --- Fuzzy matching test helpers ---

    /// git spec with a "switch" alias on checkout (5+ chars for fuzzy matching)
    fn git_spec_with_aliases() -> CliSpec {
        CliSpec {
            name: "git".into(),
            description: Some("Version control".into()),
            subcommands: vec![
                SubcommandSpec {
                    name: "checkout".into(),
                    aliases: vec!["switch".into()],
                    description: Some("Switch branches".into()),
                    subcommands: vec![],
                    options: vec![],
                    args: vec![],
                },
                SubcommandSpec {
                    name: "cherry-pick".into(),
                    aliases: vec![],
                    description: Some("Apply commits".into()),
                    subcommands: vec![],
                    options: vec![],
                    args: vec![],
                },
            ],
            options: vec![OptionSpec {
                names: vec!["-v".into(), "--verbose".into()],
                description: Some("Verbose".into()),
                takes_arg: false,
                is_required: false,
                arg: None,
            }],
            args: vec![],
        }
    }

    fn make_multi_registry(specs: Vec<CliSpec>) -> Arc<SpecRegistry> {
        let mut map = HashMap::new();
        for spec in specs {
            map.insert(spec.name.clone(), spec);
        }
        Arc::new(SpecRegistry::new(vec![Box::new(TestProvider {
            specs: map,
        })]))
    }

    // --- Fuzzy matching tests ---

    #[tokio::test]
    async fn fuzzy_subcommand_distance_one() {
        // "git chekout" → "checkout" (deletion typo, distance 1)
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("git chekout")).await;
        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].text, "checkout");
        assert!((suggestions[0].confidence - 0.70).abs() < 0.01);
        assert_eq!(suggestions[0].source, SuggestionSource::Spec);
        // replace_start should cover the mistyped token
        assert_eq!(suggestions[0].replace_start, 4);
        assert_eq!(suggestions[0].replace_end, 11);
    }

    #[tokio::test]
    async fn fuzzy_subcommand_substitution() {
        // "git chackout" → "checkout" (substitution e→a, distance 1)
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("git chackout")).await;
        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].text, "checkout");
        assert!((suggestions[0].confidence - 0.70).abs() < 0.01);
    }

    #[tokio::test]
    async fn fuzzy_subcommand_distance_two() {
        // "git chekcotu" → "checkout" (distance 2)
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("git chekcotu")).await;
        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].text, "checkout");
        assert!((suggestions[0].confidence - 0.55).abs() < 0.01);
    }

    #[tokio::test]
    async fn fuzzy_option_long_flag() {
        // "git --vrebose" → "--verbose" (transposition, distance 1)
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("git --vrebose")).await;
        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].text, "--verbose");
        assert!((suggestions[0].confidence - 0.65).abs() < 0.01);
    }

    #[tokio::test]
    async fn fuzzy_does_not_override_prefix_match() {
        // "git ch" → prefix matches "checkout" and "cherry-pick" at confidence 0.9
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("git ch")).await;
        assert!(suggestions.iter().all(|s| s.confidence > 0.8));
        assert!(suggestions.iter().any(|s| s.text == "checkout"));
        assert!(suggestions.iter().any(|s| s.text == "cherry-pick"));
    }

    #[tokio::test]
    async fn fuzzy_no_interference_with_flag_stacking() {
        // "ls -lz" → should NOT fuzzy match -lz to -la; stacking rejects unknown 'z'
        let tier = SpecTier::new(make_registry(ls_spec()));
        let suggestions = tier.predict(&req("ls -lz")).await;
        assert!(
            suggestions.is_empty(),
            "should not fuzzy match stacked-flag tokens"
        );
    }

    #[tokio::test]
    async fn fuzzy_flag_stacking_still_works() {
        // "ls -l" → flag stacking should still suggest "-la", "-lh", etc.
        let tier = SpecTier::new(make_registry(ls_spec()));
        let suggestions = tier.predict(&req("ls -l")).await;
        assert!(!suggestions.is_empty());
        assert!(suggestions.iter().any(|s| s.text.starts_with("-l")));
    }

    #[tokio::test]
    async fn fuzzy_respects_used_flags() {
        // "git --verbose --vrebose" → --verbose already used, no suggestion
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("git --verbose --vrebose")).await;
        assert!(
            suggestions.is_empty(),
            "should not suggest already-used flag"
        );
    }

    #[tokio::test]
    async fn fuzzy_skipped_for_short_tokens() {
        // "git co" → "co" is 2 chars, too short for fuzzy (and no prefix match in test spec)
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("git co")).await;
        assert!(
            suggestions.is_empty(),
            "2-char token should not trigger fuzzy"
        );
    }

    #[tokio::test]
    async fn short_token_still_prefix_matches() {
        // "git ch" → "co" is too short for fuzzy, but "ch" prefix-matches checkout/cherry-pick.
        // Verifies prefix matching still works even when fuzzy is not eligible.
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("git ch")).await;
        assert!(!suggestions.is_empty());
        assert!(suggestions.iter().any(|s| s.text == "checkout"));
        assert!(
            suggestions.iter().all(|s| s.confidence > 0.8),
            "should be prefix confidence, not fuzzy"
        );
    }

    #[tokio::test]
    async fn fuzzy_case_sensitive_flags() {
        // ls has -R (Recursive) but not -r. Fuzzy on "--colro" should match "--color".
        // But short flags like -R must not match -r (both len 2, rejected by length check anyway).
        let tier = SpecTier::new(make_registry(ls_spec()));
        let suggestions = tier.predict(&req("ls --colro")).await;
        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].text, "--color");
    }

    #[tokio::test]
    async fn fuzzy_arg_value_no_fuzzy() {
        // "curl -X PSOT" → arg-value suggestions use prefix match, not fuzzy.
        // "PSOT" doesn't prefix-match any of GET/POST/PUT/DELETE → empty.
        let tier = SpecTier::new(make_registry(curl_spec()));
        let suggestions = tier.predict(&req("curl -X PSOT")).await;
        assert!(
            suggestions.is_empty(),
            "arg-value path should not fuzzy match"
        );
    }

    #[tokio::test]
    async fn fuzzy_matches_alias() {
        // "git swtich" → fuzzy matches alias "switch" (transposition, distance 1)
        let tier = SpecTier::new(make_registry(git_spec_with_aliases()));
        let suggestions = tier.predict(&req("git swtich")).await;
        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].text, "switch");
        assert!((suggestions[0].confidence - 0.70).abs() < 0.01);
    }

    #[tokio::test]
    async fn fuzzy_command_name_resolution() {
        // "gti checkout " → resolves "gti" to "git" spec, navigates into checkout,
        // suggests checkout's options (not git's root options)
        let registry = make_multi_registry(vec![git_spec_with_nested_options(), ls_spec()]);
        let tier = SpecTier::new(registry);
        let suggestions = tier.predict(&req("gti checkout ")).await;
        // Should suggest checkout's options: -b, --force, -f
        assert!(!suggestions.is_empty());
        // Verify we get checkout's options, not git's root options
        let texts: Vec<&str> = suggestions.iter().map(|s| s.text.as_str()).collect();
        assert!(
            texts
                .iter()
                .any(|t| t.contains("-b") || t.contains("--force")),
            "should suggest checkout's options, got: {:?}",
            texts
        );
        assert!(
            !texts.iter().any(|t| t.contains("--verbose")),
            "should NOT suggest git's root options, got: {:?}",
            texts
        );
        // Change C: suggestions should have replace_start=0 and text correcting "gti" to "git checkout"
        for s in &suggestions {
            assert_eq!(
                s.replace_start, 0,
                "fuzzy command correction should set replace_start=0"
            );
            assert!(
                s.text.starts_with("git checkout "),
                "suggestion text should start with 'git checkout ': {}",
                s.text
            );
        }
    }

    #[tokio::test]
    async fn global_flag_before_subcommand_still_navigates() {
        // "git -v checkout " → should skip -v and navigate into checkout
        let registry = make_multi_registry(vec![git_spec_with_nested_options(), ls_spec()]);
        let tier = SpecTier::new(registry);
        let suggestions = tier.predict(&req("git -v checkout ")).await;
        // Should suggest checkout's options, not git's root options
        assert!(!suggestions.is_empty());
        let texts: Vec<&str> = suggestions.iter().map(|s| s.text.as_str()).collect();
        assert!(
            texts
                .iter()
                .any(|t| *t == "-b" || *t == "--force" || *t == "-f"),
            "should suggest checkout's options, got: {:?}",
            texts
        );
    }

    #[tokio::test]
    async fn flag_with_argument_before_subcommand() {
        // "git -C /path checkout " → skip -C AND /path, suggest checkout's options
        let registry = make_multi_registry(vec![git_spec_with_nested_options(), ls_spec()]);
        let tier = SpecTier::new(registry);
        let suggestions = tier.predict(&req("git -C /path checkout ")).await;
        // Should suggest checkout's options
        assert!(!suggestions.is_empty());
        let texts: Vec<&str> = suggestions.iter().map(|s| s.text.as_str()).collect();
        assert!(
            texts
                .iter()
                .any(|t| *t == "-b" || *t == "--force" || *t == "-f"),
            "should suggest checkout's options after skipping -C /path, got: {:?}",
            texts
        );
    }

    #[tokio::test]
    async fn alias_navigation_uses_canonical_name() {
        // "gti co " (co = checkout alias) → suggestions prefixed with "git checkout", not "git co"
        let registry = make_multi_registry(vec![git_spec_with_nested_options(), ls_spec()]);
        let tier = SpecTier::new(registry);
        let suggestions = tier.predict(&req("gti co ")).await;
        assert!(!suggestions.is_empty());
        // Should use canonical name "checkout" in prefix, not alias "co"
        for s in &suggestions {
            assert!(
                s.text.starts_with("git checkout "),
                "should use canonical name 'git checkout', not 'git co': {}",
                s.text
            );
        }
    }

    #[tokio::test]
    async fn fuzzy_command_name_with_subcommand_typo() {
        // "gti ch" → resolves "gti" to "git", then prefix matches "checkout" / "cherry-pick"
        // Change C: text should include corrected command prefix
        let registry = make_multi_registry(vec![git_spec(), ls_spec()]);
        let tier = SpecTier::new(registry);
        let suggestions = tier.predict(&req("gti ch")).await;
        assert!(!suggestions.is_empty());
        assert!(suggestions.iter().any(|s| s.text == "git checkout"));
        assert!(suggestions.iter().any(|s| s.text == "git cherry-pick"));
        // Ghost text: plugin detects "gti ch" != "git ch" (prefix mismatch)
        // and renders hint mode ("→ git checkout") instead of misleading suffix
        for s in &suggestions {
            assert_eq!(s.replace_start, 0);
        }
    }

    #[tokio::test]
    async fn fuzzy_double_fuzzy_command_and_subcommand() {
        // "gti chekout" → fuzzy command ("gti"→"git") + fuzzy subcommand ("chekout"→"checkout")
        // Change C clears diff_ops and prepends corrected command
        let registry = make_multi_registry(vec![git_spec_with_aliases(), ls_spec()]);
        let tier = SpecTier::new(registry);
        let suggestions = tier.predict(&req("gti chekout")).await;
        assert!(!suggestions.is_empty());
        assert_eq!(suggestions[0].replace_start, 0);
        assert!(
            suggestions[0].text.starts_with("git "),
            "double-fuzzy should correct command: {}",
            suggestions[0].text
        );
        assert!(
            suggestions[0].text.contains("checkout"),
            "double-fuzzy should resolve subcommand: {}",
            suggestions[0].text
        );
    }

    #[tokio::test]
    async fn fuzzy_command_trailing_space_suggests_only_correction() {
        // "gti " → fuzzy resolves "gti" to "git", suggests ONLY the correction
        // (not full commands like "git checkout")
        let registry = make_multi_registry(vec![git_spec(), ls_spec()]);
        let tier = SpecTier::new(registry);
        let suggestions = tier.predict(&req("gti ")).await;
        assert_eq!(
            suggestions.len(),
            1,
            "should suggest only corrected command"
        );
        assert_eq!(suggestions[0].text, "git");
        assert_eq!(suggestions[0].replace_start, 0);
        assert_eq!(suggestions[0].replace_end, 3); // "gti".len(), keeps trailing space
        assert!(
            suggestions[0].diff_ops.is_some(),
            "must include diff_ops for shell rendering"
        );
    }

    #[tokio::test]
    async fn fuzzy_command_partial_subcommand_still_works() {
        // "gti ch" → partial subcommand triggers normal fuzzy+subcommand behavior
        // Should NOT be affected by the early return for fuzzy-only correction
        let registry = make_multi_registry(vec![git_spec(), ls_spec()]);
        let tier = SpecTier::new(registry);
        let suggestions = tier.predict(&req("gti ch")).await;
        assert!(!suggestions.is_empty(), "should suggest subcommands");
        assert_eq!(suggestions[0].replace_start, 0);
        assert!(
            suggestions[0].text.contains("checkout") || suggestions[0].text.contains("cherry-pick"),
            "should suggest git subcommand: {}",
            suggestions[0].text
        );
    }

    #[tokio::test]
    async fn fuzzy_command_with_valid_subcommand_context() {
        // "gti checkout " → navigates into checkout context
        // Uses git_spec_with_nested_options() which has options on checkout
        let tier = SpecTier::new(make_registry(git_spec_with_nested_options()));
        let suggestions = tier.predict(&req("gti checkout ")).await;
        // Should fall through to Change C and show checkout's options prefixed
        assert!(!suggestions.is_empty(), "should show checkout options");
        assert_eq!(suggestions[0].replace_start, 0);
        assert!(
            suggestions[0].text.starts_with("git checkout "),
            "should be prefixed with corrected command path: {}",
            suggestions[0].text
        );
    }

    #[tokio::test]
    async fn fuzzy_command_with_flag_still_suggests() {
        // "gti --ve" → flag input, falls through to Change C logic
        // Should NOT be affected by the early return for fuzzy-only correction
        let registry = make_multi_registry(vec![git_spec(), ls_spec()]);
        let tier = SpecTier::new(registry);
        let suggestions = tier.predict(&req("gti --ve")).await;
        assert!(!suggestions.is_empty(), "should suggest --verbose");
        assert_eq!(suggestions[0].replace_start, 0);
        assert!(
            suggestions[0].text.contains("--verbose"),
            "should suggest git --verbose: {}",
            suggestions[0].text
        );
    }

    #[tokio::test]
    async fn fuzzy_double_fuzzy_transposition() {
        // "gti chekcout" → fuzzy command + fuzzy subcommand (transposition)
        let registry = make_multi_registry(vec![git_spec(), ls_spec()]);
        let tier = SpecTier::new(registry);
        let suggestions = tier.predict(&req("gti chekcout")).await;
        assert!(!suggestions.is_empty());
        assert_eq!(suggestions[0].replace_start, 0);
        assert!(
            suggestions[0].text.contains("checkout"),
            "should resolve transposed subcommand: {}",
            suggestions[0].text
        );
    }

    #[tokio::test]
    async fn fuzzy_distance_exceeds_threshold() {
        // "git xyzabc" → too many edits from any subcommand, no suggestions
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("git xyzabc")).await;
        assert!(suggestions.is_empty(), "distance > 2 should yield nothing");
    }

    #[tokio::test]
    async fn short_gibberish_no_fuzzy() {
        // "git zz" → 2-char token, no prefix match, no fuzzy (too short)
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("git zz")).await;
        assert!(
            suggestions.is_empty(),
            "2-char gibberish should yield nothing"
        );
    }

    #[tokio::test]
    async fn single_char_token_no_match() {
        // "git x" → 1-char token, no prefix match, too short for fuzzy
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("git x")).await;
        assert!(suggestions.is_empty(), "1-char token should yield nothing");
    }

    #[tokio::test]
    async fn empty_input_returns_empty() {
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("")).await;
        assert!(suggestions.is_empty());
    }

    #[tokio::test]
    async fn command_only_no_space() {
        // "git" with no trailing space → no suggestions (nothing to complete yet)
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("git")).await;
        assert!(suggestions.is_empty());
    }

    #[tokio::test]
    async fn fuzzy_command_no_space() {
        // "gti" with no trailing space → suggests corrected command "git"
        let registry = make_multi_registry(vec![git_spec(), ls_spec()]);
        let tier = SpecTier::new(registry);
        let suggestions = tier.predict(&req("gti")).await;
        assert_eq!(suggestions.len(), 1, "should suggest corrected command");
        assert_eq!(suggestions[0].text, "git");
        assert_eq!(suggestions[0].replace_start, 0);
        assert_eq!(suggestions[0].replace_end, 3); // "gti".len()
        assert!(
            suggestions[0].diff_ops.is_some(),
            "must include diff_ops for shell rendering"
        );
        assert!(
            suggestions[0]
                .description
                .as_ref()
                .is_some_and(|d| d.contains("Did you mean")),
            "should have descriptive message"
        );
    }

    #[tokio::test]
    async fn extra_whitespace_fuzzy() {
        // "git  chekout" → extra space, fuzzy subcommand still works
        let tier = SpecTier::new(make_registry(git_spec()));
        let suggestions = tier.predict(&req("git  chekout")).await;
        assert!(!suggestions.is_empty());
        assert_eq!(suggestions[0].text, "checkout");
    }

    // --- Issue #23: suppress suggestions after arg-taking flags ---

    /// Build a spec with both subcommands and an arg-taking flag (the bug scenario).
    fn cmd_with_subcommands_and_arg_flag() -> CliSpec {
        CliSpec {
            name: "claude".into(),
            description: Some("AI assistant".into()),
            subcommands: vec![
                SubcommandSpec {
                    name: "prompt".into(),
                    aliases: vec![],
                    description: Some("Send a prompt".into()),
                    subcommands: vec![],
                    options: vec![],
                    args: vec![],
                },
                SubcommandSpec {
                    name: "auth".into(),
                    aliases: vec![],
                    description: Some("Manage auth".into()),
                    subcommands: vec![],
                    options: vec![],
                    args: vec![],
                },
            ],
            options: vec![
                OptionSpec {
                    names: vec!["-p".into(), "--print".into()],
                    description: Some("Print format".into()),
                    takes_arg: true,
                    is_required: false,
                    arg: None,
                },
                OptionSpec {
                    names: vec!["-v".into(), "--verbose".into()],
                    description: Some("Verbose".into()),
                    takes_arg: false,
                    is_required: false,
                    arg: None,
                },
            ],
            args: vec![],
        }
    }

    #[tokio::test]
    async fn flag_taking_arg_suppresses_subcommands() {
        // "claude -p " → -p takes_arg, should NOT suggest "prompt" or "auth" subcommands
        let tier = SpecTier::new(make_registry(cmd_with_subcommands_and_arg_flag()));
        let suggestions = tier.predict(&req("claude -p ")).await;
        assert!(
            suggestions.is_empty(),
            "should not suggest subcommands after arg-taking flag, got: {:?}",
            suggestions.iter().map(|s| &s.text).collect::<Vec<_>>()
        );
    }

    #[tokio::test]
    async fn non_arg_flag_still_suggests_subcommands() {
        // "claude -v " → -v does NOT take arg, should suggest subcommands
        let tier = SpecTier::new(make_registry(cmd_with_subcommands_and_arg_flag()));
        let suggestions = tier.predict(&req("claude -v ")).await;
        assert!(
            suggestions.iter().any(|s| s.text == "prompt"),
            "non-arg flag should allow subcommand suggestions"
        );
    }

    #[tokio::test]
    async fn stacked_flag_last_char_takes_arg_suppresses() {
        // "ls -lT " → -T takes_arg, last in stack → suppress suggestions
        let tier = SpecTier::new(make_registry(ls_spec()));
        let suggestions = tier.predict(&req("ls -lT ")).await;
        assert!(
            suggestions.is_empty(),
            "stacked flag ending in arg-taking flag should suppress suggestions"
        );
    }

    #[tokio::test]
    async fn after_arg_value_resumes_normal_suggestions() {
        // "curl -X GET " → -X takes_arg, "GET" is its value, trailing space → back to flags
        let tier = SpecTier::new(make_registry(curl_spec()));
        let suggestions = tier.predict(&req("curl -X GET ")).await;
        assert!(
            suggestions.iter().any(|s| s.text.starts_with("-")),
            "after providing arg value, should resume suggesting flags"
        );
    }

    #[tokio::test]
    async fn option_value_no_suggestions_prefix_returns_empty() {
        // "curl -o foo" → -o takes_arg, no suggestions, "foo" being typed → empty
        let tier = SpecTier::new(make_registry(curl_spec()));
        let suggestions = tier.predict(&req("curl -o foo")).await;
        assert!(
            suggestions.is_empty(),
            "should not suggest flags/subcommands when typing arg for takes_arg flag"
        );
    }

    #[tokio::test]
    async fn after_no_suggestion_arg_value_resumes() {
        // "curl -o file.txt " → -o takes_arg (no suggestions), "file.txt" consumed → resume
        let tier = SpecTier::new(make_registry(curl_spec()));
        let suggestions = tier.predict(&req("curl -o file.txt ")).await;
        assert!(
            suggestions.iter().any(|s| s.text.starts_with("-")),
            "after providing arg value to no-suggestion flag, should resume suggesting flags"
        );
    }

    #[tokio::test]
    async fn equals_syntax_does_not_trigger_suppression() {
        // "curl --request=GET " → single token with =, does not suppress next token
        let tier = SpecTier::new(make_registry(curl_spec()));
        let suggestions = tier.predict(&req("curl --request=GET ")).await;
        assert!(
            suggestions.iter().any(|s| s.text.starts_with("-")),
            "--flag=value should not suppress suggestions for the next token"
        );
    }

    #[tokio::test]
    async fn fuzzy_command_with_arg_taking_flag_suppresses() {
        // "crlu -o " → fuzzy resolves "crlu" to "curl", -o takes_arg → suppress
        let registry = make_multi_registry(vec![curl_spec()]);
        let tier = SpecTier::new(registry);
        let suggestions = tier.predict(&req("crlu -o ")).await;
        assert!(
            suggestions.is_empty(),
            "fuzzy-resolved command should still suppress on arg-taking flag"
        );
    }

    #[tokio::test]
    async fn long_form_flag_takes_arg_suppresses() {
        // "curl --request GET " → --request takes_arg, "GET" consumed → resume
        // "curl --request " → --request takes_arg → suppress
        let tier = SpecTier::new(make_registry(curl_spec()));
        let suppressed = tier.predict(&req("curl --request ")).await;
        assert!(
            suppressed.iter().all(|s| !s.text.starts_with("-")),
            "--request takes arg, should not suggest flags: {:?}",
            suppressed.iter().map(|s| &s.text).collect::<Vec<_>>()
        );
        let resumed = tier.predict(&req("curl --request GET ")).await;
        assert!(
            resumed.iter().any(|s| s.text.starts_with("-")),
            "after providing arg value to --request, should resume suggesting flags"
        );
    }

    #[tokio::test]
    async fn sequential_arg_taking_flags() {
        // "curl -X GET -o " → -X consumed by GET, then -o takes_arg → suppress
        let tier = SpecTier::new(make_registry(curl_spec()));
        let suggestions = tier.predict(&req("curl -X GET -o ")).await;
        assert!(
            suggestions.is_empty(),
            "sequential arg-taking flag should suppress: {:?}",
            suggestions.iter().map(|s| &s.text).collect::<Vec<_>>()
        );
    }
}
