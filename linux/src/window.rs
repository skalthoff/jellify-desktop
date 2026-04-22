//! `JellifyWindow` — the top-level app window.
//!
//! Subclasses `AdwApplicationWindow` via `glib::subclass` so we get a proper
//! GObject type (required for composite templates) while keeping the
//! libadwaita integration (adaptive sizing, runtime color-scheme plumbing).
//!
//! The UI layout comes from `window.ui` via `CompositeTemplate`. Template
//! children (`header_bar`, `navigation_view`) are wired through
//! `#[template_child]` so the imp block can reach them without a runtime
//! builder lookup.
//!
//! The window owns the shared [`AppModel`]; child screens (once added in
//! follow-up batches) reach the model via `window.model()`. We hold
//! `AppModel` behind `Rc<_>` rather than `Arc<_>` because everything in the
//! GTK world runs on a single main thread — the `Arc<JellifyCore>` *inside*
//! `AppModel` is what crosses thread boundaries when we dispatch core calls
//! to a worker.

use std::cell::OnceCell;
use std::rc::Rc;

use adw::subclass::prelude::*;
use glib::subclass::InitializingObject;
use libadwaita as adw;

use crate::model::AppModel;

mod imp {
    use super::*;

    #[derive(Debug, Default, gtk4::CompositeTemplate)]
    #[template(resource = "/org/jellify/Desktop/window.ui")]
    pub struct JellifyWindow {
        #[template_child]
        pub header_bar: gtk4::TemplateChild<adw::HeaderBar>,
        #[template_child]
        pub navigation_view: gtk4::TemplateChild<adw::NavigationView>,

        /// Shared app state — set once in `setup_model`. `OnceCell` so we can
        /// initialize it lazily after the window exists (construction order
        /// matters: the imp's `Default` runs before we have a core handle).
        pub model: OnceCell<Rc<AppModel>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for JellifyWindow {
        const NAME: &'static str = "JellifyWindow";
        type Type = super::JellifyWindow;
        type ParentType = adw::ApplicationWindow;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(obj: &InitializingObject<Self>) {
            obj.init_template();
        }
    }

    impl ObjectImpl for JellifyWindow {
        fn constructed(&self) {
            self.parent_constructed();
            // Hook for future wiring: sidebar signals, GActions, geometry
            // restore from `gio::Settings`, etc. Intentionally empty in the
            // bootstrap batch so the shell compiles against a minimal
            // composite template.
        }
    }

    impl WidgetImpl for JellifyWindow {}
    impl WindowImpl for JellifyWindow {}
    impl ApplicationWindowImpl for JellifyWindow {}
    impl AdwApplicationWindowImpl for JellifyWindow {}
}

glib::wrapper! {
    /// Top-level `AdwApplicationWindow` for Jellify. Created once per primary
    /// instance in `main.rs::activate`.
    pub struct JellifyWindow(ObjectSubclass<imp::JellifyWindow>)
        @extends adw::ApplicationWindow, gtk4::ApplicationWindow, gtk4::Window, gtk4::Widget,
        @implements gio::ActionGroup, gio::ActionMap, gtk4::Accessible, gtk4::Buildable,
                    gtk4::ConstraintTarget, gtk4::Native, gtk4::Root, gtk4::ShortcutManager;
}

impl JellifyWindow {
    /// Build a new window bound to the running `adw::Application` and lazily
    /// initialize the shared [`AppModel`]. Model construction is allowed to
    /// fail (e.g. if the SQLite DB under the XDG data dir can't be opened);
    /// we log and keep presenting the shell in that case so the user still
    /// sees *something* rather than a silent no-op, and so UI developers
    /// running without a writable data dir aren't blocked.
    pub fn new(app: &adw::Application) -> Self {
        let window: Self = glib::Object::builder().property("application", app).build();
        window.setup_model();
        window
    }

    /// Access the shared [`AppModel`]. Panics if the model failed to
    /// initialize — screens that depend on it should only be pushed onto the
    /// navigation view after a successful session handshake, at which point
    /// this is guaranteed to be `Some`.
    pub fn model(&self) -> Rc<AppModel> {
        self.imp()
            .model
            .get()
            .cloned()
            .expect("AppModel not initialized — called model() before setup_model succeeded")
    }

    fn setup_model(&self) {
        match AppModel::new() {
            Ok(model) => {
                // OnceCell::set returns Err if already set; on first init
                // we are the only caller so it's safe to discard.
                let _ = self.imp().model.set(Rc::new(model));
            }
            Err(err) => {
                tracing::error!(error = %err, "failed to initialize AppModel");
            }
        }
    }
}
