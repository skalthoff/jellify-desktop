using Jellify.App.Services;
using Jellify.App.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace Jellify.App.Pages;

/// <summary>
/// Top-level chrome — left-pane <c>NavigationView</c> + content
/// <c>Frame</c>. The shell wires the frame into <see cref="INavigationService"/>
/// so view models can drive navigation without holding XAML references.
///
/// The bootstrap renders an empty content frame; concrete child pages
/// (Login, Home, Library) land in the W-M2 batch.
/// </summary>
public sealed partial class ShellPage : Page
{
    private readonly INavigationService _nav;

    public ShellPage()
    {
        InitializeComponent();
        _nav = App.Services.GetRequiredService<INavigationService>();
        _nav.Initialize(ContentFrame);
    }

    private void Nav_ItemInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (args.InvokedItemContainer is not NavigationViewItem item)
        {
            return;
        }

        // Tag-based dispatch keeps the markup VM-agnostic. Once the real
        // VMs ship (W-M2) each branch will resolve to NavigateTo<XxxVM>().
        switch (item.Tag as string)
        {
            case "Home":
                _nav.NavigateTo<HomeViewModel>();
                break;
            case "Library":
                _nav.NavigateTo<LibraryViewModel>();
                break;
            case "Search":
                // No SearchViewModel yet — placeholder, lands in #366+.
                break;
        }
    }

    private void Nav_BackRequested(NavigationView sender, NavigationViewBackRequestedEventArgs args)
    {
        _nav.GoBack();
    }
}
