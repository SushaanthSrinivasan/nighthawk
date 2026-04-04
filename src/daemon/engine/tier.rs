use crate::proto::{CompletionRequest, Suggestion};
use async_trait::async_trait;

/// A prediction tier in the completion cascade.
///
/// Tiers are ordered by latency: fast tiers run first, slow tiers
/// only run if fast tiers don't produce high-confidence results.
///
/// Implementors must respect their `budget_ms()` — the engine may
/// cancel tiers that exceed their budget.
#[async_trait]
pub trait PredictionTier: Send + Sync {
    /// Human-readable name for logging ("history", "specs", "local-llm").
    fn name(&self) -> &str;

    /// Maximum latency budget in milliseconds.
    fn budget_ms(&self) -> u32;

    /// Generate suggestions for the given request.
    /// Return empty vec if this tier has nothing to offer.
    /// Never panic — log errors and return empty vec.
    async fn predict(&self, req: &CompletionRequest) -> Vec<Suggestion>;
}
