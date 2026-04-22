using Microsoft.UI.Xaml.Controls;

namespace Jellify.App.Services;

/// <summary>
/// View-model-driven navigation. Pages register themselves against a
/// <c>TViewModel → Page</c> map so call sites only know about VM types,
/// not the XAML page they happen to back.
///
/// The shell (<c>ShellPage</c>) supplies the backing <see cref="Frame"/>
/// at startup; the implementation routes <see cref="NavigateTo{TViewModel}"/>
/// calls into <c>Frame.Navigate</c>, threading the optional parameter.
///
/// Back-stack handling lives in the implementation: the X1 mouse
/// back-button, <c>Alt+Left</c>, and the title-bar back arrow all funnel
/// through <see cref="GoBack"/>.
/// </summary>
public interface INavigationService
{
    /// <summary>
    /// Bind the navigation service to the shell's content <see cref="Frame"/>.
    /// Called once during shell activation.
    /// </summary>
    void Initialize(Frame frame);

    /// <summary>
    /// Navigate to the page registered for <typeparamref name="TViewModel"/>,
    /// passing <paramref name="param"/> through to <c>OnNavigatedTo</c> on the
    /// destination view model.
    /// </summary>
    /// <typeparam name="TViewModel">The destination VM type.</typeparam>
    /// <param name="param">Optional navigation argument (e.g. an item id).</param>
    /// <returns><c>true</c> when the navigation request was accepted.</returns>
    bool NavigateTo<TViewModel>(object? param = null) where TViewModel : class;

    /// <summary>Whether the back stack is non-empty.</summary>
    bool CanGoBack { get; }

    /// <summary>Pop one entry off the back stack. No-op when empty.</summary>
    void GoBack();
}
