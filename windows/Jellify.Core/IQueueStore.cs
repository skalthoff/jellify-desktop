namespace Jellify.Core;

/// <summary>
/// In-memory queue projection mirrored from the Rust core's player module.
/// View models read this to render the up-next list and current track;
/// player services write to it when the platform reports state changes.
/// </summary>
public interface IQueueStore
{
}
