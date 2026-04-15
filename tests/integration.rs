use std::path::PathBuf;
use std::sync::Arc;

use nighthawk::daemon::engine::history::HistoryTier;
use nighthawk::daemon::engine::specs::SpecTier;
use nighthawk::daemon::engine::PredictionEngine;
use nighthawk::daemon::history::file::FileHistory;
use nighthawk::daemon::history::ShellHistory;
use nighthawk::daemon::specs::fig::FigSpecProvider;
use nighthawk::daemon::specs::SpecRegistry;
use nighthawk::proto::*;

use interprocess::local_socket::{tokio::prelude::*, GenericFilePath, ToFsName};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

fn test_socket_path() -> String {
    #[cfg(unix)]
    {
        format!("/tmp/nighthawk-test-{}.sock", std::process::id())
    }
    #[cfg(windows)]
    {
        format!(r"\\.\pipe\nighthawk-test-{}", std::process::id())
    }
}

/// Helper: build an engine with a spec tier pointing to a temp dir containing specs.
fn build_spec_engine(specs_dir: &std::path::Path) -> Arc<PredictionEngine> {
    let fig_provider = FigSpecProvider::new(specs_dir.to_path_buf());
    let registry = Arc::new(SpecRegistry::new(vec![Box::new(fig_provider)]));
    let tier = SpecTier::new(registry);
    Arc::new(PredictionEngine::new(vec![Box::new(tier)]))
}

/// Helper: send a request and get a response over the IPC socket.
async fn query(socket_path: &str, req: &CompletionRequest) -> CompletionResponse {
    let name = socket_path.to_fs_name::<GenericFilePath>().unwrap();
    let conn = LocalSocketStream::connect(name).await.unwrap();
    let (reader, mut writer) = tokio::io::split(conn);
    let mut reader = BufReader::new(reader);

    let mut json = serde_json::to_string(req).unwrap();
    json.push('\n');
    writer.write_all(json.as_bytes()).await.unwrap();
    writer.flush().await.unwrap();

    let mut response_line = String::new();
    reader.read_line(&mut response_line).await.unwrap();
    serde_json::from_str(&response_line).unwrap()
}

#[tokio::test]
async fn spec_tier_git_checkout() {
    let dir = tempfile::TempDir::new().unwrap();
    let git_spec = include_str!("../specs/git.json");
    std::fs::write(dir.path().join("git.json"), git_spec).unwrap();

    let engine = build_spec_engine(dir.path());
    let socket_path = test_socket_path();

    let engine_clone = Arc::clone(&engine);
    let sp = socket_path.clone();
    tokio::spawn(async move {
        let _ = nighthawk::daemon::server::run(engine_clone, &sp).await;
    });

    // Give the server a moment to bind
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;

    let resp = query(
        &socket_path,
        &CompletionRequest {
            input: "git ch".into(),
            cursor: 6,
            cwd: PathBuf::from("/tmp"),
            shell: Shell::Zsh,
        },
    )
    .await;

    assert!(
        !resp.suggestions.is_empty(),
        "Should have suggestions for 'git ch'"
    );
    let first = &resp.suggestions[0];
    assert_eq!(first.text, "checkout");
    assert_eq!(first.replace_start, 4);
    assert_eq!(first.replace_end, 6);
    assert_eq!(first.source, SuggestionSource::Spec);
}

#[tokio::test]
async fn spec_tier_git_subcommand_with_space() {
    let dir = tempfile::TempDir::new().unwrap();
    let git_spec = include_str!("../specs/git.json");
    std::fs::write(dir.path().join("git.json"), git_spec).unwrap();

    let engine = build_spec_engine(dir.path());
    let socket_path = format!("{}-space", test_socket_path());

    let engine_clone = Arc::clone(&engine);
    let sp = socket_path.clone();
    tokio::spawn(async move {
        let _ = nighthawk::daemon::server::run(engine_clone, &sp).await;
    });

    tokio::time::sleep(std::time::Duration::from_millis(100)).await;

    // "git " with trailing space — should suggest subcommands
    let resp = query(
        &socket_path,
        &CompletionRequest {
            input: "git ".into(),
            cursor: 4,
            cwd: PathBuf::from("/tmp"),
            shell: Shell::Zsh,
        },
    )
    .await;

    // Should return subcommands (checkout, commit, etc.)
    assert!(
        !resp.suggestions.is_empty(),
        "Should suggest subcommands after 'git '"
    );
}

#[tokio::test]
async fn empty_input_returns_no_suggestions() {
    let dir = tempfile::TempDir::new().unwrap();
    let engine = build_spec_engine(dir.path());
    let socket_path = format!("{}-empty", test_socket_path());

    let engine_clone = Arc::clone(&engine);
    let sp = socket_path.clone();
    tokio::spawn(async move {
        let _ = nighthawk::daemon::server::run(engine_clone, &sp).await;
    });

    tokio::time::sleep(std::time::Duration::from_millis(100)).await;

    let resp = query(
        &socket_path,
        &CompletionRequest {
            input: "".into(),
            cursor: 0,
            cwd: PathBuf::from("/tmp"),
            shell: Shell::Zsh,
        },
    )
    .await;

    assert!(resp.suggestions.is_empty());
}

#[tokio::test]
async fn unknown_command_returns_empty() {
    let dir = tempfile::TempDir::new().unwrap();
    let engine = build_spec_engine(dir.path());
    let socket_path = format!("{}-unknown", test_socket_path());

    let engine_clone = Arc::clone(&engine);
    let sp = socket_path.clone();
    tokio::spawn(async move {
        let _ = nighthawk::daemon::server::run(engine_clone, &sp).await;
    });

    tokio::time::sleep(std::time::Duration::from_millis(100)).await;

    let resp = query(
        &socket_path,
        &CompletionRequest {
            input: "nonexistentcommand --fl".into(),
            cursor: 23,
            cwd: PathBuf::from("/tmp"),
            shell: Shell::Zsh,
        },
    )
    .await;

    assert!(resp.suggestions.is_empty());
}

#[tokio::test]
async fn powershell_shell_variant_works() {
    let dir = tempfile::TempDir::new().unwrap();
    let git_spec = include_str!("../specs/git.json");
    std::fs::write(dir.path().join("git.json"), git_spec).unwrap();

    let engine = build_spec_engine(dir.path());
    let socket_path = format!("{}-pwsh", test_socket_path());

    let engine_clone = Arc::clone(&engine);
    let sp = socket_path.clone();
    tokio::spawn(async move {
        let _ = nighthawk::daemon::server::run(engine_clone, &sp).await;
    });

    tokio::time::sleep(std::time::Duration::from_millis(100)).await;

    // Request with PowerShell shell and Windows-style path
    let resp = query(
        &socket_path,
        &CompletionRequest {
            input: "git ch".into(),
            cursor: 6,
            cwd: PathBuf::from(r"D:\projects\nighthawk"),
            shell: Shell::PowerShell,
        },
    )
    .await;

    assert!(
        !resp.suggestions.is_empty(),
        "PowerShell requests should work like any other shell"
    );
    assert_eq!(resp.suggestions[0].text, "checkout");
}

#[tokio::test]
async fn powershell_fuzzy_match_returns_diff_ops() {
    let dir = tempfile::TempDir::new().unwrap();
    let git_spec = include_str!("../specs/git.json");
    std::fs::write(dir.path().join("git.json"), git_spec).unwrap();

    let engine = build_spec_engine(dir.path());
    let socket_path = format!("{}-pwsh-fuzzy", test_socket_path());

    let engine_clone = Arc::clone(&engine);
    let sp = socket_path.clone();
    tokio::spawn(async move {
        let _ = nighthawk::daemon::server::run(engine_clone, &sp).await;
    });

    tokio::time::sleep(std::time::Duration::from_millis(100)).await;

    // Typo: "chekout" instead of "checkout"
    let resp = query(
        &socket_path,
        &CompletionRequest {
            input: "git chekout".into(),
            cursor: 11,
            cwd: PathBuf::from(r"C:\Users\test"),
            shell: Shell::PowerShell,
        },
    )
    .await;

    assert!(
        !resp.suggestions.is_empty(),
        "Fuzzy match should find 'checkout' for 'chekout'"
    );
    let first = &resp.suggestions[0];
    assert_eq!(first.text, "checkout");
    assert!(
        first.diff_ops.is_some(),
        "Fuzzy match should include diff_ops"
    );
}

#[tokio::test]
async fn history_tier_prefix_match() {
    let dir = tempfile::TempDir::new().unwrap();

    // Create a fake bash history file
    let history_path = dir.path().join(".bash_history");
    std::fs::write(
        &history_path,
        "git status\ngit commit -m \"test\"\nls -la\ngit status\n",
    )
    .unwrap();

    let mut file_history = FileHistory::with_path(Shell::Bash, history_path);
    file_history.load().unwrap();

    // Use concrete type to allow hot-reload via reload_if_changed()
    let history: Arc<tokio::sync::RwLock<FileHistory>> =
        Arc::new(tokio::sync::RwLock::new(file_history));

    let tier = HistoryTier::new(history);
    let engine = Arc::new(PredictionEngine::new(vec![Box::new(tier)]));

    let socket_path = format!("{}-history", test_socket_path());

    let engine_clone = Arc::clone(&engine);
    let sp = socket_path.clone();
    tokio::spawn(async move {
        let _ = nighthawk::daemon::server::run(engine_clone, &sp).await;
    });

    tokio::time::sleep(std::time::Duration::from_millis(100)).await;

    let resp = query(
        &socket_path,
        &CompletionRequest {
            input: "git s".into(),
            cursor: 5,
            cwd: PathBuf::from("/tmp"),
            shell: Shell::Bash,
        },
    )
    .await;

    assert!(
        !resp.suggestions.is_empty(),
        "Should match 'git status' from history"
    );
    assert_eq!(resp.suggestions[0].source, SuggestionSource::History);
    // The suggestion text is the SUFFIX after what's already typed
    assert_eq!(resp.suggestions[0].text, "tatus");
}
