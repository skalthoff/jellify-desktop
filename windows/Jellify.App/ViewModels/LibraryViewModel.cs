using CommunityToolkit.Mvvm.ComponentModel;
using Jellify.Core;

namespace Jellify.App.ViewModels;

/// <summary>
/// Library tab view model — albums, artists, tracks, playlists pivots.
/// Each pivot reads a paginated <c>list_*</c> stream from the Rust core.
/// </summary>
public partial class LibraryViewModel : ObservableObject
{
    private readonly IJellyfinClient _client;

    public LibraryViewModel(IJellyfinClient client)
    {
        _client = client;
    }
}
