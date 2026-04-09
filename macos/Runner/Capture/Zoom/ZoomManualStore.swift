import Foundation

struct ZoomManualData: Codable {
  let version: Int
  let segments: [ZoomManualSegment]

  init(version: Int = 2, segments: [ZoomManualSegment]) {
    self.version = version
    self.segments = segments
  }

  enum CodingKeys: String, CodingKey {
    case version
    case segments
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = (try? container.decode(Int.self, forKey: .version)) ?? 1
    let segments = (try? container.decode([ZoomManualSegment].self, forKey: .segments)) ?? []
    self.version = version
    self.segments = segments
  }
}

struct ZoomManualSegment: Codable {
  let id: String
  let startMs: Int
  let endMs: Int
  let source: String?
  let baseId: String?
}

class ZoomManualStore {
  static let shared = ZoomManualStore()

  private init() {}

  func save(projectPath: String, segments: [[String: Any]]) -> Bool {
    let url = RecordingProjectPaths.zoomManualURL(
      for: URL(fileURLWithPath: projectPath)
    )

    var manualSegments: [ZoomManualSegment] = []
    for dict in segments {
      if let id = dict["id"] as? String,
        let startMs = dict["startMs"] as? Int,
        let endMs = dict["endMs"] as? Int
      {
        manualSegments.append(
          ZoomManualSegment(
            id: id,
            startMs: startMs,
            endMs: endMs,
            source: dict["source"] as? String,
            baseId: dict["baseId"] as? String
          ))
      }
    }

    let data = ZoomManualData(version: 2, segments: manualSegments)

    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .prettyPrinted
      let jsonData = try encoder.encode(data)
      try jsonData.write(to: url)
      NativeLogger.i("ZoomManualStore", "Saved manual segments to \(url.path)")
      return true
    } catch {
      NativeLogger.e(
        "ZoomManualStore", "Failed to save manual segments: \(error.localizedDescription)")
      return false
    }
  }

  func load(projectPath: String) -> [[String: Any]] {
    let url = RecordingProjectPaths.zoomManualURL(
      for: URL(fileURLWithPath: projectPath)
    )

    guard FileManager.default.fileExists(atPath: url.path) else {
      return []
    }

    do {
      let data = try Data(contentsOf: url)
      let decoder = JSONDecoder()
      let decoded = try decoder.decode(ZoomManualData.self, from: data)

      return decoded.segments.map { segment in
        var dict: [String: Any] = [
          "id": segment.id,
          "startMs": segment.startMs,
          "endMs": segment.endMs,
          "source": segment.source ?? "manual",
        ]
        if let baseId = segment.baseId {
          dict["baseId"] = baseId
        }
        return dict
      }
    } catch {
      NativeLogger.e(
        "ZoomManualStore", "Failed to load manual segments: \(error.localizedDescription)")
      return []
    }
  }
}
