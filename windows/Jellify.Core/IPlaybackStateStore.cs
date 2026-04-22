namespace Jellify.Core;

/// <summary>
/// Reactive playback-state surface (state, position, duration, volume).
/// The Windows <c>MediaPlayer</c> bridge writes to this on every transport
/// event; view models bind to its observable properties for transport UI.
/// </summary>
public interface IPlaybackStateStore
{
}
