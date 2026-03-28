pub mod history;
pub mod specs;
pub mod tier;

use nighthawk_proto::{CompletionRequest, CompletionResponse};
use tier::PredictionTier;
use tracing::{debug, warn};

/// Orchestrates the tiered prediction cascade.
///
/// Tiers run in order (fast first). The engine returns the first
/// tier's results that produce suggestions. Future: fire slower
/// tiers in background for potential upgrades.
pub struct PredictionEngine {
    tiers: Vec<Box<dyn PredictionTier>>,
}

impl PredictionEngine {
    pub fn new(tiers: Vec<Box<dyn PredictionTier>>) -> Self {
        Self { tiers }
    }

    /// Run the prediction cascade and return the best suggestions.
    pub async fn complete(&self, req: &CompletionRequest) -> CompletionResponse {
        for tier in &self.tiers {
            match tokio::time::timeout(
                std::time::Duration::from_millis(tier.budget_ms() as u64 + 50),
                tier.predict(req),
            )
            .await
            {
                Ok(suggestions) if !suggestions.is_empty() => {
                    debug!(
                        tier = tier.name(),
                        count = suggestions.len(),
                        "Tier produced suggestions"
                    );
                    return CompletionResponse { suggestions };
                }
                Ok(_) => {
                    debug!(tier = tier.name(), "Tier returned no suggestions");
                }
                Err(_) => {
                    warn!(
                        tier = tier.name(),
                        budget_ms = tier.budget_ms(),
                        "Tier exceeded budget"
                    );
                }
            }
        }

        CompletionResponse {
            suggestions: vec![],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use nighthawk_proto::{Shell, Suggestion, SuggestionSource};
    use std::path::PathBuf;

    struct MockTier {
        suggestions: Vec<Suggestion>,
    }

    #[async_trait]
    impl PredictionTier for MockTier {
        fn name(&self) -> &str {
            "mock"
        }
        fn budget_ms(&self) -> u32 {
            10
        }
        async fn predict(&self, _req: &CompletionRequest) -> Vec<Suggestion> {
            self.suggestions.clone()
        }
    }

    fn test_request() -> CompletionRequest {
        CompletionRequest {
            input: "git ch".into(),
            cursor: 6,
            cwd: PathBuf::from("/tmp"),
            shell: Shell::Zsh,
        }
    }

    #[tokio::test]
    async fn empty_tiers_return_empty() {
        let engine = PredictionEngine::new(vec![]);
        let resp = engine.complete(&test_request()).await;
        assert!(resp.suggestions.is_empty());
    }

    #[tokio::test]
    async fn first_tier_with_results_wins() {
        let tier1 = MockTier {
            suggestions: vec![Suggestion {
                text: "checkout".into(),
                replace_start: 4,
                replace_end: 6,
                confidence: 0.9,
                source: SuggestionSource::Spec,
                description: None,
            }],
        };
        let tier2 = MockTier {
            suggestions: vec![Suggestion {
                text: "from-tier2".into(),
                replace_start: 0,
                replace_end: 6,
                confidence: 0.5,
                source: SuggestionSource::History,
                description: None,
            }],
        };

        let engine = PredictionEngine::new(vec![Box::new(tier1), Box::new(tier2)]);
        let resp = engine.complete(&test_request()).await;
        assert_eq!(resp.suggestions.len(), 1);
        assert_eq!(resp.suggestions[0].text, "checkout");
    }

    #[tokio::test]
    async fn skips_empty_tier() {
        let empty_tier = MockTier {
            suggestions: vec![],
        };
        let real_tier = MockTier {
            suggestions: vec![Suggestion {
                text: "cherry-pick".into(),
                replace_start: 4,
                replace_end: 6,
                confidence: 0.7,
                source: SuggestionSource::History,
                description: None,
            }],
        };

        let engine = PredictionEngine::new(vec![Box::new(empty_tier), Box::new(real_tier)]);
        let resp = engine.complete(&test_request()).await;
        assert_eq!(resp.suggestions[0].text, "cherry-pick");
    }
}
