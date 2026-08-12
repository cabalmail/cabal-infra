//! The main window.
//!
//! Its shape comes from `resources/window.blp`, compiled to GtkBuilder XML at
//! build time and bound here as a composite template. Phase 4 replaces the
//! status page inside it with the three-pane split view; the window, the
//! header bar, and this binding stay.

use adw::subclass::prelude::*;
use gtk::prelude::*;
use gtk::{gio, glib};

mod imp {
    use super::*;

    #[derive(Debug, Default, gtk::CompositeTemplate)]
    #[template(resource = "/com/cabalmail/Cabalmail/ui/window.ui")]
    pub struct CabalmailWindow;

    #[glib::object_subclass]
    impl ObjectSubclass for CabalmailWindow {
        const NAME: &'static str = "CabalmailWindow";
        type Type = super::CabalmailWindow;
        type ParentType = adw::ApplicationWindow;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for CabalmailWindow {}
    impl WidgetImpl for CabalmailWindow {}
    impl WindowImpl for CabalmailWindow {}
    impl ApplicationWindowImpl for CabalmailWindow {}
    impl AdwApplicationWindowImpl for CabalmailWindow {}
}

glib::wrapper! {
    pub struct CabalmailWindow(ObjectSubclass<imp::CabalmailWindow>)
        @extends adw::ApplicationWindow, gtk::ApplicationWindow, gtk::Window, gtk::Widget,
        @implements gio::ActionGroup, gio::ActionMap, gtk::Accessible, gtk::Buildable,
                    gtk::ConstraintTarget, gtk::Native, gtk::Root, gtk::ShortcutManager;
}

impl CabalmailWindow {
    #[must_use]
    pub fn new(application: &impl IsA<gtk::Application>) -> Self {
        glib::Object::builder()
            .property("application", application)
            .build()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use adw::prelude::AdwApplicationWindowExt;

    /// Builds the window the way the application does, and checks the two
    /// things a broken template shows up as: a title that is not ours, and a
    /// window with nothing in it.
    ///
    /// Needs a display. CI runs the app crate's tests under `xvfb-run`; on a
    /// developer machine without one — a bare SSH session — this reports why
    /// it did nothing rather than failing on the environment.
    #[test]
    fn the_window_builds_from_its_template() {
        if adw::init().is_err() {
            eprintln!("skipping: no display server");
            return;
        }
        crate::register_resources();

        // No application: GTK warns about a window added to one that has not
        // emitted `startup` yet, and the template — which is what this test is
        // about — does not care either way.
        let window: CabalmailWindow = glib::Object::builder().build();

        assert_eq!(window.title().as_deref(), Some("Cabalmail"));
        assert!(
            window.content().is_some(),
            "the template bound no content into the window"
        );
    }
}
