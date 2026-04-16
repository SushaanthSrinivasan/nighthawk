use crate::daemon::fuzzy;
use crate::proto::{CompletionRequest, Suggestion, SuggestionSource};
use async_trait::async_trait;

use super::tier::PredictionTier;
use crate::daemon::history::file::FileHistory;
use crate::daemon::history::ShellHistory; // Trait must be in scope to call its methods
use std::sync::Arc;
use tokio::sync::RwLock;

/// Tier 0: History prefix matching.
/// Looks up commands the user has typed before, ranked by recency/frequency.
/// Must complete in under 1ms.
pub struct HistoryTier {
    // Use concrete FileHistory type to allow calling reload_if_changed()
    history: Arc<RwLock<FileHistory>>,
}

impl HistoryTier {
    pub fn new(history: Arc<RwLock<FileHistory>>) -> Self {
        Self { history }
    }
}

#[async_trait]
impl PredictionTier for HistoryTier {
    fn name(&self) -> &str {
        "history"
    }

    fn budget_ms(&self) -> u32 {
        1
    }

    async fn predict(&self, req: &CompletionRequest) -> Vec<Suggestion> {
        let input = &req.input[..req.cursor];
        if input.is_empty() {
            return vec![];
        }

        // Check for history file changes before searching (hot-reload)
        {
            let mut history = self.history.write().await;
            history.reload_if_changed();
        }

        let history = self.history.read().await;
        let entries = history.search_prefix(input, 5);

        if !entries.is_empty() {
            // Fast path: exact prefix match
            return entries
                .into_iter()
                .map(|entry| {
                    let suffix = &entry.command[input.len()..];
                    Suggestion {
                        text: suffix.to_string(),
                        replace_start: req.cursor,
                        replace_end: req.cursor,
                        confidence: 0.8,
                        source: SuggestionSource::History,
                        description: None,
                        diff_ops: None,
                    }
                })
                .collect();
        }

        // Fuzzy fallback: try correcting the first token
        Self::try_fuzzy_fallback(input, &history)
    }
}

impl HistoryTier {
    /// Fuzzy fallback when prefix matching fails.
    /// Corrects typos in the first token (command name), then re-searches history.
    fn try_fuzzy_fallback(input: &str, history: &FileHistory) -> Vec<Suggestion> {
        // Extract first token using split_whitespace to handle leading whitespace correctly
        let first_token = match input.split_whitespace().next() {
            Some(token) => token,
            None => return vec![], // Input is empty or only whitespace
        };

        // Check if token is long enough for fuzzy matching
        if fuzzy::max_distance_for_length(first_token.len()).is_none() {
            return vec![];
        }

        // Get the rest of the input after the first token
        let rest = input
            .find(first_token)
            .map(|pos| &input[pos + first_token.len()..])
            .unwrap_or("");

        // Get unique command names from history (preserves frequency order)
        let command_names = history.command_names();

        // Find fuzzy matches
        let mut matches = fuzzy::fuzzy_matches(first_token, command_names.iter().copied());

        if matches.is_empty() {
            return vec![];
        }

        // Re-sort by (distance, position) to prefer higher-frequency commands at equal distance
        // command_names is already in frequency order, so position = frequency rank
        matches.sort_by(|a, b| {
            let pos_a = command_names
                .iter()
                .position(|&c| c == a.text)
                .unwrap_or(usize::MAX);
            let pos_b = command_names
                .iter()
                .position(|&c| c == b.text)
                .unwrap_or(usize::MAX);
            a.distance.cmp(&b.distance).then(pos_a.cmp(&pos_b))
        });

        // Take best match
        let best = &matches[0];
        let corrected_command = &best.text;

        // Reconstruct query with corrected command (avoid allocation if rest is empty)
        let corrected_query = if rest.is_empty() {
            corrected_command.clone()
        } else {
            format!("{}{}", corrected_command, rest)
        };

        // Re-search with corrected query
        let entries = history.search_prefix(&corrected_query, 5);

        if entries.is_empty() {
            return vec![];
        }

        // Compute diff ops for the correction
        let diff_ops = fuzzy::diff_ops(first_token, corrected_command);

        // Distance-aware confidence: 0.70 for dist 1, 0.55 for dist 2
        let confidence = if best.distance == 1 { 0.70 } else { 0.55 };

        entries
            .into_iter()
            .map(|entry| Suggestion {
                text: entry.command.clone(),
                replace_start: 0, // Full replacement from start
                replace_end: 0,   // Will be set by caller based on cursor
                confidence,
                source: SuggestionSource::History,
                description: None,
                diff_ops: Some(diff_ops.clone()),
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::{DiffOp, Shell};
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn create_history_with_entries(entries: &[&str]) -> FileHistory {
        let mut tmp = NamedTempFile::new().unwrap();
        for entry in entries {
            writeln!(tmp, "{}", entry).unwrap();
        }
        let mut history = FileHistory::with_path(Shell::Bash, tmp.path().to_path_buf());
        history.load().unwrap();
        history
    }

    #[test]
    fn fuzzy_corrects_typo_in_command() {
        // "cclaude" should fuzzy-match to "claude"
        let history = create_history_with_entries(&[
            "claude remote-control",
            "claude --resume",
            "git status",
        ]);

        let results = HistoryTier::try_fuzzy_fallback("cclaude rem", &history);

        assert_eq!(results.len(), 1);
        assert_eq!(results[0].text, "claude remote-control");
        assert_eq!(results[0].replace_start, 0);
        assert!(results[0].diff_ops.is_some());
    }

    #[test]
    fn fuzzy_preserves_rest_of_input() {
        let history = create_history_with_entries(&["cargo build --release", "cargo test"]);

        let results = HistoryTier::try_fuzzy_fallback("crago build", &history);

        assert_eq!(results.len(), 1);
        assert_eq!(results[0].text, "cargo build --release");
    }

    #[test]
    fn fuzzy_skips_short_tokens() {
        // "gi" is too short for fuzzy matching (len <= 2)
        let history = create_history_with_entries(&["git status", "go build"]);

        let results = HistoryTier::try_fuzzy_fallback("gi", &history);

        assert!(results.is_empty());
    }

    #[test]
    fn fuzzy_distance_one_confidence() {
        // Single character typo = distance 1 → confidence 0.70
        let history = create_history_with_entries(&["cargo build"]);

        let results = HistoryTier::try_fuzzy_fallback("crago", &history);

        assert_eq!(results.len(), 1);
        assert!((results[0].confidence - 0.70).abs() < 0.001);
    }

    #[test]
    fn fuzzy_distance_two_confidence() {
        // Two character typos = distance 2 → confidence 0.55
        // "chckot" → "checkout" (missing 'e' and 'u')
        let history = create_history_with_entries(&["checkout main"]);

        let results = HistoryTier::try_fuzzy_fallback("chckot", &history);

        assert_eq!(results.len(), 1);
        assert!((results[0].confidence - 0.55).abs() < 0.001);
    }

    #[test]
    fn fuzzy_prefers_higher_frequency() {
        // "claud" at distance 1 could match both "claude" and "claud"
        // But since we look for fuzzy (dist > 0), and exact is excluded,
        // we test that among equal distances, higher frequency wins
        let history = create_history_with_entries(&[
            // "cargo" appears 3 times (highest frequency)
            "cargo build",
            "cargo test",
            "cargo run",
            // "crago" appears once (if it existed) - but we use "cargi" to test
            "cargi something",
        ]);

        // "cargi" at distance 1 could match "cargo"
        // "cargo" has higher frequency, so it should be chosen
        let results = HistoryTier::try_fuzzy_fallback("cargi", &history);

        // Should correct to "cargo" (higher frequency) not stay as "cargi" (exact, excluded)
        assert!(!results.is_empty());
        assert!(results[0].text.starts_with("cargo"));
    }

    #[test]
    fn fuzzy_diff_ops_correct() {
        let history = create_history_with_entries(&["cargo build"]);

        let results = HistoryTier::try_fuzzy_fallback("crago", &history);

        assert!(!results.is_empty());
        let diff_ops = results[0].diff_ops.as_ref().unwrap();

        // "crago" → "cargo" should have transposition of 'a' and 'r'
        // The diff should allow reconstructing "cargo" from "crago"
        assert!(!diff_ops.is_empty());

        // Verify diff ops can reconstruct the correction
        let mut typed = String::new();
        let mut corrected = String::new();
        for op in diff_ops {
            match op {
                DiffOp::Keep(c) => {
                    typed.push(*c);
                    corrected.push(*c);
                }
                DiffOp::Delete(c) => typed.push(*c),
                DiffOp::Insert(c) => corrected.push(*c),
            }
        }
        assert_eq!(typed, "crago");
        assert_eq!(corrected, "cargo");
    }

    #[test]
    fn fuzzy_returns_empty_when_no_match() {
        let history = create_history_with_entries(&["git status", "cargo build"]);

        // "zzzzz" won't fuzzy match anything
        let results = HistoryTier::try_fuzzy_fallback("zzzzz", &history);

        assert!(results.is_empty());
    }

    #[test]
    fn fuzzy_returns_empty_when_corrected_query_has_no_prefix_match() {
        let history = create_history_with_entries(&["cargo build"]);

        // "crago xyz" corrects to "cargo xyz" but no history entry starts with "cargo xyz"
        let results = HistoryTier::try_fuzzy_fallback("crago xyz", &history);

        assert!(results.is_empty());
    }

    #[test]
    fn fuzzy_handles_leading_whitespace() {
        let history = create_history_with_entries(&["cargo build"]);

        // Leading whitespace should be handled - first real token is "crago"
        let results = HistoryTier::try_fuzzy_fallback("  crago", &history);

        assert_eq!(results.len(), 1);
        assert!(results[0].text.starts_with("cargo"));
    }

    #[test]
    fn fuzzy_handles_whitespace_only_input() {
        let history = create_history_with_entries(&["cargo build"]);

        // Whitespace-only input should return empty
        let results = HistoryTier::try_fuzzy_fallback("   ", &history);

        assert!(results.is_empty());
    }
}
