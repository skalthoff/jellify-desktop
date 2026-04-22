//! Build script — compiles the app's `gresource` bundle via `glib-build-tools`
//! so UI XML templates and (future) CSS / icons are embedded in the binary
//! and loadable at runtime via `gio::resources_register_include!`.
//!
//! `source_dirs` lists the directories the gresource manifest's relative
//! paths are resolved against. The UI composite template lives in `src/`
//! alongside the matching Rust module (per the bootstrap layout); add
//! `resources/` as the conventional home for future icons and CSS.

fn main() {
    glib_build_tools::compile_resources(
        &["src", "resources"],
        "resources/resources.gresource.xml",
        "resources.gresource",
    );
}
