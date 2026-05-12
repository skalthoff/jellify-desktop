using CommunityToolkit.Mvvm.ComponentModel;
using Lyrebird.Core;

namespace Lyrebird.App.ViewModels;

/// <summary>
/// Login screen view model — server URL probe → username/password →
/// <c>LyrebirdCore.login(...)</c>. Concrete bindings land in batch W-M2.
/// </summary>
public partial class LoginViewModel : ObservableObject
{
    private readonly IJellyfinClient _client;

    public LoginViewModel(IJellyfinClient client)
    {
        _client = client;
    }
}
