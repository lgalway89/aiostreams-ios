import Foundation

/// One line's time on screen in milliseconds, which is when someone speaks.
struct SubSpan {
    var start: Double
    var end: Double
}

/**
 * Lines an added subtitle up with one of the file's own, on timing alone, so the two can be in
 * different languages. A port of the web app's `lib/subtitles/align.ts`, which the Shield and the
 * other apps sync addon subtitles with; the file's own lines come from its index (SubtitleIndex),
 * so the whole film is matched at once rather than as it plays.
 */
enum SubtitleAligner {
    struct Alignment {
        /// Shows the target's lines in time with the reference's.
        let delayMs: Double
        /// The target runs at this rate of the reference, as one timed for another frame rate does.
        let ratio: Double
        /// Clear of every other delay.
        let confident: Bool
    }

    /// Longer lines are signs or songs, not speech.
    private static let longestMs = 12_000.0
    /// A longer gap between the reference's lines is a stretch it wasn't read over.
    private static let unreadGapMs = 60_000.0
    private static let stepMs = 10.0
    /// Delays this close to the best match are its own edges.
    private static let nearMs = 3000.0
    private static let minMatch = 0.5
    private static let minLead = 1.6
    /// Lines starting or ending this close together start or end together.
    private static let edgeMs = 150.0
    private static let minEdgeLead = 2.0
    private static let agreeMs = 300.0
    private static let film = 24000.0 / 1001.0
    /// Film played at the PAL rate and back.
    private static let ratios = [1, 25 / film, film / 25]

    private static func kept(_ lines: [SubSpan]) -> [SubSpan] {
        lines.filter { $0.end > $0.start && $0.end - $0.start <= longestMs }
    }

    /// The speech in `lines`, in order, with overlapping lines joined.
    private static func speech(_ lines: [SubSpan], ratio: Double = 1) -> [SubSpan] {
        join(kept(lines).map { SubSpan(start: $0.start * ratio, end: $0.end * ratio) }.sorted { $0.start < $1.start }, gapMs: 0)
    }

    /// Sorted spans with those less than `gapMs` apart joined.
    private static func join(_ spans: [SubSpan], gapMs: Double) -> [SubSpan] {
        var joined: [SubSpan] = []
        for span in spans {
            if let last = joined.last, span.start - last.end <= gapMs {
                joined[joined.count - 1].end = max(last.end, span.end)
            } else {
                joined.append(span)
            }
        }
        return joined
    }

    /// The times the lines start and end at.
    private static func edges(_ lines: [SubSpan], ratio: Double = 1) -> (starts: [Double], ends: [Double]) {
        let lines = kept(lines)
        return (lines.map { $0.start * ratio }.sorted(), lines.map { $0.end * ratio }.sorted())
    }

    /// A curve over the delays from -limit to +limit, summed from its changes of slope.
    private final class Curve {
        let limitMs: Double
        var values: [Double]
        private var slope = 0.0
        private var value = 0.0

        init(limitMs: Double) {
            self.limitMs = limitMs
            values = Array(repeating: 0, count: Int((2 * limitMs / SubtitleAligner.stepMs).rounded()) + 1)
        }

        func clear() {
            for i in values.indices { values[i] = 0 }
            slope = 0
            value = 0
        }

        func add(_ delayMs: Double, _ change: Double) {
            let i = Int(((delayMs + limitMs) / SubtitleAligner.stepMs).rounded())
            if i >= values.count { return }
            if i >= 0 {
                values[i] += change
            } else {
                slope += change
                value -= change * Double(i) * SubtitleAligner.stepMs
            }
        }

        func sum() -> [Double] {
            var slope = self.slope
            var value = self.value
            for i in values.indices {
                let change = values[i]
                values[i] = value
                slope += change
                value += slope * SubtitleAligner.stepMs
            }
            return values
        }
    }

    /// How long `target`, moved by each delay, overlaps `fixed`: each pair adds a trapezoid of delays.
    private static func overlaps(_ fixed: [SubSpan], _ target: [SubSpan], _ curve: Curve) -> [Double] {
        curve.clear()
        let limit = curve.limitMs
        var lo = 0
        var hi = 0
        for t in target {
            while lo < fixed.count && fixed[lo].end - t.start <= -limit { lo += 1 }
            while hi < fixed.count && fixed[hi].start - t.end < limit { hi += 1 }
            var i = lo
            while i < hi {
                let f = fixed[i]
                let first = f.start - t.end
                let last = f.end - t.start
                let full = min(f.end - f.start, t.end - t.start)
                curve.add(first, 1)
                curve.add(first + full, -1)
                curve.add(last - full, -1)
                curve.add(last, 1)
                i += 1
            }
        }
        return curve.sum()
    }

    /// How many of `target`'s times each delay brings near one of `fixed`'s, nearer counting more.
    private static func meetings(_ fixed: [Double], _ target: [Double], _ curve: Curve) -> [Double] {
        curve.clear()
        let limit = curve.limitMs
        var lo = 0
        var hi = 0
        for t in target {
            while lo < fixed.count && fixed[lo] - t < -limit - edgeMs { lo += 1 }
            while hi < fixed.count && fixed[hi] - t <= limit + edgeMs { hi += 1 }
            var i = lo
            while i < hi {
                let delay = fixed[i] - t
                curve.add(delay - edgeMs, 1 / edgeMs)
                curve.add(delay, -2 / edgeMs)
                curve.add(delay + edgeMs, 1 / edgeMs)
                i += 1
            }
        }
        return curve.sum()
    }

    /// A curve's best delay and value, and its lead over the best delay clear of it.
    private static func peak(_ curve: [Double], limitMs: Double) -> (delayMs: Double, value: Double, lead: Double) {
        guard !curve.isEmpty else { return (0, 0, 0) }
        var best = 0
        var sum = 0.0
        for i in curve.indices {
            sum += curve[i]
            if curve[i] > curve[best] { best = i }
        }
        let top = curve[best]
        var left = best
        var right = best
        while left > 0 && curve[left - 1] >= top * 0.99 { left -= 1 }
        while right < curve.count - 1 && curve[right + 1] >= top * 0.99 { right += 1 }
        var next = 0.0
        for i in curve.indices where Double(abs(i - best)) * stepMs > nearMs { next = max(next, curve[i]) }
        let chance = sum / Double(curve.count)
        return (Double(left + right) / 2 * stepMs - limitMs, top,
                next > chance ? (top - chance) / (next - chance) : .infinity)
    }

    private struct Match {
        var delayMs: Double
        var ratio: Double
        var match: Double
        var lead: Double
    }

    private static func match(_ heard: [SubSpan], _ read: [SubSpan], _ target: [SubSpan], _ a: Curve, _ b: Curve) -> (Double, Double, Double) {
        var both = overlaps(heard, target, a)
        let shown = overlaps(read, target, b)
        let spoken = heard.reduce(0) { $0 + $1.end - $1.start }
        for i in both.indices {
            let whole = spoken + shown[i] - both[i]
            both[i] /= whole == 0 ? 1 : whole
        }
        let best = peak(both, limitMs: a.limitMs)
        return (best.delayMs, best.value, best.lead)
    }

    /// Dense dialogue overlaps almost as well seconds apart; the moments lines start and end still tell.
    private static func edgesAgree(_ reference: [SubSpan], _ target: [SubSpan], _ found: Match,
                                   _ range: (Double, Double), _ a: Curve, _ b: Curve) -> Bool {
        let fixed = edges(reference)
        let moved = edges(target, ratio: found.ratio)
        let inside = { (times: [Double]) in times.filter { $0 > range.0 && $0 < range.1 } }
        var starts = meetings(fixed.starts, inside(moved.starts), a)
        let ends = meetings(fixed.ends, inside(moved.ends), b)
        for i in starts.indices { starts[i] += ends[i] }
        let best = peak(starts, limitMs: a.limitMs)
        return best.lead >= minEdgeLead && abs(best.delayMs - found.delayMs) <= agreeMs
    }

    /// The delay within `limitMs` that lines `target` up with `reference`.
    static func align(reference: [SubSpan], target: [SubSpan], limitMs: Double) -> Alignment? {
        let heard = speech(reference)
        guard let firstHeard = heard.first, let lastHeard = heard.last else { return nil }
        let read = join(heard, gapMs: unreadGapMs)
        let range = (firstHeard.start - limitMs, lastHeard.end + limitMs)
        let a = Curve(limitMs: limitMs)
        let b = Curve(limitMs: limitMs)
        var found: Match?
        for ratio in ratios {
            let lines = speech(target, ratio: ratio).filter { $0.end > range.0 && $0.start < range.1 }
            if lines.isEmpty { continue }
            let (delay, value, lead) = match(heard, read, lines, a, b)
            if found == nil || value > found!.match { found = Match(delayMs: delay, ratio: ratio, match: value, lead: lead) }
        }
        guard let found else { return nil }
        let confident = found.match >= minMatch
            && (found.lead >= minLead || edgesAgree(reference, target, found, range, a, b))
        return Alignment(delayMs: found.delayMs.rounded(), ratio: found.ratio, confident: confident)
    }
}

/// The line timings of an SRT, WebVTT or ASS/SSA file.
enum SubtitleTimings {
    private static let arrow = try! NSRegularExpression(
        pattern: #"(?:(\d+):)?(\d{1,2}):(\d{2})[,.](\d{1,3})\s*-->\s*(?:(\d+):)?(\d{1,2}):(\d{2})[,.](\d{1,3})"#)
    private static let dialogue = try! NSRegularExpression(
        pattern: #"^Dialogue:\s*[^,]*,\s*(\d+):(\d{2}):(\d{2})\.(\d{1,3})\s*,\s*(\d+):(\d{2}):(\d{2})\.(\d{1,3})"#,
        options: .anchorsMatchLines)

    static func parse(_ text: String) -> [SubSpan] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        func number(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        func ms(_ m: NSTextCheckingResult, from i: Int) -> Double {
            let hours = Double(number(m, i) ?? "0") ?? 0
            let minutes = Double(number(m, i + 1) ?? "0") ?? 0
            let seconds = Double(number(m, i + 2) ?? "0") ?? 0
            let fraction = number(m, i + 3) ?? "0"
            let part = (Double(fraction) ?? 0) / pow(10, Double(fraction.count))
            return ((hours * 60 + minutes) * 60 + seconds + part) * 1000
        }
        var lines = arrow.matches(in: text, range: whole).map { SubSpan(start: ms($0, from: 1), end: ms($0, from: 5)) }
        if lines.isEmpty {
            lines = dialogue.matches(in: text, range: whole).map { SubSpan(start: ms($0, from: 1), end: ms($0, from: 5)) }
        }
        return lines
    }
}
