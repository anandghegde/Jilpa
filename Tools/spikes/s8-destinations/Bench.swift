import Foundation

/// What one identity read costs, key by key, so the product knows what a folder comparison costs.
enum Bench {
  static func run(path: String, rounds: Int) {
    let sets: [(String, Set<URLResourceKey>)] = [
      ("fileIdentifier", [.fileIdentifierKey]),
      ("fileResourceIdentifier", [.fileResourceIdentifierKey]),
      ("volumeUUIDString", [.volumeUUIDStringKey]),
      ("volumeIdentifier", [.volumeIdentifierKey]),
      ("volumeLocalizedFormatDescription", [.volumeLocalizedFormatDescriptionKey]),
      ("fileIdentifier + volumeUUIDString", [.fileIdentifierKey, .volumeUUIDStringKey]),
      ("fileResourceIdentifier + volumeIdentifier", [.fileResourceIdentifierKey, .volumeIdentifierKey]),
    ]
    print("| Read | Rounds | p50 ms | p95 ms | max ms |")
    print("| --- | --- | --- | --- | --- |")
    for (name, keys) in sets {
      var samples: [Double] = []
      for _ in 0..<rounds {
        var url = URL(fileURLWithPath: path)
        url.removeAllCachedResourceValues()
        let started = DispatchTime.now()
        _ = try? url.resourceValues(forKeys: keys)
        samples.append(Identity.elapsed(started))
      }
      row(name, samples)
    }
    var samples: [Double] = []
    for _ in 0..<rounds {
      var info = stat()
      var fs = statfs()
      let started = DispatchTime.now()
      _ = stat(path, &info)
      _ = statfs(path, &fs)
      samples.append(Identity.elapsed(started))
    }
    row("stat + statfs (device, inode, fsid)", samples)
  }

  private static func row(_ name: String, _ samples: [Double]) {
    let sorted = samples.sorted()
    func rank(_ quantile: Double) -> Double {
      sorted[min(max(Int((quantile * Double(sorted.count)).rounded(.up)) - 1, 0), sorted.count - 1)]
    }
    print(
      "| \(name) | \(sorted.count) | \(String(format: "%.3f", rank(0.5))) | \(String(format: "%.3f", rank(0.95))) | \(String(format: "%.3f", sorted.last ?? 0)) |"
    )
  }
}
