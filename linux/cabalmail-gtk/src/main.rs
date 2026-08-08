//! Entry point for the Cabalmail Linux client.
//!
//! The `AdwApplication` shell, the GResource bundle, and the `spawn_to_ui!`
//! async bridge land in Phase 1, work item 4. Until then this binary exists so
//! the workspace, the binary name, and the packaging paths are settled first.

fn main() {
    println!(
        "cabalmail {} — the GTK application shell is not implemented yet \
         (Phase 1, work item 4).",
        env!("CARGO_PKG_VERSION")
    );
}
