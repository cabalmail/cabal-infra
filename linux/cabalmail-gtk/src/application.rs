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
    /// Builds the application around a resolved configuration.
    ///
    /// The runtime is attached separately, by
    /// [`attach_runtime`](Self::attach_runtime), because only the primary
    /// instance has any use for one.
    #[must_use]
    pub fn new(settings: Settings) -> Self {
        let application: Self = glib::Object::builder()
            .property("application-id", APP_ID)
            .build();

        application
            .imp()
            .settings
            .set(settings)
            .expect("the application is configured once, here");
        application
    }

    /// Gives the application the runtime every request will run on.
    ///
    /// # Panics
    ///
    /// If a runtime has already been attached.
    pub fn attach_runtime(&self, runtime: Runtime) {
        assert!(
            self.imp().runtime.set(runtime).is_ok(),
            "the application is given its runtime once"
        );
    }

    /// The I/O runtime. Every `cabalmail-kit` call goes through this, via
    /// [`crate::spawn_to_ui!`].
    ///
    /// # Panics
    ///
    /// If no runtime was attached. Only a remote instance runs without one,
    /// and a remote instance never reaches any UI code.
    #[must_use]
    pub fn runtime(&self) -> &Runtime {
        self.imp()
            .runtime
            .get()
            .expect("the primary instance is given a runtime before it starts")
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
/// The application ID is registered before anything else is built. A second
/// launch while one is already running is a *remote* instance: it hands an
/// activation to the running client and exits, so it needs neither a runtime
/// nor a window, and this run's overrides will not reach the client that is
/// already up. Registering first is what makes both of those knowable.
///
/// # Errors
///
/// If the application cannot register, or if the I/O runtime cannot be built.
/// Everything else that can go wrong here — a malformed resource bundle, a
/// template that does not match its widget — is a build-time bug and panics
/// rather than asking the user to act on it.
pub fn run(settings: Settings) -> Result<ExitCode, String> {
    crate::register_resources();
    let application = CabalmailApplication::new(settings);

    // Registration emits `startup` on the primary instance, before the runtime
    // is attached — which is why nothing in `startup` may reach for it.
    application
        .register(gio::Cancellable::NONE)
        .map_err(|error| format!("the application could not register: {error}"))?;

    if application.is_remote() {
        for notice in ignored_override_notices(application.settings()) {
            eprintln!("cabalmail: {notice}");
        }
    } else {
        let runtime =
            Runtime::new().map_err(|error| format!("the I/O runtime could not start: {error}"))?;
        application.attach_runtime(runtime);
    }

    // GTK never sees our command line. The flags belong to the configuration
    // CLI, which has already parsed them, and handing the leftovers to
    // GApplication would have it reject or reinterpret them.
    let program = std::env::args()
        .next()
        .unwrap_or_else(|| "cabalmail".to_owned());
    Ok(ExitCode::from(application.run_with_args(&[program])))
}

/// Starts the application, asserts it reaches a main window, and quits.
///
/// The only assertion that covers the *packaged artifact* rather than the
/// source tree: the smoke job installs the built package into a clean
/// container and runs the installed binary through this. A break that the
/// widget tests cannot see — a GResource that did not get bundled, a data file
/// the package forgot to install, a shared library the dependency array does
/// not name — shows up here and nowhere else.
///
/// [`NON_UNIQUE`](gio::ApplicationFlags::NON_UNIQUE) because the whole point
/// is to start a client: without it a self-test run on a machine where the
/// client is already up registers as a remote instance, exits 0 having built
/// no window, and reports success for a binary it never started.
///
/// # Errors
///
/// If the application cannot register, if the I/O runtime cannot be built, or
/// if the run finished without a window ever becoming visible.
pub fn self_test(settings: Settings) -> Result<ExitCode, String> {
    crate::register_resources();
    let application = CabalmailApplication::new(settings);
    application.set_flags(application.flags() | gio::ApplicationFlags::NON_UNIQUE);

    application
        .register(gio::Cancellable::NONE)
        .map_err(|error| format!("the application could not register: {error}"))?;
    let runtime =
        Runtime::new().map_err(|error| format!("the I/O runtime could not start: {error}"))?;
    application.attach_runtime(runtime);

    let reached = std::rc::Rc::new(std::cell::Cell::new(false));
    let recorder = std::rc::Rc::clone(&reached);
    application.connect_activate(move |application| {
        // From an idle callback rather than from here: a handler connected to
        // `activate` runs before the class closure that builds the window, so
        // asking now would find no window and report a failure that is only
        // this test's own ordering.
        let application = application.clone();
        let recorder = std::rc::Rc::clone(&recorder);
        glib::idle_add_local_once(move || {
            recorder.set(
                application
                    .active_window()
                    .is_some_and(|window| window.is_visible()),
            );
            application.quit();
        });
    });

    let program = std::env::args()
        .next()
        .unwrap_or_else(|| "cabalmail".to_owned());
    let code = application.run_with_args(&[program]);
    verdict(reached.get(), code == glib::ExitCode::SUCCESS)?;
    println!("{}", cabalmail_kit::SELF_TEST_MARKER);
    Ok(ExitCode::SUCCESS)
}

/// Whether the run counts as a started client.
///
/// Split out because it is the whole assertion: the rest of [`self_test`]
/// needs a display and a main loop to exercise, and a rule that only runs
/// inside those is a rule nothing can check. Both conditions are required —
/// a client that drew nothing and exited 0 is the failure the smoke job
/// exists to catch, and reporting it as success is exactly the shape of
/// falsely-green this whole arrangement is built against.
fn verdict(reached_a_window: bool, exited_cleanly: bool) -> Result<(), String> {
    if !reached_a_window {
        return Err("the client exited without ever showing a window".to_owned());
    }
    if !exited_cleanly {
        return Err("the client reached a window but exited non-zero".to_owned());
    }
    Ok(())
}

/// What to say when this invocation only raises the window of a client that is
/// already running.
///
/// Transient sources — flags and `CABALMAIL_*` variables — are the whole point
/// of the configuration CLI, and they apply to the process that resolved them.
/// A remote instance exits without ever starting a client, so they are dropped;
/// saying which ones is cheaper than the debugging session that follows a
/// silent one. A launch that overrode nothing gets no notice: raising the
/// existing window is exactly what was asked for.
///
/// Phase 6's live settings store can carry these across to the running client,
/// at which point this goes away.
fn ignored_override_notices(settings: &Settings) -> Vec<String> {
    let mut origins: Vec<String> = Key::ALL
        .iter()
        .copied()
        .filter(|key| settings.source(*key).is_transient())
        .filter_map(|key| settings.source(key).origin())
        .collect();
    origins.sort();

    if origins.is_empty() {
        return Vec::new();
    }
    vec![format!(
        "already running; raised the existing window. This run's overrides ({}) were ignored — \
         quit the running client first, or use `cabalmail config set` to make them stick.",
        origins.join(", ")
    )]
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
        let mut settings = Settings::defaults();
        settings.set(
            Key::Theme,
            Value::Text("dark".to_owned()),
            Source::Flag("--theme".to_owned()),
        );

        let application = CabalmailApplication::new(settings);
        assert_eq!(application.settings().text(Key::Theme), "dark");
    }

    /// The runtime is attached after construction, so a remote instance can
    /// skip building one.
    #[test]
    fn the_runtime_is_the_one_that_was_attached() {
        let application = CabalmailApplication::new(Settings::defaults());
        application.attach_runtime(Runtime::new().expect("the runtime builds"));
        application.runtime().shutdown(Duration::from_millis(0));
    }

    /// The assertion the smoke job rests on. A client that drew nothing must
    /// not report success, whatever it exited with — that is the failure the
    /// job exists to catch, and the one a packaging break looks like.
    #[test]
    fn a_self_test_that_drew_no_window_is_a_failure() {
        for exited_cleanly in [true, false] {
            let error = verdict(false, exited_cleanly).expect_err("nothing was drawn");
            assert!(error.contains("without ever showing a window"), "{error}");
        }
    }

    /// A window that came up and then took the process down with it is a
    /// break too — a crash on shutdown is still a crash.
    #[test]
    fn a_self_test_that_exited_badly_is_a_failure() {
        let error = verdict(true, false).expect_err("it exited non-zero");
        assert!(error.contains("exited non-zero"), "{error}");
    }

    #[test]
    fn a_self_test_that_drew_a_window_and_exited_cleanly_passes() {
        assert_eq!(verdict(true, true), Ok(()));
    }

    /// A launch that overrode nothing only asked for the window, so raising it
    /// is the whole answer and there is nothing to report.
    #[test]
    fn a_launch_without_overrides_is_told_nothing() {
        assert!(ignored_override_notices(&Settings::defaults()).is_empty());
    }

    /// Both transient sources are named, so the user can see which of this
    /// run's arguments did not reach the client that was already up.
    #[test]
    fn dropped_overrides_are_named_by_where_they_came_from() {
        let mut settings = Settings::defaults();
        settings.set(
            Key::Theme,
            Value::Text("dark".to_owned()),
            Source::Flag("--theme".to_owned()),
        );
        let dispose_action = settings.get(Key::DisposeAction).clone();
        settings.set(
            Key::DisposeAction,
            dispose_action,
            Source::Env("CABALMAIL_DISPOSE_ACTION".to_owned()),
        );

        let notices = ignored_override_notices(&settings);
        assert_eq!(notices.len(), 1, "{notices:?}");
        assert!(notices[0].contains("--theme"), "{}", notices[0]);
        assert!(
            notices[0].contains("CABALMAIL_DISPOSE_ACTION"),
            "{}",
            notices[0]
        );
    }
}
