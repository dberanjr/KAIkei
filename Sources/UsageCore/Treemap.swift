import Foundation

public struct TreemapRect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// Squarified treemap (Bruls, Huizing and van Wijk): tiles sized by weight and kept close to square, so a label fits in each.
public enum Treemap {
    /// One rectangle per weight, in the same order. Callers pass weights largest first for the best shapes.
    /// A weight of zero (or less) gets an empty tile.
    public static func layout(weights: [Double], in bounds: TreemapRect) -> [TreemapRect] {
        var out = [TreemapRect](repeating: TreemapRect(x: bounds.x, y: bounds.y, width: 0, height: 0), count: weights.count)
        let positive = weights.indices.filter { weights[$0] > 0 }
        let total = positive.reduce(0) { $0 + weights[$1] }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return out }
        let scale = bounds.width * bounds.height / total
        var remaining = positive[...]
        var free = bounds

        func worst(_ row: [Int], side: Double) -> Double {
            let areas = row.map { weights[$0] * scale }
            let sum = areas.reduce(0, +)
            guard sum > 0, let low = areas.min(), let high = areas.max() else { return .infinity }
            return max(side * side * high / (sum * sum), sum * sum / (side * side * low))
        }

        while !remaining.isEmpty {
            let side = min(free.width, free.height)
            var row: [Int] = []
            while let next = remaining.first {
                if row.isEmpty || worst(row + [next], side: side) <= worst(row, side: side) {
                    row.append(next)
                    remaining = remaining.dropFirst()
                } else { break }
            }
            let rowArea = row.reduce(0) { $0 + weights[$1] * scale }
            if free.width >= free.height {  // lay the row down the left edge as a column
                let columnWidth = remaining.isEmpty ? free.width : rowArea / free.height
                var y = free.y
                for i in row {
                    let h = remaining.isEmpty && i == row.last ? free.y + free.height - y : weights[i] * scale / columnWidth
                    out[i] = TreemapRect(x: free.x, y: y, width: columnWidth, height: h)
                    y += h
                }
                free = TreemapRect(x: free.x + columnWidth, y: free.y, width: free.width - columnWidth, height: free.height)
            } else {  // lay the row along the top edge
                let rowHeight = remaining.isEmpty ? free.height : rowArea / free.width
                var x = free.x
                for i in row {
                    let w = remaining.isEmpty && i == row.last ? free.x + free.width - x : weights[i] * scale / rowHeight
                    out[i] = TreemapRect(x: x, y: free.y, width: w, height: rowHeight)
                    x += w
                }
                free = TreemapRect(x: free.x, y: free.y + rowHeight, width: free.width, height: free.height - rowHeight)
            }
        }
        return out
    }

    /// Keeps the first `keeping` weights and totals the rest, so a long tail becomes one "other" tile instead of unreadable slivers.
    public static func collapse(weights: [Double], keeping: Int) -> (kept: [Int], restWeight: Double, restCount: Int) {
        let kept = Array(weights.indices.prefix(max(keeping, 0)))
        let rest = weights.dropFirst(kept.count)
        return (kept, rest.reduce(0, +), rest.count)
    }
}
