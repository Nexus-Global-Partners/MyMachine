/// Baselines from the immediately preceding successful census. A failed census
/// breaks continuity: later totals must not be paired with an older interval.
public struct CounterObservationHistory<Key: Hashable, Counter> {
    private var counters: [Key: Counter] = [:]

    public init() {}

    public subscript(key: Key) -> Counter? { counters[key] }

    public mutating func replace(with observation: [Key: Counter]?) {
        counters = observation ?? [:]
    }
}
