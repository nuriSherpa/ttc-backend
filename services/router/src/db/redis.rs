use redis::aio::ConnectionManager;
use redis::Client;

pub async fn new_client(url: &str) -> anyhow::Result<ConnectionManager> {
    let client = Client::open(url)?;
    let conn = ConnectionManager::new(client).await?;
    Ok(conn)
}