pub mod file;

/// A shell history entry.
#[derive(Debug, Clone)]
pub struct HistoryEntry {
    pub command: String,
    pub timestamp: Option<i64>,
    pub frequency: u32,
}

/// Trait for shell history backends.
pub trait ShellHistory: Send + Sync {
    /// Load or refresh history entries from the source.
    fn load(&mut self) -> Result<(), Box<dyn std::error::Error + Send + Sync>>;

    /// Find commands matching the given prefix, ranked by recency/frequency.
    fn search_prefix(&self, prefix: &str, limit: usize) -> Vec<HistoryEntry>;
}
