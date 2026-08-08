//! The Cabalmail desktop application: the GTK4 + libadwaita shell, the
//! tokio-to-GTK bridge every request rides on, and the widgets.
//!
//! Everything that can be decided without a widget belongs in `cabalmail-kit`
//! instead. The split is structural: the kit has no GTK dependency to reach
//! for, so its futures cannot touch a widget and its tests need no display.
//!
//! This is a library with a thin binary (`src/main.rs`) on top of it, rather
//! than a binary alone, so that a helper written one phase before its first
//! caller is public API rather than dead code.

pub mod application;
pub mod runtime;
pub mod ui;

use gtk::gio;

// Re-exported for `spawn_to_ui!`, which expands to `$crate::glib::clone!` and
// must resolve it without the call site having imported anything.
pub use gtk::glib;

/// The application ID: D-Bus name, GSettings-style resource prefix, `.desktop`
/// file name, AppStream component ID, and icon name, all at once.
pub const APP_ID: &str = "com.cabalmail.Cabalmail";

/// The GResource prefix, which is [`APP_ID`] as a path. `#[template(resource =
/// …)]` attributes are string literals, so this is the documentation of a
/// convention rather than something they can interpolate — the test below
/// keeps the two honest.
pub const RESOURCE_PREFIX: &str = "/com/cabalmail/Cabalmail";

/// Registers the compiled interface bundle, once per process.
///
/// The bundle is compiled into the binary by `build.rs`, so a failure here is a
/// build bug rather than anything a user can cause or fix.
///
/// Idempotent because both [`application::run`] and the widget tests need it,
/// and a test binary runs many of the latter.
pub fn register_resources() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        gio::resources_register_include!("cabalmail.gresource")
            .expect("the interface bundle is compiled into the binary");
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};

    /// The placeholders packaging substitutes when it installs the data files.
    /// Anything else in `@…@` form is a typo that would ship verbatim into a
    /// user's `.desktop` file.
    const PLACEHOLDERS: &[&str] = &["@BINARY@", "@VERSION@", "@DATE@"];

    fn data(name: &str) -> String {
        let path: PathBuf = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("data")
            .join(name);
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
    }

    fn placeholders(text: &str) -> Vec<String> {
        text.split('@')
            .skip(1)
            .step_by(2)
            .map(|name| format!("@{name}@"))
            .collect()
    }

    #[test]
    fn the_resource_prefix_is_the_application_id_as_a_path() {
        assert_eq!(RESOURCE_PREFIX, format!("/{}", APP_ID.replace('.', "/")));
    }

    /// A desktop entry whose `Icon`, `StartupWMClass`, or file name drifts from
    /// the application ID gives a window with a generic icon and a launcher
    /// that cannot match it back to the running app — visible, and easy to
    /// miss, so assert it instead.
    #[test]
    fn the_desktop_entry_is_keyed_to_the_application_id() {
        let desktop = data(&format!("{APP_ID}.desktop.in"));
        for expected in [
            "[Desktop Entry]",
            "Type=Application",
            "Name=Cabalmail",
            "Exec=@BINARY@",
            "TryExec=@BINARY@",
            &format!("Icon={APP_ID}"),
            &format!("StartupWMClass={APP_ID}"),
            "Categories=Network;Email;",
        ] {
            assert!(
                desktop.contains(expected),
                "the desktop entry omits {expected}"
            );
        }
        // `mailto:` handling is Phase 5. Claiming the scheme before the client
        // can honour it would take over the user's mail links and drop them.
        assert!(
            !desktop.contains("mailto"),
            "mailto handling is not implemented yet"
        );
    }

    #[test]
    fn the_metainfo_is_keyed_to_the_desktop_entry() {
        let metainfo = data(&format!("{APP_ID}.metainfo.xml.in"));
        for expected in [
            &format!("<id>{APP_ID}</id>"),
            &format!("<launchable type=\"desktop-id\">{APP_ID}.desktop</launchable>"),
            "<project_license>AGPL-3.0-or-later</project_license>",
        ] {
            assert!(metainfo.contains(expected), "the metainfo omits {expected}");
        }
    }

    /// The installed icon is what `Icon=` resolves to. A rename on one side
    /// only shows up as a missing icon on someone else's desktop.
    #[test]
    fn the_installed_icon_matches_the_desktop_entry() {
        let icon = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("data/icons/hicolor/scalable/apps")
            .join(format!("{APP_ID}.svg"));
        assert!(icon.is_file(), "{} is missing", icon.display());
    }

    #[test]
    fn every_substitution_in_the_data_files_is_one_packaging_knows() {
        for name in [
            format!("{APP_ID}.desktop.in"),
            format!("{APP_ID}.metainfo.xml.in"),
        ] {
            for placeholder in placeholders(&data(&name)) {
                assert!(
                    PLACEHOLDERS.contains(&placeholder.as_str()),
                    "{name} uses {placeholder}, which nothing substitutes"
                );
            }
        }
    }
}
