use thiserror::Error;

#[derive(Debug, Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum JellifyError {
    #[error("network error: {0}")]
    Network(String),

    #[error("authentication failed: {0}")]
    Auth(String),

    #[error("server returned an error: {status} {message}")]
    Server { status: u16, message: String },

    #[error("not logged in")]
    NotAuthenticated,

    #[error("no active session — call login or restore first")]
    NoSession,

    /// The current access token was rejected by the server (`401`) and a
    /// silent re-read from the keyring did not surface a fresh one. Surfaced
    /// so the UI can prompt the user to re-authenticate — see
    /// [`crate::JellifyCore::forget_token`] for the pre-fill affordance.
    #[error("authentication expired — please sign in again")]
    AuthExpired,

    #[error("decode error: {0}")]
    Decode(String),

    #[error("storage error: {0}")]
    Storage(String),

    #[error("credential store error: {0}")]
    Credentials(String),

    #[error("audio error: {0}")]
    Audio(String),

    #[error("invalid input: {0}")]
    InvalidInput(String),

    #[error("queue index {index} is out of bounds (queue length: {len})")]
    InvalidIndex { index: usize, len: usize },

    #[error("{0}")]
    Other(String),
}

impl From<reqwest::Error> for JellifyError {
    fn from(e: reqwest::Error) -> Self {
        JellifyError::Network(e.to_string())
    }
}

impl From<serde_json::Error> for JellifyError {
    fn from(e: serde_json::Error) -> Self {
        JellifyError::Decode(e.to_string())
    }
}

impl From<rusqlite::Error> for JellifyError {
    fn from(e: rusqlite::Error) -> Self {
        JellifyError::Storage(e.to_string())
    }
}

impl From<keyring::Error> for JellifyError {
    fn from(e: keyring::Error) -> Self {
        JellifyError::Credentials(e.to_string())
    }
}

impl From<url::ParseError> for JellifyError {
    fn from(e: url::ParseError) -> Self {
        JellifyError::InvalidInput(format!("invalid url: {e}"))
    }
}

pub type Result<T, E = JellifyError> = std::result::Result<T, E>;
