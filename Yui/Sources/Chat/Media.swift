import Foundation
import SwiftUI
import UIKit

// Media (YUI-21). Pictures and videos live in the private `yui-media` bucket
// (migration 20260924040000_yui_media.sql) at <user>/<agent>/<from>/<file>.
// Agents send signed URLs; the person's photos go up under from=user and
// travel to the agent as that path, which its host downloads.

extension EnvironmentValues {
    /// Upload and link signing for the open thread. nil on the demo account.
    @Entry var yuiMedia: YuiMedia? = nil
}

@MainActor
struct YuiMedia {
    let account: Account
    let agentID: String

    nonisolated static let bucket = "yui-media"
    static let storage = YuiBackend.url.appending(path: "storage/v1")
    /// The longest side of a photo we send. Plenty for vision, light on a phone connection.
    nonisolated static let maxSide: CGFloat = 2048

    /// JPEG-encodes a photo and uploads it. Returns the bucket path the agent gets.
    func upload(photo data: Data) async throws -> String {
        guard let jpeg = Self.jpeg(data) else { throw AccountError.server("not_a_photo") }
        guard let user = account.session?.userID else { throw AccountError.signedOut }
        let path = "\(user.lowercased())/\(agentID.lowercased())/user/\(UUID().uuidString.lowercased()).jpg"
        var req = URLRequest(url: Self.storage.appending(path: "object/\(Self.bucket)/\(path)"))
        req.httpMethod = "POST"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.httpBody = jpeg
        _ = try await send(req)
        return path
    }

    /// A signed link past its expiry is signed again with this person's own token.
    func fresh(_ url: URL) async -> URL {
        guard let path = Self.bucketPath(url), Self.expiry(url).map({ $0.timeIntervalSinceNow < 300 }) ?? true else { return url }
        return await link(path: path) ?? url
    }

    /// A signed link to one of this person's bucket paths (their own sent photos on reopen).
    func link(path: String) async -> URL? {
        if let hit = await SignedCache.shared.get(path) { return hit }
        var req = URLRequest(url: Self.storage.appending(path: "object/sign/\(Self.bucket)/\(path)"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"expiresIn":604800}"#.utf8)
        guard let data = try? await send(req),
              let signed = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["signedURL"] as? String,
              let out = URL(string: Self.storage.absoluteString + signed) else { return nil }
        await SignedCache.shared.put(path, out)
        return out
    }

    private func send(_ r: URLRequest) async throws -> Data {
        var req = r
        req.setValue(YuiBackend.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(try await account.validAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AccountError.server("http_\((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    /// `<user>/<agent>/<from>/<file>` when the URL is one of our signed links.
    nonisolated static func bucketPath(_ url: URL) -> String? {
        let marker = "/storage/v1/object/sign/\(bucket)/"
        guard url.host() == YuiBackend.url.host(), let r = url.path().range(of: marker) else { return nil }
        return String(url.path()[r.upperBound...])
    }

    /// The `exp` inside a signed link's token.
    nonisolated static func expiry(_ url: URL) -> Date? {
        guard let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "token" })?.value else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let exp = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    nonisolated static func jpeg(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let side = max(image.size.width, image.size.height)
        guard side > maxSide else { return image.jpegData(compressionQuality: 0.85) }
        let scale = maxSide / side
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.85)
    }
}

private actor SignedCache {
    static let shared = SignedCache()
    private var links: [String: URL] = [:]
    func get(_ path: String) -> URL? {
        guard let url = links[path], let exp = YuiMedia.expiry(url), exp.timeIntervalSinceNow > 300 else { return nil }
        return url
    }
    func put(_ path: String, _ url: URL) {
        // Expired links go as new ones come (YUI-100): the map never outgrows what is live.
        links = links.filter { (YuiMedia.expiry($0.value)?.timeIntervalSinceNow ?? 0) > 0 }
        links[path] = url
    }
}

/// A YL media token as a URL. Relative paths (`/demo/room.jpg`) are the site's.
enum YLMediaURL {
    static let site = URL(string: "https://www.yuigui.com")!

    static func url(_ token: String?) -> URL? {
        guard let t = token?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return URL(string: t) }
        if t.hasPrefix("/") { return URL(string: t, relativeTo: site)?.absoluteURL }
        return nil
    }

    static func isVideo(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v", "webm"].contains(url.pathExtension.lowercased())
    }
}
