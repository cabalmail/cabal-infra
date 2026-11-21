- **The iPad split no longer measures a width nothing reads.**
  `SplitShell` kept a `contentColumnWidth` state, written from a geometry
  reader on the list column and read by nothing since iPadOS began
  drawing the search field in the column's header. The state, the reader
  and `recordContentColumnWidth` are gone, so the split is told about one
  layout change fewer on every resize. The Mac window's own width
  measurement, which its search field does read, is untouched. Nothing
  visible changes.
