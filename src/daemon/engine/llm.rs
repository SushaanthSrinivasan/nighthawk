use super::tier::PredictionTier;
use crate::daemon::config::LlmConfig;
use crate::proto::{CompletionRequest, Suggestion, SuggestionSource};
use async_trait::async_trait;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, Ordering};
use tracing::{debug, warn};

const DEFAULT_SYSTEM_PROMPT: &str = "\
You are a terminal command autocomplete engine. \
Given a partial shell command, output ONLY the text that should be appended \
after the cursor to complete the command. Do not repeat text before the cursor. \
Do not add explanation, markdown, or quotes. Output only the raw completion text. \
If you cannot suggest anything, output nothing.";

/// Maximum number of input characters to send to the LLM.
/// Prevents exceeding model context windows on very long inputs.
const MAX_INPUT_CHARS: usize = 2048;

pub struct LlmTier {
    client: Client,
    config: LlmConfig,
    system_prompt: String,
    /// Tracks whether we've already warned about a connection failure,
    /// so subsequent failures log at debug instead of warn.
    has_warned_connection: AtomicBool,
}

// ── OpenAI-compatible API types (private) ───────────────────────

#[derive(Serialize)]
struct ChatRequest {
    model: String,
    messages: Vec<ChatMessage>,
    temperature: f32,
    max_tokens: u32,
    stream: bool,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    stop: Vec<String>,
    /// Disable reasoning/thinking mode for models that support it.
    /// SGLang uses chat_template_kwargs, others may ignore this field.
    #[serde(skip_serializing_if = "Option::is_none")]
    chat_template_kwargs: Option<ChatTemplateKwargs>,
}

#[derive(Serialize)]
struct ChatTemplateKwargs {
    enable_thinking: bool,
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
    /// The main response content. Can be null for reasoning models
    /// that put all output into reasoning_content.
    content: Option<String>,
    /// Reasoning models (Qwen3, DeepSeek-R1) put thinking here
    /// when served with a reasoning parser (e.g. SGLang --reasoning-parser).
    #[serde(default)]
    #[allow(dead_code)]
    reasoning_content: Option<String>,
}

// ── Construction ────────────────────────────────────────────────

impl LlmTier {
    pub fn new(config: LlmConfig) -> Self {
        let client = Client::builder()
            .connect_timeout(std::time::Duration::from_millis(500))
            .timeout(std::time::Duration::from_millis(config.budget_ms as u64))
            .build()
            .unwrap_or_else(|_| Client::new());

        let system_prompt = config
            .system_prompt
            .clone()
            .unwrap_or_else(|| DEFAULT_SYSTEM_PROMPT.to_string());

        Self {
            client,
            config,
            system_prompt,
            has_warned_connection: AtomicBool::new(false),
        }
    }
}

// ── Helper functions (pub(crate) for testing) ───────────────────

/// Build the user prompt from the completion request.
pub(crate) fn build_user_prompt(req: &CompletionRequest) -> String {
    let input_before_cursor = &req.input[..req.cursor];
    // Truncate to last MAX_INPUT_CHARS to avoid exceeding model context
    let truncated = if input_before_cursor.len() > MAX_INPUT_CHARS {
        &input_before_cursor[input_before_cursor.len() - MAX_INPUT_CHARS..]
    } else {
        input_before_cursor
    };
    format!(
        "Shell: {}\nWorking directory: {}\nCommand so far: {}",
        req.shell.as_str(),
        req.cwd.display(),
        truncated
    )
}

/// Extract a clean completion from the raw LLM response.
///
/// Small models frequently return unexpected formats: fenced code blocks,
/// inline backticks, shell prompt prefixes, trailing comments, or echo
/// the input prefix. This function strips all of that down to the raw
/// completion suffix.
pub(crate) fn extract_completion(raw: &str, input_before_cursor: &str) -> Option<String> {
    let mut text = raw.trim().to_string();
    if text.is_empty() {
        return None;
    }

    // Strip fenced code blocks: ```...\ncontent\n```
    if text.starts_with("```") {
        // Remove opening fence (optionally with language tag)
        if let Some(after_fence) = text.strip_prefix("```") {
            let after_lang = after_fence
                .find('\n')
                .map(|i| &after_fence[i + 1..])
                .unwrap_or(after_fence);
            // Remove closing fence
            text = after_lang
                .strip_suffix("```")
                .unwrap_or(after_lang)
                .trim()
                .to_string();
        }
    }

    // Strip inline backticks: `completion`
    if text.starts_with('`') && text.ends_with('`') && text.len() >= 2 {
        text = text[1..text.len() - 1].to_string();
    }

    // Strip shell prompt prefixes
    for prefix in &["$ ", "> "] {
        if let Some(rest) = text.strip_prefix(prefix) {
            text = rest.to_string();
            break;
        }
    }

    // Take first line only
    if let Some(first_line) = text.lines().next() {
        text = first_line.to_string();
    }

    // Strip trailing comments (e.g., "checkout  # switch branches")
    if let Some(hash_pos) = text.find(" #") {
        text = text[..hash_pos].to_string();
    }

    // If the model echoed the full input, strip the prefix
    let trimmed_input = input_before_cursor.trim();
    if !trimmed_input.is_empty() && text.starts_with(trimmed_input) {
        text = text[trimmed_input.len()..].to_string();
    }

    let result = text.trim().to_string();
    if result.is_empty() {
        None
    } else {
        Some(result)
    }
}

// ── PredictionTier impl ─────────────────────────────────────────

#[async_trait]
impl PredictionTier for LlmTier {
    fn name(&self) -> &str {
        "local-llm"
    }

    fn budget_ms(&self) -> u32 {
        self.config.budget_ms
    }

    async fn predict(&self, req: &CompletionRequest) -> Vec<Suggestion> {
        let input_before_cursor = &req.input[..req.cursor];
        if input_before_cursor.trim().is_empty() {
            return vec![];
        }

        let user_prompt = build_user_prompt(req);
        let url = format!(
            "{}/chat/completions",
            self.config.endpoint.trim_end_matches('/')
        );

        let chat_req = ChatRequest {
            model: self.config.model.clone(),
            messages: vec![
                ChatMessage {
                    role: "system".into(),
                    content: self.system_prompt.clone(),
                },
                ChatMessage {
                    role: "user".into(),
                    content: user_prompt,
                },
            ],
            temperature: self.config.temperature,
            max_tokens: self.config.max_tokens,
            stream: false,
            stop: vec!["\n".into()],
            chat_template_kwargs: Some(ChatTemplateKwargs {
                enable_thinking: false,
            }),
        };

        let response = match self.client.post(&url).json(&chat_req).send().await {
            Ok(resp) => resp,
            Err(e) => {
                if self
                    .has_warned_connection
                    .compare_exchange(false, true, Ordering::Relaxed, Ordering::Relaxed)
                    .is_ok()
                {
                    warn!(
                        error = %e,
                        endpoint = %self.config.endpoint,
                        "Local LLM tier: cannot reach endpoint — is the server running?"
                    );
                } else {
                    debug!(error = %e, "LLM request failed");
                }
                return vec![];
            }
        };

        if !response.status().is_success() {
            debug!(status = %response.status(), "LLM endpoint returned non-success status");
            return vec![];
        }

        let chat_resp: ChatResponse = match response.json().await {
            Ok(resp) => resp,
            Err(e) => {
                debug!(error = %e, "Failed to parse LLM response JSON");
                return vec![];
            }
        };

        let raw_content = match chat_resp.choices.first() {
            Some(choice) => match &choice.message.content {
                Some(c) if !c.trim().is_empty() => c.clone(),
                _ => {
                    debug!("LLM response had empty/null content (reasoning model may need enable_thinking=false)");
                    return vec![];
                }
            },
            None => {
                debug!("LLM response had no choices");
                return vec![];
            }
        };

        match extract_completion(&raw_content, input_before_cursor) {
            Some(completion) => vec![Suggestion {
                text: completion,
                replace_start: req.cursor,
                replace_end: req.input.len(),
                confidence: 0.6,
                source: SuggestionSource::LocalModel,
                description: Some(format!("via {}", self.config.model)),
                diff_ops: None,
            }],
            None => vec![],
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::Shell;
    use std::path::PathBuf;

    fn test_request() -> CompletionRequest {
        CompletionRequest {
            input: "git checkout -b feat/".into(),
            cursor: 21,
            cwd: PathBuf::from("/home/user/project"),
            shell: Shell::Bash,
        }
    }

    // ── Prompt construction tests ───────────────────────────────

    #[test]
    fn prompt_includes_shell_and_cwd() {
        let req = test_request();
        let prompt = build_user_prompt(&req);
        assert!(prompt.contains("Shell: bash"));
        assert!(prompt.contains("/home/user/project"));
        assert!(prompt.contains("git checkout -b feat/"));
    }

    #[test]
    fn prompt_truncates_at_cursor() {
        let req = CompletionRequest {
            input: "git checkout main extra_stuff".into(),
            cursor: 17, // "git checkout main"
            cwd: PathBuf::from("/tmp"),
            shell: Shell::Zsh,
        };
        let prompt = build_user_prompt(&req);
        assert!(prompt.contains("git checkout main"));
        assert!(!prompt.contains("extra_stuff"));
    }

    #[test]
    fn prompt_truncates_long_input() {
        let long_input = "a".repeat(MAX_INPUT_CHARS + 500);
        let req = CompletionRequest {
            input: long_input.clone(),
            cursor: long_input.len(),
            cwd: PathBuf::from("/tmp"),
            shell: Shell::Bash,
        };
        let prompt = build_user_prompt(&req);
        // The "Command so far:" portion should be at most MAX_INPUT_CHARS
        let after_prefix = prompt.split("Command so far: ").nth(1).unwrap();
        assert_eq!(after_prefix.len(), MAX_INPUT_CHARS);
    }

    // ── Completion extraction tests ─────────────────────────────

    #[test]
    fn extract_completion_simple() {
        assert_eq!(
            extract_completion("new-feature-branch", "git checkout -b "),
            Some("new-feature-branch".into())
        );
    }

    #[test]
    fn extract_completion_multiline_takes_first() {
        assert_eq!(
            extract_completion("new-feature\ngit push origin", "git checkout -b "),
            Some("new-feature".into())
        );
    }

    #[test]
    fn extract_completion_empty() {
        assert_eq!(extract_completion("", "git "), None);
        assert_eq!(extract_completion("  \n  ", "git "), None);
    }

    #[test]
    fn extract_completion_strips_prefix_echo() {
        assert_eq!(
            extract_completion("git checkout main", "git checkout "),
            Some("main".into())
        );
    }

    #[test]
    fn extract_completion_strips_backticks() {
        // Inline backticks
        assert_eq!(
            extract_completion("`checkout main`", "git "),
            Some("checkout main".into())
        );
    }

    #[test]
    fn extract_completion_strips_fenced_code_block() {
        let raw = "```bash\ncheckout main\n```";
        assert_eq!(
            extract_completion(raw, "git "),
            Some("checkout main".into())
        );
    }

    #[test]
    fn extract_completion_strips_comments() {
        assert_eq!(
            extract_completion("checkout # switch branches", "git "),
            Some("checkout".into())
        );
    }

    #[test]
    fn extract_completion_strips_prompt_prefix() {
        assert_eq!(
            extract_completion("$ checkout main", "git "),
            Some("checkout main".into())
        );
        assert_eq!(
            extract_completion("> checkout main", "git "),
            Some("checkout main".into())
        );
    }

    #[test]
    fn extract_completion_trims_whitespace() {
        assert_eq!(
            extract_completion("  new-feature  \n", "git checkout -b "),
            Some("new-feature".into())
        );
    }

    // ── Tier construction tests ─────────────────────────────────

    #[test]
    fn default_config_produces_valid_tier() {
        let tier = LlmTier::new(LlmConfig::default());
        assert_eq!(tier.name(), "local-llm");
        assert_eq!(tier.budget_ms(), 500);
    }

    // ── Serialization tests ─────────────────────────────────────

    #[test]
    fn chat_request_serializes_stream_false() {
        let req = ChatRequest {
            model: "test".into(),
            messages: vec![],
            temperature: 0.0,
            max_tokens: 64,
            stream: false,
            stop: vec!["\n".into()],
            chat_template_kwargs: Some(ChatTemplateKwargs {
                enable_thinking: false,
            }),
        };
        let json = serde_json::to_value(&req).unwrap();
        assert_eq!(json["stream"], false);
        assert_eq!(json["chat_template_kwargs"]["enable_thinking"], false);
        assert_eq!(json["stop"][0], "\n");
    }
}
