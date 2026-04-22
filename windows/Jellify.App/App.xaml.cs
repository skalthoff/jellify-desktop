using System;
using Jellify.App.Services;
using Jellify.App.ViewModels;
using Jellify.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.UI.Xaml;

namespace Jellify.App;

/// <summary>
/// Composition root. Builds a <see cref="HostApplicationBuilder"/> at
/// startup and exposes the resolved <see cref="IServiceProvider"/> via
/// <see cref="Services"/> so view models and pages can resolve their
/// dependencies outside the XAML activation path.
/// </summary>
public partial class App : Application
{
    private Window? _window;

    /// <summary>
    /// Process-wide DI container. Resolved on the UI thread; not safe to
    /// touch before <see cref="OnLaunched"/> has run.
    /// </summary>
    public static IServiceProvider Services { get; private set; } = default!;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Services = BuildHost().Services;

        _window = new MainWindow();
        _window.Activate();
    }

    /// <summary>
    /// Wire the DI container. Core stores are singletons (one per process);
    /// view models are transient because pages create fresh ones per
    /// navigation. The navigation service is a singleton so the shell and
    /// every VM see the same back stack.
    /// </summary>
    private static IHost BuildHost()
    {
        var builder = Host.CreateApplicationBuilder();

        // Core (Rust-backed) services. Concrete implementations land in
        // Issue #362 / #363 — for the bootstrap we register the contracts
        // so the DI graph compiles and the Composition root is wired.
        builder.Services.AddSingleton<IJellyfinClient>(_ =>
            throw new NotImplementedException(
                "JellyfinClient implementation lands with Jellify.Core wrapper (#363)."));
        builder.Services.AddSingleton<IQueueStore>(_ =>
            throw new NotImplementedException("QueueStore lands with player batch."));
        builder.Services.AddSingleton<IPlaybackStateStore>(_ =>
            throw new NotImplementedException("PlaybackStateStore lands with player batch."));

        // Navigation.
        builder.Services.AddSingleton<INavigationService, NavigationService>();

        // View models — transient so each page activation gets a fresh VM
        // (they typically own ObservableCollection instances that mustn't
        // be re-used across page lifetimes).
        builder.Services.AddTransient<LoginViewModel>();
        builder.Services.AddTransient<HomeViewModel>();
        builder.Services.AddTransient<LibraryViewModel>();

        return builder.Build();
    }
}
