use crate::error::{JellifyError, Result};
use parking_lot::Mutex;
use rusqlite::{params, Connection};
use std::path::{Path, PathBuf};

const SCHEMA_VERSION: i32 = 1;

pub struct Database {
    conn: Mutex<Connection>,
}

impl Database {
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self> {
        if let Some(parent) = path.as_ref().parent() {
            std::fs::create_dir_all(parent).map_err(|e| JellifyError::Storage(e.to_string()))?;
        }
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        let db = Database {
            conn: Mutex::new(conn),
        };
        db.migrate()?;
        Ok(db)
    }

    pub fn in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        let db = Database {
            conn: Mutex::new(conn),
        };
        db.migrate()?;
        Ok(db)
    }

    fn migrate(&self) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        tx.execute(
            "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY)",
            [],
        )?;
        let current: i32 = tx
            .query_row(
                "SELECT COALESCE(MAX(version), 0) FROM schema_version",
                [],
                |r| r.get(0),
            )
            .unwrap_or(0);

        if current < 1 {
            tx.execute_batch(include_str!("migrations/001_initial.sql"))?;
            tx.execute(
                "INSERT INTO schema_version (version) VALUES (?1)",
                params![1],
            )?;
        }

        if current < SCHEMA_VERSION {
            // Future migrations inserted here as `if current < N { ... }` blocks.
        }

        tx.commit()?;
        Ok(())
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<()> {
        self.conn.lock().execute(
            "INSERT INTO settings (key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    pub fn get_setting(&self, key: &str) -> Result<Option<String>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare("SELECT value FROM settings WHERE key = ?1")?;
        let row = stmt.query_row(params![key], |r| r.get::<_, String>(0)).ok();
        Ok(row)
    }

    pub fn delete_setting(&self, key: &str) -> Result<()> {
        self.conn
            .lock()
            .execute("DELETE FROM settings WHERE key = ?1", params![key])?;
        Ok(())
    }

    pub fn record_play(&self, track_id: &str, played_at: i64) -> Result<()> {
        self.conn.lock().execute(
            "INSERT INTO play_history (track_id, played_at) VALUES (?1, ?2)",
            params![track_id, played_at],
        )?;
        Ok(())
    }

    pub fn play_count(&self, track_id: &str) -> Result<u64> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare("SELECT COUNT(*) FROM play_history WHERE track_id = ?1")?;
        let count: i64 = stmt.query_row(params![track_id], |r| r.get(0))?;
        Ok(count as u64)
    }
}

pub fn default_data_dir() -> PathBuf {
    if let Some(dirs) = dirs_next_like() {
        dirs.join("jellify-desktop")
    } else {
        PathBuf::from(".").join(".jellify-desktop")
    }
}

fn dirs_next_like() -> Option<PathBuf> {
    // Minimal hand-rolled equivalent of `dirs::data_dir()` so we don't pull
    // another crate just for this. Prefer XDG_DATA_HOME on Unix, APPDATA on
    // Windows, ~/Library/Application Support on macOS.
    if let Ok(val) = std::env::var("XDG_DATA_HOME") {
        if !val.is_empty() {
            return Some(PathBuf::from(val));
        }
    }
    #[cfg(target_os = "macos")]
    {
        if let Ok(home) = std::env::var("HOME") {
            return Some(PathBuf::from(home).join("Library/Application Support"));
        }
    }
    #[cfg(target_os = "windows")]
    {
        if let Ok(appdata) = std::env::var("APPDATA") {
            return Some(PathBuf::from(appdata));
        }
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        if let Ok(home) = std::env::var("HOME") {
            return Some(PathBuf::from(home).join(".local/share"));
        }
    }
    None
}

// ============================================================================
// Credentials — access tokens stored in OS credential store via `keyring`.
// ============================================================================

const SERVICE: &str = "org.jellify.desktop";

pub struct CredentialStore;

impl CredentialStore {
    pub fn save_token(server_id: &str, username: &str, token: &str) -> Result<()> {
        let entry = keyring::Entry::new(SERVICE, &format!("{server_id}/{username}"))?;
        entry.set_password(token)?;
        Ok(())
    }

    pub fn load_token(server_id: &str, username: &str) -> Result<Option<String>> {
        let entry = keyring::Entry::new(SERVICE, &format!("{server_id}/{username}"))?;
        match entry.get_password() {
            Ok(t) => Ok(Some(t)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    pub fn delete_token(server_id: &str, username: &str) -> Result<()> {
        let entry = keyring::Entry::new(SERVICE, &format!("{server_id}/{username}"))?;
        match entry.delete_credential() {
            Ok(_) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
}
