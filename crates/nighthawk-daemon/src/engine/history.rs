use async_trait::async_trait;
use nighthawk_proto::{CompletionRequest, Suggestion, SuggestionSource};

use super::tier::PredictionTier;
use crate::history::ShellHistory;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Tier 0: History prefix matching.
/// Looks up commands the user has typed before, ranked by recency/frequency.
/// Must complete in under 1ms.
pub struct HistoryTier {
    history: Arc<RwLock<dyn ShellHistory>>,
}

impl HistoryTier {
    pub fn new(history: Arc<RwLock<dyn ShellHistory>>) -> Self {
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
