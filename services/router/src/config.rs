use anyhow::Context;

pub struct Config {
    pub port: u16,
    pub pgdsn: String,
    pub redis_url: String,
    pub internal_token: String,
}

impl Config {
    pub fn load() -> anyhow::Result<Self> {
        Ok(Self {
            port: std::env::var("PORT")
                .unwrap_or_else(|_| "8081".into())
                .parse()
                .context("PORT must be a number")?,
            pgdsn: std::env::var("PGDSN").context("PGDSN is required")?,
            redis_url: std::env::var("REDIS_URL").context("REDIS_URL is required")?,
            internal_token: std::env::var("INTERNAL_TOKEN").context("INTERNAL_TOKEN is required")?,
        })
    }
}