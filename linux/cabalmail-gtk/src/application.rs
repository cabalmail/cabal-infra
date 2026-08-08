//! The `AdwApplication` subclass: what owns the runtime, the resolved
//! settings, and the window.

use std::process::ExitCode;
use std::time::Duration;

use adw::prelude::*;
use adw::subclass::prelude::*;
use cabalmail_kit::config::{Key, Settings};
use gtk::{gio, glib};

use crate::APP_ID;
use crate::runtime::Runtime;
use crate::ui::window::CabalmailWindow;

/// How long quitting waits for work in flight before abandoning it. Long
/// enough for a request that is nearly done, short enough that nobody reaches
/// for the window manager.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(2);

mod imp {
    use super::*;
    use std::cell::OnceCell;

    #[derive(Default)]
    pub struct CabalmailApplication {
        /// The one I/O runtime, per the bridge's rules. Set in
        /// [`super::CabalmailApplication::new`].
        pub runtime: OnceCell<Runtime>,
        /// Configuration as resolved at startup, including this run's flags and
        /// `CABALMAIL_*` variables.
        ///
        /// Phase 6 turns this into a live store with three writers — file, UI,
        /// and server. Until then it is read once and never changes, which is
        /// why it is a `OnceCell` rather than something observable.
        pub settings: OnceCell<Settings>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for CabalmailApplication {
        const NAME: &'static str = "CabalmailApplication";
        type Type = super::CabalmailApplication;
        type ParentType = adw::Application;
    }

    impl ObjectImpl for CabalmailApplication {}

    impl ApplicationImpl for CabalmailApplication {
        fn startup(&self) {
            self.parent_startup();
            self.obj().setup_actions();
            self.obj().apply_theme();
        }

        fn activate(&self) {
            let application = self.obj();
            let window = application
                .active_window()
                .unwrap_or_else(|| CabalmailWindow::new(&*application).upcast());
            window.present();
        }

        fn shutdown(&self) {
            if let Some(runtime) = self.runtime.get() {
                runtime.shutdown(SHUTDOWN_GRACE);
            }
            self.parent_shutdown();
        }
    }

    impl GtkApplicationImpl for CabalmailApplication {}
    impl AdwApplicationImpl for CabalmailApplication {}
}

glib::wrapper! {
    pub struct CabalmailApplication(ObjectSubclass<imp::CabalmailApplication>)
        @extends adw::Application, gtk::Application, gio::Application,
        @implements gio::ActionGroup, gio::ActionMap;
}

impl CabalmailApplication {
    /// Builds the application around a resolved configuration and the runtime
    /// every request will run on.
    #[must_use]
    pub fn new(settings: Settings, runtime: Runtime) -> Self {
        let application: Self = glib::Object::builder()
            .property("application-id", APP_ID)
            .build();

        let imp = application.imp();
        imp.settings
            .set(settings)
            .expect("the application is configured once, here");
        assert!(
            imp.runtime.set(runtime).is_ok(),
            "the application is given its runtime once, here"
        );
        application
    }

    /// The I/O runtime. Every `cabalmail-kit` call goes through this, via
    /// [`crate::spawn_to_ui!`].
    #[must_use]
    pub fn runtime(&self) -> &Runtime {
        self.imp()
            .runtime
            .get()
            .expect("the runtime is set in `new`")
    }

    /// Configuration as resolved at startup.
    #[must_use]
    pub fn settings(&self) -> &Settings {
        self.imp()
            .settings
            .get()
            .expect("the settings are set in `new`")
    }

    fn setup_actions(&self) {
        let quit = gio::ActionEntry::builder("quit")
            .activate(|application: &Self, _, _| application.quit())
            .build();
        self.add_action_entries([quit]);
        self.set_accels_for_action("app.quit", &["<primary>q"]);
    }

    /// Applies the `theme` preference to libadwaita's style manager.
    fn apply_theme(&self) {
        adw::StyleManager::default()
            .set_color_scheme(color_scheme(self.settings().text(Key::Theme)));
    }
}

/// The `theme` preference as a libadwaita color scheme.
///
/// `system` is not "no opinion" — it is an explicit instruction to follow the
/// desktop, which is what `ColorScheme::Default` does. Anything else follows it
/// too: the schema rejects unknown values long before this, and guessing at a
/// forced appearance would be the worse failure.
fn color_scheme(theme: &str) -> adw::ColorScheme {
    match theme {
        "light" => adw::ColorScheme::ForceLight,
        "dark" => adw::ColorScheme::ForceDark,
        _ => adw::ColorScheme::Default,
    }
}

/// Starts the application and runs it until it quits.
///
/// # Errors
///
/// If the I/O runtime cannot be built. Everything else that can go wrong here
/// — a malformed resource bundle, a template that does not match its widget —
/// is a build-time bug and panics rather than asking the user to act on it.
pub fn run(settings: Settings) -> Result<ExitCode, String> {
    crate::register_resources();
    let runtime =
        Runtime::new().map_err(|error| format!("the I/O runtime could not start: {error}"))?;

    // GTK never sees our command line. The flags belong to the configuration
    // CLI, which has already parsed them, and handing the leftovers to
    // GApplication would have it reject or reinterpret them.
    let program = std::env::args()
        .next()
        .unwrap_or_else(|| "cabalmail".to_owned());
    let application = CabalmailApplication::new(settings, runtime);
    Ok(ExitCode::from(application.run_with_args(&[program])))
}

#[cfg(test)]
mod tests {
    use super::*;
    use cabalmail_kit::config::{Source, Value};

    /// Every value the schema accepts for `theme` maps to a scheme, and the
    /// default asks to follow the desktop.
    #[test]
    fn every_theme_the_schema_accepts_maps_to_a_color_scheme() {
        assert_eq!(color_scheme("light"), adw::ColorScheme::ForceLight);
        assert_eq!(color_scheme("dark"), adw::ColorScheme::ForceDark);
        assert_eq!(color_scheme("system"), adw::ColorScheme::Default);

        let settings = Settings::defaults();
        assert_eq!(
            color_scheme(settings.text(Key::Theme)),
            adw::ColorScheme::Default
        );

        // A value the schema does not accept never reaches here, but if one
        // ever did, following the desktop is the harmless reading.
        assert_eq!(color_scheme("chartreuse"), adw::ColorScheme::Default);
    }

    /// The application reads its configuration from the store it was given,
    /// not from the current user's file.
    #[test]
    fn settings_are_the_ones_the_application_was_built_with() {
        let runtime = Runtime::new().expect("the runtime builds");
        let mut settings = Settings::defaults();
        settings.set(
            Key::Theme,
            Value::Text("dark".to_owned()),
            Source::Flag("--theme".to_owned()),
        );

        let application = CabalmailApplication::new(settings, runtime);
        assert_eq!(application.settings().text(Key::Theme), "dark");
    }
}
