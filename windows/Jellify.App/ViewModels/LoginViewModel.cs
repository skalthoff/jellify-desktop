using CommunityToolkit.Mvvm.ComponentModel;
using Jellify.Core;

namespace Jellify.App.ViewModels;

/// <summary>
/// Login screen view model — server URL probe → username/password →
/// <c>JellifyCore.login(...)</c>. Concrete bindings land in batch W-M2.
/// </summary>
public partial class LoginViewModel : ObservableObject
{
    private readonly IJellyfinClient _client;

    public LoginViewModel(IJellyfinClient client)
    {
        _client = client;
    }
}
