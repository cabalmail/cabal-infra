- **iPhone Duo fold adapter in the Apple app layer.** A main window now
  publishes its fold (`\.foldState`: none, a vertical crease in book pose
  or a horizontal one in laptop pose, in the window's own coordinates)
  from the iOS 27.1 reserved-region and hinge APIs, behind the
  SwiftUICore 8.0.85 guard in `Platform/FoldGeometry.swift`. A reading
  counts only once two layout passes agree, and a fold holds while the
  hinge moves, ending on a fully open hinge, after 0.6 s at rest with no
  region, or when the window changes size. `onFoldPiecesChange(_:)` gives
  a view its bounds less the crease. Nothing reads it yet, so nothing
  changes on screen; the Duo columns, toasts, reader bar and crease
  margins build on it. The iOS-hosted suite fails if CI's Xcode stops
  compiling the guarded code (`FoldAPICompiledTests`).
