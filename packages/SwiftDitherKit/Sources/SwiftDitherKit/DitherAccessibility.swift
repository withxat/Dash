/// Optional localized semantic labels supplied to assistive technologies.
public struct DitherAccessibility: Hashable, Sendable {
  /// A concise, localized name for the chart.
  public var title: String?
  /// A localized sentence describing the chart's purpose or takeaway.
  public var summary: String?
  /// A localized label for categories, slices, or radar axes.
  public var categoryAxisLabel: String?
  /// A localized label for the numeric value axis.
  public var valueAxisLabel: String?

  public init(
    title: String? = nil,
    summary: String? = nil,
    categoryAxisLabel: String? = nil,
    valueAxisLabel: String? = nil
  ) {
    self.title = title
    self.summary = summary
    self.categoryAxisLabel = categoryAxisLabel
    self.valueAxisLabel = valueAxisLabel
  }
}
