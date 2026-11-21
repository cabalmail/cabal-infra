- **The iPad split no longer measures a width nothing reads.**
  `SplitShell` kept a `contentColumnWidth` state, written from a geometry
  reader on the list column and read by nothing since iPadOS began
  drawing the search field in the column's header. The state, the reader
  and `recordContentColumnWidth` are gone. The Mac window's own width
  measurement, which its search field does read, is untouched, and
  nothing visible changes. One source scan
  (`ColumnToolbarOccupantsSourceScanTests`) ended its slice on the
  deleted function's comment; its end marker is now the next heading in
  the file, with every assertion unchanged.
