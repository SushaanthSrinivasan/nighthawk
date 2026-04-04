#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    nighthawk::daemon::run().await
}
