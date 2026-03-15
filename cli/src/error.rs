/// Error types for the CLI.
#[derive(Debug, thiserror::Error)]
pub enum CliError {
    #[error("data not found: {0}")]
    DataNotFound(String),

    #[error("parse error: {0}")]
    ParseError(String),

    #[error("unknown character: {0}")]
    UnknownCharacter(String),

    #[error("invalid filter: {0}")]
    InvalidFilter(String),

    #[error("network error: {0}")]
    NetworkError(String),

    #[error("io error: {0}")]
    IoError(String),
}
