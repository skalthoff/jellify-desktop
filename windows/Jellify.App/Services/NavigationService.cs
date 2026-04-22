using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml.Controls;

namespace Jellify.App.Services;

/// <summary>
/// Concrete <see cref="INavigationService"/>. Holds the shell's content
/// <see cref="Frame"/> and a static VM→Page registry. Bigger apps tend to
/// move the registry into a source generator; for the bootstrap a hand-
/// maintained dictionary is enough and keeps the registration explicit.
/// </summary>
public sealed class NavigationService : INavigationService
{
    private Frame? _frame;

    /// <summary>
    /// VM → Page lookup. Pages added here become valid targets for
    /// <see cref="NavigateTo{TViewModel}"/>; subsequent batches will grow
    /// this map as Login, Home, Library, etc. land.
    /// </summary>
    private static readonly IReadOnlyDictionary<Type, Type> PageMap = new Dictionary<Type, Type>
    {
        // Placeholder until ShellPage hosts its first child page.
        // [typeof(LoginViewModel)] = typeof(LoginPage),
        // [typeof(HomeViewModel)]  = typeof(HomePage),
        // [typeof(LibraryViewModel)] = typeof(LibraryPage),
    };

    public void Initialize(Frame frame)
    {
        _frame = frame;
    }

    public bool NavigateTo<TViewModel>(object? param = null) where TViewModel : class
    {
        if (_frame is null)
        {
            return false;
        }

        if (!PageMap.TryGetValue(typeof(TViewModel), out var pageType))
        {
            return false;
        }

        return _frame.Navigate(pageType, param);
    }

    public bool CanGoBack => _frame?.CanGoBack ?? false;

    public void GoBack()
    {
        if (_frame is { CanGoBack: true } f)
        {
            f.GoBack();
        }
    }
}
