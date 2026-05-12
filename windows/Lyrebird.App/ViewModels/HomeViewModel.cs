using CommunityToolkit.Mvvm.ComponentModel;
using Lyrebird.Core;

namespace Lyrebird.App.ViewModels;

/// <summary>
/// Home tab view model — recently played, latest albums, suggested
/// stations. Populated by the Rust core via paginated library queries.
/// </summary>
public partial class HomeViewModel : ObservableObject
{
    private readonly IJellyfinClient _client;

    public HomeViewModel(IJellyfinClient client)
    {
        _client = client;
    }
}
