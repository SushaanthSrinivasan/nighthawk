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

        entries
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
            .collect()
    }
}
