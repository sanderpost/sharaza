use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("Database error: {0}")]
    Database(#[from] rusqlite::Error),

    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("HTTP error: {0}")]
    Http(#[from] reqwest::Error),

    #[error("Image error: {0}")]
    Image(#[from] image::ImageError),

    #[error("Regex error: {0}")]
    Regex(#[from] regex::Error),

    #[error("Invalid configuration: {0}")]
    InvalidConfig(String),

    #[error("Upload failed: {0}")]
    UploadFailed(String),

    #[error("Operation cancelled: {0}")]
    Cancelled(String),
}

pub type CoreResult<T> = Result<T, CoreError>;
