use crate::engine::PredictionEngine;
use interprocess::local_socket::{tokio::prelude::*, GenericFilePath, ListenerOptions, ToFsName};
use nighthawk_proto::CompletionRequest;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tracing::{debug, error, info};

/// Start the IPC server listening for completion requests.
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

    loop {
        match listener.accept().await {
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
