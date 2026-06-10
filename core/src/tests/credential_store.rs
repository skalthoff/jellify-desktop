//! Credential-store backend selection and the in-memory dev/e2e store.
//!
//! The resolver decision matrix is a pure function (`resolve_backend`), so it
//! is tested without process-global env mutation. The in-memory store is
//! driven through the backend-explicit primitives because the unit-test
//! harness pins `credential_backend()` to `Native` — the suite's mock
//! `keyring` builder (`install_mock_keyring`) owns that path.

use super::*;
use crate::storage::{credential_backend, resolve_backend, CredentialBackend};

#[test]
fn resolver_decision_matrix() {
    // Unset → native keyring, exactly as before the switch existed.
    assert_eq!(resolve_backend(None), CredentialBackend::Native);
    // The one opt-in spelling.
    assert_eq!(resolve_backend(Some("memory")), CredentialBackend::Memory);
    // Everything else falls back to native: empty, unknown values, case and
    // whitespace variants. Fail-safe means an unrecognized value can only
    // ever land on the production backend.
    assert_eq!(resolve_backend(Some("")), CredentialBackend::Native);
    assert_eq!(resolve_backend(Some("native")), CredentialBackend::Native);
    assert_eq!(resolve_backend(Some("keychain")), CredentialBackend::Native);
    assert_eq!(resolve_backend(Some("Memory")), CredentialBackend::Native);
    assert_eq!(resolve_backend(Some("MEMORY")), CredentialBackend::Native);
    assert_eq!(resolve_backend(Some(" memory")), CredentialBackend::Native);
    assert_eq!(resolve_backend(Some("memory ")), CredentialBackend::Native);
}

#[test]
fn unit_test_harness_is_pinned_to_native() {
    // Under `cfg(test)` the cached resolver ignores the environment entirely,
    // so the suite always exercises the `keyring` path through the installed
    // mock builder — even when a developer's shell happens to export
    // `LYREBIRD_CREDENTIAL_STORE=memory`. Release builds share this branch of
    // the `cfg` structure, which is the compile-time guarantee that the env
    // switch cannot downgrade a production build.
    assert_eq!(credential_backend(), CredentialBackend::Native);
}

#[test]
fn memory_store_round_trips_save_load_delete() {
    let account = "memtest-server/round-trip-user";
    assert_eq!(
        CredentialStore::load_secret(CredentialBackend::Memory, account).unwrap(),
        None,
        "fresh account starts absent"
    );

    CredentialStore::save_secret(CredentialBackend::Memory, account, "tok-1").unwrap();
    assert_eq!(
        CredentialStore::load_secret(CredentialBackend::Memory, account)
            .unwrap()
            .as_deref(),
        Some("tok-1")
    );

    // Overwrite wins, matching keychain `set_password` semantics.
    CredentialStore::save_secret(CredentialBackend::Memory, account, "tok-2").unwrap();
    assert_eq!(
        CredentialStore::load_secret(CredentialBackend::Memory, account)
            .unwrap()
            .as_deref(),
        Some("tok-2")
    );

    // Delete drops the secret and is idempotent, matching the native arm's
    // `NoEntry` mapping.
    CredentialStore::delete_secret(CredentialBackend::Memory, account).unwrap();
    assert_eq!(
        CredentialStore::load_secret(CredentialBackend::Memory, account).unwrap(),
        None
    );
    CredentialStore::delete_secret(CredentialBackend::Memory, account)
        .expect("deleting an absent entry is a no-op");
}

#[test]
fn memory_store_isolates_accounts() {
    CredentialStore::save_secret(CredentialBackend::Memory, "memtest-iso/a", "secret-a").unwrap();
    CredentialStore::save_secret(CredentialBackend::Memory, "memtest-iso/b", "secret-b").unwrap();

    assert_eq!(
        CredentialStore::load_secret(CredentialBackend::Memory, "memtest-iso/a")
            .unwrap()
            .as_deref(),
        Some("secret-a")
    );

    CredentialStore::delete_secret(CredentialBackend::Memory, "memtest-iso/a").unwrap();
    assert_eq!(
        CredentialStore::load_secret(CredentialBackend::Memory, "memtest-iso/a").unwrap(),
        None
    );
    assert_eq!(
        CredentialStore::load_secret(CredentialBackend::Memory, "memtest-iso/b")
            .unwrap()
            .as_deref(),
        Some("secret-b"),
        "deleting one account must not disturb another"
    );
}
