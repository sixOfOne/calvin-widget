import Foundation

struct ImageDownload {
    var jpeg: Data?
    var status: Int
    var rawBytes: Int
    var note: String
}

enum StripLoader {
    /// Safari on macOS. WKWebView uses this so GoComics serves the normal page.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"

    static func downloadImage(from url: URL, referer: URL) async -> ImageDownload {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/png,image/jpeg,image/gif,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status), !data.isEmpty else {
                return ImageDownload(jpeg: nil, status: status, rawBytes: data.count, note: "HTTP \(status), \(data.count) bytes")
            }
            guard let jpeg = StripImage.jpegData(from: data) else {
                return ImageDownload(
                    jpeg: nil,
                    status: status,
                    rawBytes: data.count,
                    note: "HTTP \(status), \(data.count) bytes, JPEG conversion failed"
                )
            }
            return ImageDownload(
                jpeg: jpeg,
                status: status,
                rawBytes: data.count,
                note: "HTTP \(status), \(data.count) bytes, jpeg \(jpeg.count)"
            )
        } catch {
            return ImageDownload(jpeg: nil, status: -1, rawBytes: 0, note: error.localizedDescription)
        }
    }
}
