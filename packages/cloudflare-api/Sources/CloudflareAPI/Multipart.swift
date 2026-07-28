import Foundation

/// Minimal multipart/form-data encoder for Worker script content.
public struct MultipartForm: Sendable {
  public struct Part: Sendable {
    public let name: String
    public let filename: String?
    public let contentType: String?
    public let body: Data

    public init(name: String, filename: String? = nil, contentType: String? = nil, body: Data) {
      self.name = name
      self.filename = filename
      self.contentType = contentType
      self.body = body
    }
  }

  public let boundary: String
  public private(set) var parts: [Part] = []

  public init(boundary: String = "dash-\(UUID().uuidString)") {
    self.boundary = boundary
  }

  public mutating func addField(name: String, value: String) {
    parts.append(Part(name: name, body: Data(value.utf8)))
  }

  public mutating func addFile(name: String, filename: String, contentType: String, data: Data) {
    parts.append(Part(name: name, filename: filename, contentType: contentType, body: data))
  }

  public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

  public func encode() -> Data {
    var data = Data()
    for part in parts {
      data.append(Data("--\(boundary)\r\n".utf8))
      var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
      if let filename = part.filename {
        disposition += "; filename=\"\(filename)\""
      }
      data.append(Data("\(disposition)\r\n".utf8))
      if let contentType = part.contentType {
        data.append(Data("Content-Type: \(contentType)\r\n".utf8))
      }
      data.append(Data("\r\n".utf8))
      data.append(part.body)
      data.append(Data("\r\n".utf8))
    }
    data.append(Data("--\(boundary)--\r\n".utf8))
    return data
  }
}

/// Minimal multipart parser for module-Worker downloads, whose responses put
/// the boundary in the Content-Type header. Bodies are Worker-script sized,
/// so parsing in memory is fine.
public enum MultipartDocument {
  public struct Part: Sendable {
    public let name: String?
    public let filename: String?
    public let contentType: String?
    public let body: Data
  }

  /// Extracts `boundary=` from a Content-Type header value, unquoting if needed.
  public static func boundary(fromContentType contentType: String) -> String? {
    for parameter in contentType.split(separator: ";").dropFirst() {
      let trimmed = parameter.trimmingCharacters(in: .whitespaces)
      guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
      var value = String(trimmed.dropFirst("boundary=".count))
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value = String(value.dropFirst().dropLast())
      }
      return value.isEmpty ? nil : value
    }
    return nil
  }

  public static func parse(data: Data, contentType: String) -> [Part] {
    guard let boundary = boundary(fromContentType: contentType) else { return [] }
    let delimiter = Data("--\(boundary)".utf8)
    let crlf = Data("\r\n".utf8)
    var parts: [Part] = []
    var cursor = data.startIndex

    while let markerRange = data.range(of: delimiter, in: cursor..<data.endIndex) {
      // A delimiter followed by "--" is the closing marker.
      let afterMarker = markerRange.upperBound
      if data[afterMarker...].starts(with: Data("--".utf8)) { break }
      guard let headerStart = data.range(of: crlf, in: afterMarker..<data.endIndex)?.upperBound
      else { break }
      guard
        let headerEnd = data.range(of: Data("\r\n\r\n".utf8), in: headerStart..<data.endIndex)
      else { break }
      let headerData = data[headerStart..<headerEnd.lowerBound]
      let bodyStart = headerEnd.upperBound
      guard
        let nextMarker = data.range(
          of: Data("\r\n--\(boundary)".utf8), in: bodyStart..<data.endIndex)
      else { break }
      let body = data[bodyStart..<nextMarker.lowerBound]

      var name: String?
      var filename: String?
      var partType: String?
      for line in String(decoding: headerData, as: UTF8.self).split(separator: "\r\n") {
        let lowered = line.lowercased()
        if lowered.hasPrefix("content-disposition:") {
          name = headerParameter(String(line), key: "name")
          filename = headerParameter(String(line), key: "filename")
        } else if lowered.hasPrefix("content-type:") {
          partType = line.dropFirst("content-type:".count)
            .trimmingCharacters(in: .whitespaces)
        }
      }
      parts.append(Part(name: name, filename: filename, contentType: partType, body: Data(body)))
      cursor = nextMarker.lowerBound + crlf.count
    }
    return parts
  }

  private static func headerParameter(_ header: String, key: String) -> String? {
    for parameter in header.split(separator: ";").dropFirst() {
      let trimmed = parameter.trimmingCharacters(in: .whitespaces)
      guard trimmed.lowercased().hasPrefix("\(key)=") else { continue }
      var value = String(trimmed.dropFirst(key.count + 1))
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value = String(value.dropFirst().dropLast())
      }
      return value
    }
    return nil
  }
}

/// A Worker script's editable source: the main module (or classic script)
/// content plus what re-uploading it needs to know.
public struct WorkerSource: Sendable, Codable, Hashable {
  /// Content of the main module (module workers) or the whole script (classic).
  public let content: String
  /// Main module filename for module workers; nil for classic scripts.
  public let mainModule: String?
  /// Total module parts in the download; editing is only safe when <= 1.
  public let moduleCount: Int

  public init(content: String, mainModule: String?, moduleCount: Int) {
    self.content = content
    self.mainModule = mainModule
    self.moduleCount = moduleCount
  }
}
