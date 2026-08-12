//! The tokio-to-GTK bridge.
//!
//! GTK owns the main thread and its `glib::MainContext` loop; the HTTP stack
//! (Phase 3) wants a tokio reactor. Getting this wrong produces an app that
//! blocks the UI on every request or deadlocks under load, and it is very hard
//! to retrofit — so the pattern is fixed here, before any feature code exists,
//! and every later phase spells it exactly one way:
//!
//! - The application owns exactly one multi-thread runtime, created at startup.
//! - Every `cabalmail-kit` call is spawned onto it. Kit futures are `Send` and
//!   never touch GTK types — structurally so, since the kit crate has no GTK
//!   dependency to touch.
//! - Results come back over an `async_channel` consumed by a
//!   `glib::spawn_future_local` task that owns the widget handles.
//! - Widgets are never captured across the `.await` that crosses the boundary;
//!   [`spawn_to_ui!`] takes `glib::clone!` capture attributes so the handler
//!   holds weak references.

use std::cell::RefCell;
use std::future::Future;
use std::time::Duration;

use crate::glib;

/// The application's I/O runtime: one multi-thread tokio runtime, plus the one
/// way of getting a result off it and onto the UI thread.
pub struct Runtime {
    // `Option` so [`Runtime::shutdown`] can consume the tokio runtime through a
    // shared reference — the application holds this behind `&self` for its
    // whole life, and shutting down is the last thing it does with it.
    inner: RefCell<Option<tokio::runtime::Runtime>>,
}

impl Runtime {
    /// Builds the runtime.
    ///
    /// # Errors
    ///
    /// If the worker threads cannot be spawned, which is a
    /// nothing-will-work-from-here condition rather than a recoverable one.
    pub fn new() -> std::io::Result<Self> {
        tokio::runtime::Builder::new_multi_thread()
            .thread_name("cabalmail-io")
            .enable_all()
            .build()
            .map(|runtime| Self {
                inner: RefCell::new(Some(runtime)),
            })
    }

    /// Runs `future` on the runtime and hands its result to `on_result` on the
    /// UI thread.
    ///
    /// Prefer the [`spawn_to_ui!`] macro, which is the same call with
    /// `glib::clone!` captures wrapped around the handler.
    ///
    /// `on_result` does not run if the future panics, if the application is
    /// shutting down, or if the local task is dropped — all of which mean
    /// there is no longer a widget waiting for the answer.
    pub fn spawn_to_ui<F, H>(&self, future: F, on_result: H)
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
        H: FnOnce(F::Output) + 'static,
    {
        let borrowed = self.inner.borrow();
        let Some(runtime) = borrowed.as_ref() else {
            // Past shutdown. The window this would have updated is gone.
            return;
        };

        // Capacity one: there is exactly one result, and the sender is dropped
        // as soon as it has been handed over.
        let (sender, receiver) = async_channel::bounded(1);
        runtime.spawn(async move {
            // A closed channel means the receiving task went away while the
            // request was in flight, which is ordinary — a closed window, a
            // superseded request.
            let _ = sender.send(future.await).await;
        });
        glib::spawn_future_local(async move {
            if let Ok(result) = receiver.recv().await {
                on_result(result);
            }
        });
    }

    /// Stops the runtime, waiting at most `grace` for work in flight.
    ///
    /// Dropping a tokio runtime blocks the calling thread until its workers are
    /// done. On the GTK main thread, at quit, that turns one wedged request
    /// into a window that will not close — so quitting is bounded instead.
    pub fn shutdown(&self, grace: Duration) {
        let runtime = self.inner.borrow_mut().take();
        if let Some(runtime) = runtime {
            runtime.shutdown_timeout(grace);
        }
    }
}

/// Runs a future on the application's runtime and handles its result on the UI
/// thread — the single spelling of that dance.
///
/// Everything from the first `#` onwards is passed to `glib::clone!` verbatim,
/// so every capture form it understands works here:
///
/// ```ignore
/// spawn_to_ui!(
///     app.runtime(),
///     async move { client.list_folders().await },
///     #[weak]
///     window,
///     move |folders| window.show_folders(folders)
/// );
/// ```
///
/// Without captures the handler is passed through unchanged:
///
/// ```ignore
/// spawn_to_ui!(app.runtime(), async move { probe().await }, |ok| println!("{ok}"));
/// ```
#[macro_export]
macro_rules! spawn_to_ui {
    ($runtime:expr, $future:expr, #$($handler:tt)+) => {
        $crate::runtime::Runtime::spawn_to_ui(
            &$runtime,
            $future,
            $crate::glib::clone!(#$($handler)+),
        )
    };
    ($runtime:expr, $future:expr, $handler:expr $(,)?) => {
        $crate::runtime::Runtime::spawn_to_ui(&$runtime, $future, $handler)
    };
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::glib::prelude::*;
    use std::cell::Cell;
    use std::rc::Rc;
    use std::thread::ThreadId;

    /// Runs `body` with a main context of its own as the thread default, then
    /// spins that context until something quits the loop or `patience` runs
    /// out.
    ///
    /// A private context rather than `MainContext::default()`: the default one
    /// is process-wide, and `cargo test` runs these in parallel on several
    /// threads. `glib::spawn_future_local` — the call under test — resolves
    /// the *thread default*, so this exercises the real path while keeping
    /// each test to itself.
    fn on_a_main_context<F>(patience: Duration, body: F)
    where
        F: FnOnce(glib::MainLoop),
    {
        let context = glib::MainContext::new();
        context
            .with_thread_default(|| {
                let main_loop = glib::MainLoop::new(Some(&context), false);
                body(main_loop.clone());
                // Attached to *this* context explicitly. `timeout_add_local`
                // and friends attach to the process-wide default context,
                // which this loop never dispatches — a test that failed would
                // hang instead of failing.
                glib::timeout_source_new(
                    patience,
                    Some("patience"),
                    glib::Priority::DEFAULT,
                    glib::clone!(
                        #[strong]
                        main_loop,
                        move || {
                            main_loop.quit();
                            glib::ControlFlow::Break
                        }
                    ),
                )
                .attach(Some(&context));
                main_loop.run();
            })
            .expect("the context is not owned by another thread");
    }

    /// The property the whole bridge exists for: work runs off the UI thread,
    /// its result arrives on it.
    #[test]
    fn a_spawned_result_reaches_the_main_context() {
        let runtime = Runtime::new().expect("the runtime builds");
        let seen: Rc<Cell<Option<u32>>> = Rc::new(Cell::new(None));

        on_a_main_context(Duration::from_secs(5), |main_loop| {
            runtime.spawn_to_ui(
                async { 42_u32 },
                glib::clone!(
                    #[strong]
                    seen,
                    #[strong]
                    main_loop,
                    move |value| {
                        seen.set(Some(value));
                        main_loop.quit();
                    }
                ),
            );
        });

        assert_eq!(seen.get(), Some(42));
    }

    /// The handler owns widget handles, so it has to run on the thread that
    /// owns the widgets — not on whichever worker finished the future.
    #[test]
    fn the_handler_runs_on_the_thread_that_spawned_it() {
        let runtime = Runtime::new().expect("the runtime builds");
        let ui_thread = std::thread::current().id();
        let ran_on: Rc<Cell<Option<ThreadId>>> = Rc::new(Cell::new(None));
        let ran_off: Rc<Cell<Option<ThreadId>>> = Rc::new(Cell::new(None));

        on_a_main_context(Duration::from_secs(5), |main_loop| {
            runtime.spawn_to_ui(
                async { std::thread::current().id() },
                glib::clone!(
                    #[strong]
                    ran_on,
                    #[strong]
                    ran_off,
                    #[strong]
                    main_loop,
                    move |future_thread| {
                        ran_off.set(Some(future_thread));
                        ran_on.set(Some(std::thread::current().id()));
                        main_loop.quit();
                    }
                ),
            );
        });

        assert_eq!(ran_on.get(), Some(ui_thread));
        assert_ne!(
            ran_off.get(),
            Some(ui_thread),
            "the future ran on the UI thread"
        );
    }

    /// Results are delivered per request, not coalesced or dropped when
    /// several are in flight at once.
    #[test]
    fn every_spawned_future_delivers_its_own_result() {
        const REQUESTS: u32 = 32;

        let runtime = Runtime::new().expect("the runtime builds");
        let delivered: Rc<RefCell<Vec<u32>>> = Rc::new(RefCell::new(Vec::new()));

        on_a_main_context(Duration::from_secs(10), |main_loop| {
            for request in 0..REQUESTS {
                runtime.spawn_to_ui(
                    async move { request },
                    glib::clone!(
                        #[strong]
                        delivered,
                        #[strong]
                        main_loop,
                        move |value| {
                            delivered.borrow_mut().push(value);
                            if delivered.borrow().len() == REQUESTS as usize {
                                main_loop.quit();
                            }
                        }
                    ),
                );
            }
        });

        let mut delivered = delivered.borrow().clone();
        delivered.sort_unstable();
        assert_eq!(delivered, (0..REQUESTS).collect::<Vec<_>>());
    }

    /// The macro's capture form is the one every call site will use, so it is
    /// the form that has to keep compiling: the handler holds a weak reference
    /// and still sees the result.
    #[test]
    fn the_macro_delivers_through_a_weak_capture() {
        let runtime = Runtime::new().expect("the runtime builds");
        // Any GObject will do — this stands in for the window a real handler
        // would hold. Constructing a widget would need an initialized GTK, and
        // the bridge has nothing to do with widgets.
        let anchor = glib::Object::new::<glib::Object>();
        let seen: Rc<Cell<bool>> = Rc::new(Cell::new(false));

        on_a_main_context(Duration::from_secs(5), |main_loop| {
            spawn_to_ui!(
                runtime,
                async { "done" },
                #[weak]
                anchor,
                #[strong]
                seen,
                #[strong]
                main_loop,
                move |result: &str| {
                    assert_eq!(result, "done");
                    // Upgraded: the handler really is holding the object.
                    assert!(anchor.type_().is_a(glib::Object::static_type()));
                    seen.set(true);
                    main_loop.quit();
                }
            );
        });

        assert!(seen.get(), "the handler never ran");
    }

    /// A weak capture whose object is gone drops the handler instead of
    /// resurrecting it — the reason captures are weak in the first place.
    #[test]
    fn a_dropped_weak_capture_skips_the_handler() {
        let runtime = Runtime::new().expect("the runtime builds");
        let anchor = glib::Object::new::<glib::Object>();
        let ran: Rc<Cell<bool>> = Rc::new(Cell::new(false));

        on_a_main_context(Duration::from_millis(250), |_| {
            spawn_to_ui!(
                runtime,
                async { 1_u8 },
                #[weak]
                anchor,
                #[strong]
                ran,
                move |_| {
                    let _ = anchor.type_();
                    ran.set(true);
                }
            );
            drop(anchor);
        });

        assert!(!ran.get(), "the handler ran with a dead capture");
    }

    /// Quitting must not wait on work in flight, and work handed in afterwards
    /// must not resurrect the runtime.
    #[test]
    fn work_offered_after_shutdown_is_dropped() {
        let runtime = Runtime::new().expect("the runtime builds");
        let ran: Rc<Cell<bool>> = Rc::new(Cell::new(false));

        runtime.shutdown(Duration::from_millis(100));

        on_a_main_context(Duration::from_millis(250), |_| {
            runtime.spawn_to_ui(
                async { 1_u8 },
                glib::clone!(
                    #[strong]
                    ran,
                    move |_| ran.set(true)
                ),
            );
        });

        assert!(!ran.get(), "a shut-down runtime still delivered a result");
    }
}
