import Foundation

/// Which of a window's view trees owns a slice of its navigation.
///
/// A layout swap (an iPhone Duo fold, an iPad window crossing the size-class
/// line) builds a new view tree while the old one is still being torn down.
/// The tree that appeared last takes over once its landing or hand-off has
/// run (`mount`); until then it sees nothing, so a list mounts only after
/// the restore it applies is parked, and neither it nor the tree it replaces
/// can write (`canWrite`).
struct TreeGate: Equatable {
    /// The tree that owns the slice.
    private(set) var mounted: UUID?
    /// The tree that appeared last.
    private(set) var appearing: UUID?

    /// `tree` appeared. Returns whether it replaces another tree, which is a
    /// layout swap's rebuild rather than a first appearance or a tab switch
    /// bringing the same tree back.
    mutating func appear(_ tree: UUID) -> Bool {
        appearing = tree
        return mounted != nil && mounted != tree
    }

    /// `tree` takes over.
    mutating func mount(_ tree: UUID) {
        mounted = tree
    }

    /// Whether `tree` should draw the slice: only once it has taken over.
    func shows(_ tree: UUID) -> Bool {
        tree == mounted
    }

    /// Whether `tree` may change the slice: it has taken over and nothing
    /// has appeared since.
    func canWrite(_ tree: UUID) -> Bool {
        tree == mounted && tree == appearing
    }

    /// Whether `tree` is still the last to appear: a second swap during an
    /// await may have built another.
    func isAppearing(_ tree: UUID) -> Bool {
        tree == appearing
    }
}
