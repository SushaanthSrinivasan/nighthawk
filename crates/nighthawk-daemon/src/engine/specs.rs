use async_trait::async_trait;
use nighthawk_proto::{CompletionRequest, Suggestion, SuggestionSource};

use super::tier::PredictionTier;
use crate::specs::SpecRegistry;
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

        // Match options
        for opt in &spec.options {
            for name in &opt.names {
                if name.starts_with(current_token) && name != current_token {
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

        suggestions.sort_by(|a, b| b.confidence.partial_cmp(&a.confidence).unwrap());
        suggestions.truncate(5);
        suggestions
    }
}
