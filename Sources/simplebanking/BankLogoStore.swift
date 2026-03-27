import AppKit
import CryptoKit
import Foundation

@MainActor
final class BankLogoStore: ObservableObject {
    static let shared = BankLogoStore()

    @Published private(set) var images: [String: NSImage] = [:]

    private var requestedBrandIDs: Set<String> = []
    private let fileManager = FileManager.default
    private let cacheDirectory: URL

    private init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let appDirectory = base.appendingPathComponent("com.maik.simplebanking", isDirectory: true)
        cacheDirectory = appDirectory.appendingPathComponent("logo-cache/banks", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func preload(brand: BankLogoAssets.BankBrand?) {
        guard let brand else { return }
        loadIfNeeded(brand: brand)
    }

    func image(for brand: BankLogoAssets.BankBrand?) -> NSImage? {
        guard let brand else { return nil }
        return images[brand.id]
    }

    private func loadIfNeeded(brand: BankLogoAssets.BankBrand) {
        guard images[brand.id] == nil else { return }
        guard !requestedBrandIDs.contains(brand.id) else { return }

        let scheme = brand.logoURL.scheme?.lowercased() ?? ""

        // Bundled SVG — load synchronously, no caching needed
        if scheme == "file" {
            if let image = NSImage(contentsOf: brand.logoURL) {
                images[brand.id] = image
            }
            return
        }

        guard scheme == "http" || scheme == "https" else { return }

        if let cached = loadImageFromDisk(for: brand.logoURL) {
            images[brand.id] = cached
            return
        }

        requestedBrandIDs.insert(brand.id)

        Task {
            defer { requestedBrandIDs.remove(brand.id) }
            do {
                var request = URLRequest(url: brand.logoURL)
                request.timeoutInterval = 20
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return
                }
                guard let image = NSImage(data: data) else { return }
                images[brand.id] = image
                saveImageToDisk(data: data, for: brand.logoURL)
            } catch {
                // Network/cache failures are non-fatal; UI uses a placeholder icon.
            }
        }
    }

    private func loadImageFromDisk(for remoteURL: URL) -> NSImage? {
        let cacheURL = cacheFileURL(for: remoteURL)
        guard fileManager.fileExists(atPath: cacheURL.path) else { return nil }
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return NSImage(data: data)
    }

    private func saveImageToDisk(data: Data, for remoteURL: URL) {
        let cacheURL = cacheFileURL(for: remoteURL)
        try? data.write(to: cacheURL, options: [.atomic])
    }

    private func cacheFileURL(for remoteURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(key).img")
    }
}
