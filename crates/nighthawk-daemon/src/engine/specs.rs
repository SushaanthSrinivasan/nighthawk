use async_trait::async_trait;
use nighthawk_proto::{CompletionRequest, Suggestion, SuggestionSource};
use std::collections::HashSet;

use super::tier::PredictionTier;
use crate::specs::{OptionSpec, SpecRegistry};
use std::sync::Arc;

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

        let spec = match self.registry.lookup(command) {
            Some(spec) => spec,
            None => return vec![],
        };

        // If we only have the command name, suggest subcommands
        if parts.len() == 1 && !input.ends_with(' ') {
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

        // Include current_token so we don't re-suggest the exact flag being typed
        let mut all_committed = previous_tokens.clone();
        if !current_token.is_empty() {
            all_committed.push(current_token);
        }
        let used_flags = collect_used_flags(&all_committed, &spec.options);

        let mut suggestions = Vec::new();

        // Match subcommands
        for sub in &spec.subcommands {
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
                });
            }
        }

        // Match options by prefix
        for opt in &spec.options {
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
            let exact_flag_no_arg = spec.options.iter().any(|opt| {
                !opt.takes_arg
                    && opt
                        .names
                        .iter()
                        .any(|n| n == current_token && is_single_char_flag(n))
            });

            if exact_flag_no_arg {
                for (ch, opt) in stackable_flags(&spec.options) {
                    let flag_name = format!("-{}", ch);
                    if !used_flags.contains(&flag_name) {
                        suggestions.push(Suggestion {
                            text: format!("{}{}", current_token, ch),
                            replace_start: token_start,
                            replace_end: req.cursor,
                            confidence: 0.8,
                            source: SuggestionSource::Spec,
                            description: opt.description.clone(),
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
                        let stackable = stackable_flags(&spec.options);
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
        suggestions
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::specs::{CliSpec, OptionSpec, SpecProvider, SpecRegistry, SubcommandSpec};
    use nighthawk_proto::{Shell, SuggestionSource};
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
                },
                OptionSpec {
                    names: vec!["-a".into()],
                    description: Some("Show hidden".into()),
                    takes_arg: false,
                    is_required: false,
                },
                OptionSpec {
                    names: vec!["-h".into()],
                    description: Some("Human sizes".into()),
                    takes_arg: false,
                    is_required: false,
                },
                OptionSpec {
                    names: vec!["-R".into()],
                    description: Some("Recursive".into()),
                    takes_arg: false,
                    is_required: false,
                },
                OptionSpec {
                    names: vec!["-t".into()],
                    description: Some("Sort by time".into()),
                    takes_arg: false,
                    is_required: false,
                },
                OptionSpec {
                    names: vec!["-T".into()],
                    description: Some("Tab size".into()),
                    takes_arg: true,
                    is_required: false,
                },
                OptionSpec {
                    names: vec!["--color".into()],
                    description: Some("Colorize output".into()),
                    takes_arg: true,
                    is_required: false,
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
            }],
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
                },
                OptionSpec {
                    names: vec!["-x".into()],
                    description: Some("X flag".into()),
                    takes_arg: false,
                    is_required: false,
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
}
