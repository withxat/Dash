import Foundation

// Hugeicons "02" file-format glyphs (document-with-folded-corner family),
// generated into the asset catalog by generate-file-icons.mjs. Shown as the
// leading icon for non-image R2 objects; image objects render a thumbnail
// instead and fall back to `HugeFileImage` while it loads.

enum HugeAsset {
  static let file = "HugeFile02"
  static let pdf = "HugePdf02"
  static let doc = "HugeDoc02"
  static let txt = "HugeTxt02"
  static let csv = "HugeCsv02"
  static let xls = "HugeXls02"
  static let ppt = "HugePpt02"
  static let zip = "HugeZip02"
  static let rar = "HugeRar02"
  static let svg = "HugeSvg02"
  static let png = "HugePng02"
  static let jpg = "HugeJpg02"
  static let gif = "HugeGif02"
  static let image = "HugeFileImage"
  static let video = "HugeFilePlay"
  static let audio = "HugeWav02"
  static let xml = "HugeXml02"
  static let html = "HugeHtml02"
  static let css = "HugeCss02"
  static let code = "HugeJsx03"
}

/// Resolves an object key to its file-format glyph by extension. The generic
/// `HugeFile02` document covers anything without a dedicated Hugeicons glyph,
/// keeping every non-image row in the same "02" visual family.
enum FileTypeIcon {
  static func asset(forKey key: String) -> String {
    switch fileExtension(of: key) {
    case "pdf": HugeAsset.pdf
    case "doc", "docx", "rtf", "odt", "pages": HugeAsset.doc
    case "txt", "text", "log", "md", "markdown", "readme": HugeAsset.txt
    case "csv", "tsv": HugeAsset.csv
    case "xls", "xlsx", "numbers", "ods": HugeAsset.xls
    // `.key` is left to the neutral fallback: in an R2 bucket it is far more
    // often a TLS/PEM private key than a Keynote deck.
    case "ppt", "pptx", "odp": HugeAsset.ppt
    case "zip", "tar", "gz", "tgz", "7z", "bz2", "xz": HugeAsset.zip
    case "rar": HugeAsset.rar
    case "svg": HugeAsset.svg
    case "png": HugeAsset.png
    case "jpg", "jpeg": HugeAsset.jpg
    case "gif": HugeAsset.gif
    case "webp", "heic", "heif", "avif", "bmp", "tif", "tiff", "ico":
      HugeAsset.image
    case "mp4", "mov", "avi", "mkv", "webm", "m4v", "mpg", "mpeg", "wmv", "flv":
      HugeAsset.video
    case "mp3", "wav", "aac", "flac", "m4a", "ogg", "opus", "aiff", "wma":
      HugeAsset.audio
    case "xml", "plist", "yml", "yaml", "toml": HugeAsset.xml
    case "html", "htm", "xhtml": HugeAsset.html
    case "css", "scss", "sass", "less": HugeAsset.css
    case "js", "jsx", "ts", "tsx", "mjs", "cjs", "json", "swift", "py", "rb",
      "go", "rs", "java", "kt", "c", "cpp", "h", "sh", "sql":
      HugeAsset.code
    default: HugeAsset.file
    }
  }

  /// Lowercased extension of the last path segment, or "" when the filename has
  /// no dot (dotfiles like `.gitignore` count as extensionless).
  private static func fileExtension(of key: String) -> String {
    guard let name = key.split(separator: "/").last else { return "" }
    let parts = name.split(separator: ".")
    guard parts.count > 1, let ext = parts.last else { return "" }
    return ext.lowercased()
  }
}
