#[cfg(feature = "cloud-llm")]
pub mod cloud;
pub mod history;
#[cfg(feature = "local-llm")]
pub mod llm;
pub mod specs;
pub mod tier;

use crate::proto::{CompletionRequest, CompletionResponse};
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
        // Every tier slices `&req.input[..req.cursor]`, which PANICS if `cursor` is past
        // the end or not on a UTF-8 char boundary — e.g. a client that sends a character
        // index where the protocol wants a byte offset (the pre-fix zsh/bash plugins did
        // exactly this, crashing a worker on any multibyte input). Sanitize once here, at
        // the single entry point, by snapping the cursor down to the nearest valid
        // boundary; the clone only happens on the rare bad-cursor path.
        let sanitized;
        let req = if req.cursor > req.input.len() || !req.input.is_char_boundary(req.cursor) {
            let mut c = req.cursor.min(req.input.len());
            while c > 0 && !req.input.is_char_boundary(c) {
                c -= 1;
            }
            debug!(from = req.cursor, to = c, "Sanitized out-of-bounds cursor");
            sanitized = CompletionRequest {
                cursor: c,
                ..req.clone()
            };
            &sanitized
        } else {
            req
        };

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
    use crate::proto::{Shell, Suggestion, SuggestionSource};
    use async_trait::async_trait;
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
                diff_ops: None,
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
                diff_ops: None,
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
                diff_ops: None,
            }],
        };

        let engine = PredictionEngine::new(vec![Box::new(empty_tier), Box::new(real_tier)]);
        let resp = engine.complete(&test_request()).await;
        assert_eq!(resp.suggestions[0].text, "cherry-pick");
    }

    /// Tier that slices `&req.input[..req.cursor]` exactly as the real tiers do (history,
    /// specs, cloud, llm all open with that line) and echoes the cursor it actually saw.
    /// If the engine fails to sanitize a bad cursor, the slice here panics — that's the
    /// regression these tests guard.
    struct EchoCursorTier;

    #[async_trait]
    impl PredictionTier for EchoCursorTier {
        fn name(&self) -> &str {
            "echo-cursor"
        }
        fn budget_ms(&self) -> u32 {
            10
        }
        async fn predict(&self, req: &CompletionRequest) -> Vec<Suggestion> {
            let prefix = &req.input[..req.cursor];
            vec![Suggestion {
                text: format!("cursor={} prefix={}", req.cursor, prefix),
                replace_start: req.cursor,
                replace_end: req.cursor,
                confidence: 1.0,
                source: SuggestionSource::History,
                description: None,
                diff_ops: None,
            }]
        }
    }

    #[tokio::test]
    async fn sanitizes_cursor_inside_multibyte_char() {
        // "café": é occupies bytes 3-4, so byte 4 is INSIDE the 2-byte sequence (not a
        // char boundary). The pre-fix code panicked here on every multibyte buffer.
        let req = CompletionRequest {
            input: "café".into(),
            cursor: 4,
            cwd: PathBuf::from("/tmp"),
            shell: Shell::Zsh,
        };
        let engine = PredictionEngine::new(vec![Box::new(EchoCursorTier)]);
        let resp = engine.complete(&req).await; // must not panic
                                                // Snapped down to the boundary before é.
        assert_eq!(resp.suggestions[0].text, "cursor=3 prefix=caf");
    }

    #[tokio::test]
    async fn sanitizes_cursor_past_end() {
        let req = CompletionRequest {
            input: "git".into(),
            cursor: 99,
            cwd: PathBuf::from("/tmp"),
            shell: Shell::Zsh,
        };
        let engine = PredictionEngine::new(vec![Box::new(EchoCursorTier)]);
        let resp = engine.complete(&req).await; // must not panic
        assert_eq!(resp.suggestions[0].text, "cursor=3 prefix=git");
    }

    #[tokio::test]
    async fn valid_cursor_is_unchanged() {
        // "git ch" len 6, cursor 6 is a valid boundary — must pass through untouched.
        let engine = PredictionEngine::new(vec![Box::new(EchoCursorTier)]);
        let resp = engine.complete(&test_request()).await;
        assert_eq!(resp.suggestions[0].text, "cursor=6 prefix=git ch");
    }
}
