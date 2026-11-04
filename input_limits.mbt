///|
/// The parser bounds syntactic nesting. Cap the source before token allocation.
fn Source::check_size(self : Source) -> Unit raise AnalysisError {
  if self.text.length() > 1_000_000 {
    raise Unsupported(
      { path: self.path, line: 1, column: 1, },
      "source exceeds 1000000 string code units",
    )
  }
}
