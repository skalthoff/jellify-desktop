using Microsoft.UI.Xaml;

namespace Jellify.App;

/// <summary>
/// The single top-level <see cref="Window"/>. Hosts the
/// <see cref="Pages.ShellPage"/> which owns the NavigationView + Frame
/// that everything else slots into.
/// </summary>
public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
    }
}
