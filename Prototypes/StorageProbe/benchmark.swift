import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: benchmark FOLDER\n", stderr)
    exit(1)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let clock = ContinuousClock()
let start = clock.now
let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
    .filter { $0.pathExtension.lowercased() == "txt" }
let scan = start.duration(to: clock.now)
var corpus: [(URL, String)] = []
corpus.reserveCapacity(urls.count)
for url in urls {
    corpus.append((url, try String(contentsOf: url, encoding: .utf8)))
}
let load = start.duration(to: clock.now)
let queries = ["marker-0000", "marker-0500", "marker-0999", "sample text", "not-here"]
var durations: [Double] = []
for _ in 0..<20 {
    for query in queries {
        let begin = clock.now
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        _ = corpus.filter { item in terms.allSatisfy { term in item.0.lastPathComponent.localizedCaseInsensitiveContains(term) || item.1.localizedCaseInsensitiveContains(term) } }
        durations.append(Double(begin.duration(to: clock.now).components.attoseconds) / 1e15 + Double(begin.duration(to: clock.now).components.seconds) * 1000)
    }
}
durations.sort()
func ms(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}
print("files=\(urls.count) scan_ms=\(ms(scan)) load_ms=\(ms(load)) query_p50_ms=\(durations[durations.count / 2]) query_p95_ms=\(durations[Int(Double(durations.count) * 0.95)])")
