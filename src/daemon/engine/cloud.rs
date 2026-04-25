//! Cloud LLM Tier (Tier 3): Intent-aware command synthesis using cloud APIs.
//!
//! Unlike the local LLM tier which does token completion, this tier reasons
//! about what the user is trying to accomplish and suggests sophisticated
//! commands they may not have known to type.

use super::tier::PredictionTier;
use crate::daemon::config::{CloudConfig, CloudProvider};
use crate::daemon::history::file::FileHistory;
use crate::proto::{CompletionRequest, Shell, Suggestion, SuggestionSource};
use async_trait::async_trait;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;
use tracing::{debug, warn};

const SYSTEM_PROMPT: &str = r#"You are an expert terminal command synthesizer. Analyze the user's INTENT based on their partial command and recent history, then suggest a sophisticated command they may not have known to type.

OUTPUT FORMAT (exactly two lines):
COMMAND: <complete shell command>
DESCRIPTION: <5-10 word explanation of what this does>

RULES:
- Suggest ONE complete, ready-to-execute command
- Include useful flags the user might not know
- Consider the working directory and shell type
- The description MUST explain what the command does (for user safety)
- If you cannot suggest anything useful, output: NONE

EXAMPLES:
Input: "docker logs" after container issues
COMMAND: docker logs myapp --tail 100 --follow
DESCRIPTION: Stream last 100 log lines from myapp container

Input: "find ." in a git repo
COMMAND: find . -type f -name '*.rs' -mtime -1
DESCRIPTION: Find Rust files modified in the last day

Input: "git log"
COMMAND: git log --oneline --graph -20
DESCRIPTION: Show visual commit graph of last 20 commits"#;

// ── OpenAI-compatible API types ─────────────────────────────────

#[derive(Serialize)]
struct ChatRequest {
    model: String,
    messages: Vec<ChatMessage>,
    temperature: f32,
    max_tokens: u32,
    stream: bool,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    stop: Vec<String>,
}

#[derive(Serialize)]
struct ChatMessage {
    role: String,
    content: String,
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<ChatChoice>,
}

#[derive(Deserialize)]
struct ChatChoice {
    message: ChatResponseMessage,
}

#[derive(Deserialize)]
struct ChatResponseMessage {
    content: Option<String>,
}

// ── Provider trait for extensibility ────────────────────────────

#[derive(Debug, thiserror::Error)]
pub enum ProviderError {
    #[error("HTTP request failed: {0}")]
    Http(#[from] reqwest::Error),
    #[error("Authentication failed (401/403) — check API key")]
    Auth,
    #[error("Rate limited (429) — try again later")]
    RateLimited,
    #[error("API error ({0})")]
    Api(u16),
    #[error("Empty response from provider")]
    EmptyResponse,
}

/// Trait for cloud LLM providers. Implement this to add new providers.
#[async_trait]
trait CloudProviderImpl: Send + Sync {
    async fn complete(&self, system: &str, user: &str) -> Result<String, ProviderError>;
}

// ── OpenAI-compatible provider (OpenAI + Groq) ──────────────────

struct OpenAICompatProvider {
    client: Client,
    base_url: String,
    api_key: String,
    model: String,
    max_tokens: u32,
    temperature: f32,
}

#[async_trait]
impl CloudProviderImpl for OpenAICompatProvider {
    async fn complete(&self, system: &str, user: &str) -> Result<String, ProviderError> {
        let url = format!("{}/chat/completions", self.base_url.trim_end_matches('/'));
        let req = ChatRequest {
            model: self.model.clone(),
            messages: vec![
                ChatMessage {
                    role: "system".into(),
                    content: system.into(),
                },
                ChatMessage {
                    role: "user".into(),
                    content: user.into(),
                },
            ],
            temperature: self.temperature,
            max_tokens: self.max_tokens,
            stream: false,
            stop: vec![],
        };

        let resp = self
            .client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.api_key))
            .json(&req)
            .send()
            .await?;

        match resp.status().as_u16() {
            401 | 403 => return Err(ProviderError::Auth),
            429 => return Err(ProviderError::RateLimited),
            s if s >= 400 => return Err(ProviderError::Api(s)),
            _ => {}
        }

        let chat_resp: ChatResponse = resp.json().await?;
        chat_resp
            .choices
            .first()
            .and_then(|c| c.message.content.clone())
            .ok_or(ProviderError::EmptyResponse)
    }
}

// ── Anthropic provider ──────────────────────────────────────────

struct AnthropicProvider {
    client: Client,
    base_url: String,
    api_key: String,
    model: String,
    max_tokens: u32,
    temperature: f32,
}

#[async_trait]
impl CloudProviderImpl for AnthropicProvider {
    async fn complete(&self, system: &str, user: &str) -> Result<String, ProviderError> {
        let url = format!("{}/v1/messages", self.base_url.trim_end_matches('/'));

        let body = serde_json::json!({
            "model": self.model,
            "max_tokens": self.max_tokens,
            "system": system,
            "messages": [{"role": "user", "content": user}],
            "temperature": self.temperature
        });

        let resp = self
            .client
            .post(&url)
            .header("x-api-key", &self.api_key)
            .header("anthropic-version", "2023-06-01")
            .header("content-type", "application/json")
            .json(&body)
            .send()
            .await?;

        match resp.status().as_u16() {
            401 | 403 => return Err(ProviderError::Auth),
            429 => return Err(ProviderError::RateLimited),
            s if s >= 400 => return Err(ProviderError::Api(s)),
            _ => {}
        }

        let json: serde_json::Value = resp.json().await?;
        json["content"][0]["text"]
            .as_str()
            .map(String::from)
            .ok_or(ProviderError::EmptyResponse)
    }
}

// ── CloudTier implementation ────────────────────────────────────

pub struct CloudTier {
    provider: Box<dyn CloudProviderImpl>,
    config: CloudConfig,
    histories: Arc<RwLock<[FileHistory; 5]>>,
    has_warned: AtomicBool,
}

impl CloudTier {
    /// Create CloudTier. Returns None if API key is missing (logs warning).
    pub fn new(config: CloudConfig, histories: Arc<RwLock<[FileHistory; 5]>>) -> Option<Self> {
        let api_key = match config.api_key() {
            Some(key) => key,
            None => {
                let env_var = match config.provider {
                    CloudProvider::OpenAI => "OPENAI_API_KEY",
                    CloudProvider::Anthropic => "ANTHROPIC_API_KEY",
                    CloudProvider::Groq => "GROQ_API_KEY",
                };
                warn!(
                    provider = ?config.provider,
                    "Cloud LLM tier disabled: set {} or cloud.api_key in config",
                    env_var
                );
                return None;
            }
        };

        let model = config
            .model
            .clone()
            .unwrap_or_else(|| config.default_model().to_string());
        let base_url = config
            .base_url
            .clone()
            .unwrap_or_else(|| config.default_base_url().to_string());

        // HTTP timeout with safety margin
        let http_timeout = config.budget_ms.saturating_sub(100);
        let client = match Client::builder()
            .connect_timeout(Duration::from_millis(500))
            .timeout(Duration::from_millis(http_timeout as u64))
            .build()
        {
            Ok(c) => c,
            Err(e) => {
                warn!(error = %e, "Failed to create HTTP client for cloud tier");
                return None;
            }
        };

        let provider: Box<dyn CloudProviderImpl> = match config.provider {
            CloudProvider::OpenAI | CloudProvider::Groq => Box::new(OpenAICompatProvider {
                client,
                base_url,
                api_key,
                model,
                max_tokens: config.max_tokens,
                temperature: config.temperature,
            }),
            CloudProvider::Anthropic => Box::new(AnthropicProvider {
                client,
                base_url,
                api_key,
                model,
                max_tokens: config.max_tokens,
                temperature: config.temperature,
            }),
        };

        Some(Self {
            provider,
            config,
            histories,
            has_warned: AtomicBool::new(false),
        })
    }

    /// Get recent commands from shell history (stateless read at request time)
    async fn get_recent_history(&self, shell: Shell, limit: usize) -> Vec<String> {
        let histories = self.histories.read().await;
        let idx = shell.index();
        histories[idx]
            .entries()
            .iter()
            .take(limit)
            .map(|e| e.command.clone())
            .collect()
    }
}

#[async_trait]
impl PredictionTier for CloudTier {
    fn name(&self) -> &str {
        "cloud-llm"
    }

    fn budget_ms(&self) -> u32 {
        self.config.budget_ms
    }

    async fn predict(&self, req: &CompletionRequest) -> Vec<Suggestion> {
        let input = &req.input[..req.cursor];
        if input.trim().is_empty() {
            return vec![];
        }

        // Get recent history (stateless read)
        let history = self
            .get_recent_history(req.shell, self.config.history_context_size)
            .await;

        // Build prompt
        let history_text = if history.is_empty() {
            String::new()
        } else {
            format!(
                "\n\nRecent commands:\n{}",
                history
                    .iter()
                    .map(|c| format!("- {}", c))
                    .collect::<Vec<_>>()
                    .join("\n")
            )
        };

        let user_prompt = format!(
            "Shell: {}\nWorking directory: {}\nCurrent input: {}{}",
            req.shell.as_str(),
            req.cwd.display(),
            input,
            history_text
        );

        // Call provider
        let raw = match self.provider.complete(SYSTEM_PROMPT, &user_prompt).await {
            Ok(r) => r,
            Err(ProviderError::Auth) => {
                warn!("Cloud LLM: authentication failed — check API key");
                return vec![];
            }
            Err(ProviderError::RateLimited) => {
                warn!("Cloud LLM: rate limited (429) — try again later");
                return vec![];
            }
            Err(e) => {
                if self
                    .has_warned
                    .compare_exchange(false, true, Ordering::Relaxed, Ordering::Relaxed)
                    .is_ok()
                {
                    warn!(error = %e, "Cloud LLM: request failed");
                } else {
                    debug!(error = %e, "Cloud LLM request failed");
                }
                return vec![];
            }
        };

        // Parse response
        let (command, description) = parse_cloud_response(&raw);
        let Some(command) = command else {
            return vec![];
        };

        vec![Suggestion {
            text: command,
            replace_start: 0,
            replace_end: req.input.len(),
            confidence: 0.7,
            source: SuggestionSource::CloudModel,
            description,
            diff_ops: None,
        }]
    }
}

fn parse_cloud_response(raw: &str) -> (Option<String>, Option<String>) {
    let raw = raw.trim();
    if raw.eq_ignore_ascii_case("none") {
        return (None, None);
    }

    let mut command = None;
    let mut description = None;

    for line in raw.lines() {
        let line = line.trim();
        if let Some(cmd) = line.strip_prefix("COMMAND:") {
            command = Some(cmd.trim().to_string());
        } else if let Some(desc) = line.strip_prefix("DESCRIPTION:") {
            description = Some(desc.trim().to_string());
        }
    }

    // Fallback: first non-empty line as command
    if command.is_none() {
        command = raw
            .lines()
            .find(|l| !l.trim().is_empty())
            .map(|l| l.trim().to_string());
    }

    (command, description)
}

// ── Tests ───────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_structured_response() {
        let raw = "COMMAND: docker logs myapp --tail 100\nDESCRIPTION: Show last 100 log lines";
        let (cmd, desc) = parse_cloud_response(raw);
        assert_eq!(cmd, Some("docker logs myapp --tail 100".into()));
        assert_eq!(desc, Some("Show last 100 log lines".into()));
    }

    #[test]
    fn parse_none_response() {
        let (cmd, desc) = parse_cloud_response("NONE");
        assert!(cmd.is_none());
        assert!(desc.is_none());

        let (cmd, desc) = parse_cloud_response("none");
        assert!(cmd.is_none());
        assert!(desc.is_none());
    }

    #[test]
    fn parse_fallback_unstructured() {
        let raw = "git log --oneline -20";
        let (cmd, desc) = parse_cloud_response(raw);
        assert_eq!(cmd, Some("git log --oneline -20".into()));
        assert!(desc.is_none());
    }

    #[test]
    fn parse_with_extra_whitespace() {
        let raw = "  COMMAND:   find . -name '*.rs'  \n  DESCRIPTION:   Find Rust files  ";
        let (cmd, desc) = parse_cloud_response(raw);
        assert_eq!(cmd, Some("find . -name '*.rs'".into()));
        assert_eq!(desc, Some("Find Rust files".into()));
    }

    #[test]
    fn parse_empty_response() {
        let (cmd, desc) = parse_cloud_response("");
        assert!(cmd.is_none());
        assert!(desc.is_none());

        let (cmd, desc) = parse_cloud_response("   \n   ");
        assert!(cmd.is_none());
        assert!(desc.is_none());
    }
}
