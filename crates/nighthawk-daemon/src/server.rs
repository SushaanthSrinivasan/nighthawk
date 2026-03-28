use crate::engine::PredictionEngine;
use interprocess::local_socket::{tokio::prelude::*, GenericFilePath, ListenerOptions, ToFsName};
use nighthawk_proto::CompletionRequest;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tracing::{debug, error, info};

/// Start the IPC server listening for completion requests.
/// Handles SIGTERM/SIGINT for graceful shutdown.
pub async fn run(
    engine: Arc<PredictionEngine>,
    socket_path: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    // Clean up stale socket file on Unix
    #[cfg(unix)]
    {
        let _ = std::fs::remove_file(socket_path);
    }

    let name = socket_path.to_fs_name::<GenericFilePath>()?;
    let opts = ListenerOptions::new().name(name);
    let listener = opts.create_tokio()?;

    info!(%socket_path, "Daemon listening");

    let shutdown = shutdown_signal();
    tokio::pin!(shutdown);

    loop {
        tokio::select! {
            result = listener.accept() => {
                match result {
                    Ok(conn) => {
                        let engine = Arc::clone(&engine);
                        tokio::spawn(async move {
                            if let Err(e) = handle_connection(conn, &engine).await {
                                debug!("Connection ended: {e}");
                            }
                        });
                    }
                    Err(e) => {
                        error!("Accept failed: {e}");
                    }
                }
            }
            _ = &mut shutdown => {
                info!("Shutdown signal received");
                break;
            }
        }
    }

    // Cleanup socket
    #[cfg(unix)]
    {
        let _ = std::fs::remove_file(socket_path);
    }

    // Cleanup PID file
    let pid_path = dirs::config_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("nighthawk")
        .join("nighthawk.pid");
    let _ = std::fs::remove_file(&pid_path);

    info!("Daemon shut down");
    Ok(())
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        let mut sigterm = signal(SignalKind::terminate()).expect("failed to register SIGTERM");
        let mut sigint = signal(SignalKind::interrupt()).expect("failed to register SIGINT");
        tokio::select! {
            _ = sigterm.recv() => {},
            _ = sigint.recv() => {},
        }
    }
    #[cfg(windows)]
    {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to register Ctrl+C");
    }
}

async fn handle_connection(
    conn: impl AsyncRead + AsyncWrite + Unpin,
    engine: &PredictionEngine,
) -> Result<(), Box<dyn std::error::Error>> {
    let (reader, mut writer) = tokio::io::split(conn);
    let mut reader = BufReader::new(reader);
    let mut line = String::new();

    loop {
        line.clear();
        let bytes_read = reader.read_line(&mut line).await?;
        if bytes_read == 0 {
            break; // Client disconnected
        }

        let req: CompletionRequest = match serde_json::from_str(line.trim()) {
            Ok(req) => req,
            Err(e) => {
                debug!("Invalid request: {e}");
                continue;
            }
        };

        let response = engine.complete(&req).await;
        let mut response_json = serde_json::to_string(&response)?;
        response_json.push('\n');
        writer.write_all(response_json.as_bytes()).await?;
        writer.flush().await?;
    }

    Ok(())
}
