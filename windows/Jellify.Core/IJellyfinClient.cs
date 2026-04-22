namespace Jellify.Core;

/// <summary>
/// Idiomatic C# facade over the UniFFI-generated <c>JellifyCore</c> handle.
/// The wrapper is what app-side view models depend on; subsequent batches
/// add concrete implementations that delegate into the Rust core.
/// </summary>
public interface IJellyfinClient
{
    /// <summary>
    /// Stable identifier the Rust core advertises for this device install.
    /// Persisted on first launch; used as the Jellyfin <c>DeviceId</c> on
    /// every authenticated request.
    /// </summary>
    string DeviceId { get; }
}
