use thiserror::Error;

/// Canonical error type for the Jellify core. Structured so callers can
/// match on the concrete failure class without parsing error messages.
///
/// The coarse `Server { status, message }` that preceded this rework has
/// been split by HTTP status so Swift / Rust callers can act on meaningful
/// subclasses:
///
/// - [`Self::Auth`] — 401 from the server (bad / expired credentials).
/// - [`Self::Forbidden`] — 403 (user lacks permission for the item).
/// - [`Self::NotFound`] — 404 (item / user view does not exist).
/// - [`Self::RateLimit`] — 429 with an optional `Retry-After` hint.
/// - [`Self::Network`] — transport-level failure (DNS, TLS, timeout).
/// - [`Self::Server`] — any other HTTP failure (5xx or unclassified 4xx).
///
/// [`Self::is_retryable`] is the single source of truth for "should I
/// exponentially back off and try again?"; it returns `true` for 5xx
/// `Server`, `RateLimit`, and `Network`.
#[derive(Debug, Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum JellifyError {
    #[error("network error: {0}")]
    Network(String),

    #[error("authentication failed: {0}")]
    Auth(String),

    #[error("forbidden: {0}")]
    Forbidden(String),

    #[error("not found: {0}")]
    NotFound(String),

    #[error("rate limited (retry after {retry_after:?}s)")]
    RateLimit { retry_after: Option<u64> },

    #[error("server returned an error: {status} {body}")]
    Server { status: u16, body: String },

    #[error("not logged in")]
    NotAuthenticated,

    #[error("no active session — call login or restore first")]
    NoSession,

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

    #[error("{0}")]
    Other(String),
}

impl JellifyError {
    /// Should the caller retry the request after an exponential backoff?
    ///
    /// Returns `true` for:
    /// - [`Self::RateLimit`] — the server asked us to slow down; the
    ///   `retry_after` (when set) is an upper bound on the wait.
    /// - [`Self::Server`] with a 5xx status — transient server-side issue.
    /// - [`Self::Network`] — transport fault (DNS, TLS, timeout); usually
    ///   resolves on its own.
    ///
    /// Returns `false` for `Auth`, `Forbidden`, `NotFound`, `Decode`,
    /// `InvalidInput`, `NotAuthenticated`, `NoSession`, `Storage`,
    /// `Credentials`, `Audio`, `Other` — those need user or code action, not
    /// a retry.
    pub fn is_retryable(&self) -> bool {
        match self {
            JellifyError::RateLimit { .. } => true,
            JellifyError::Network(_) => true,
            JellifyError::Server { status, .. } => (500..600).contains(status),
            _ => false,
        }
    }

    /// Build a JellifyError from an HTTP response's status code, body text,
    /// and optional `Retry-After` header. Dispatches to the narrowest
    /// variant that matches the status:
    ///
    /// - 401 → [`Self::Auth`]
    /// - 403 → [`Self::Forbidden`]
    /// - 404 → [`Self::NotFound`]
    /// - 429 → [`Self::RateLimit`]
    /// - else → [`Self::Server`]
    pub fn from_status(status: u16, body: String, retry_after: Option<u64>) -> Self {
        match status {
            401 => JellifyError::Auth(body),
            403 => JellifyError::Forbidden(body),
            404 => JellifyError::NotFound(body),
            429 => JellifyError::RateLimit { retry_after },
            _ => JellifyError::Server { status, body },
        }
    }
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
