// OpenSky — SelfUpdate.swift
// `opensky version` prints the build version; `opensky update` self-updates.
//
// Update strategy (idempotent, no sudo):
//   1. Determine install dir: the binary's own directory if writable
//      (default ~/.local/bin), else fall back to /usr/local/bin when writable.
//   2. Download the latest GitHub release artifact (opensky-<arch>-macos.tar.xz)
//      via the public API, or build from source when no artifact matches.
//   3. Atomic swap: download to temp → verify → move over old binary → done.

import Foundation

enum SelfUpdate {
    static let currentVersion = "1.0.0"
    static let repo = "pkyanam/OpenSky"
    static let releaseAPI = "https://api.github.com/repos/\(repo)/releases/latest"
    static let archiveName = "opensky-\(archTag)-macos.tar.xz"

    static var archTag: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func run(_ rest: [String]) async {
        switch rest.first ?? "" {
        case "", "--check":
            await check()
        case "--install", "install":
            await install()
        default:
            FileHandle.standardError.write("usage: opensky update [--check]\n".data(using: .utf8)!)
            exit(2)
        }
    }

    static func printVersion() {
        print("opensky \(currentVersion) (\(archTag))")
    }

    // MARK: - check

    static func check() async {
        print("installed: \(currentVersion)")
        guard let latest = await latestVersion() else {
            print("could not reach GitHub releases (offline?); staying on \(currentVersion)")
            return
        }
        if normalize(latest) == normalize(currentVersion) {
            print("latest:    \(latest) — up to date")
        } else {
            print("latest:    \(latest) — run `opensky update --install` to update")
        }
    }

    static func normalize(_ v: String) -> String {
        v.hasPrefix("v") ? String(v.dropFirst()) : v
    }

    struct Release: Decodable {
        let tagName: String
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browserDownloadUrl: String }
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", assets
        }
    }

    static func latestVersion() async -> String? {
        guard let url = URL(string: releaseAPI) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let rel = try? JSONDecoder().decode(Release.self, from: data) else {
            if status == 404 { print("no published release yet; reporting local version") }
            return nil
        }
        return rel.tagName
    }

    static func latestRelease() async -> Release? {
        guard let url = URL(string: releaseAPI) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let rel = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
        return rel
    }

    // MARK: - install

    static func install() async {
        let fm = FileManager.default
        let me = CommandLine.arguments.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
        let installDir = me?.deletingLastPathComponent().path ?? installFallback()
        print("updating opensky in \(installDir)…")

        print("fetching latest release…")
        guard let rel = await latestRelease() else {
            print("✗ could not reach GitHub releases")
            exit(1)
        }
        if normalize(rel.tagName) == normalize(currentVersion), me != nil {
            print("already up to date (\(currentVersion))")
            return
        }

        let asset = rel.assets.first { $0.name == archiveName }
        let tmp = fm.temporaryDirectory.appendingPathComponent("opensky-update-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        if let asset {
            print("downloading \(asset.name)…")
            guard let (data, resp) = try? await URLSession.shared.data(from: URL(string: asset.browserDownloadUrl)!),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else {
                print("✗ download failed; update aborted"); exit(1)
            }
            let archive = tmp.appendingPathComponent(archiveName)
            try? data.write(to: archive)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            proc.arguments = ["-xf", archive.path, "-C", tmp.path]
            try? proc.run(); proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let entries = try? fm.contentsOfDirectory(atPath: tmp.path),
                  let binName = entries.first(where: { $0 == "opensky" }) else {
                print("✗ archive extraction failed"); exit(1)
            }
            swap(newBinary: tmp.appendingPathComponent(binName), into: installDir)
        } else {
            print("no prebuilt binary for \(archTag) in release \(rel.tagName); building from source…")
            let repoDir = tmp.appendingPathComponent("OpenSky-src")
            let clone = Process()
            clone.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            clone.arguments = ["git", "clone", "--depth", "1",
                               "https://github.com/\(repo).git", repoDir.path]
            try? clone.run(); clone.waitUntilExit()
            guard clone.terminationStatus == 0 else { print("✗ clone failed (git required)"); exit(1) }
            let build = Process()
            build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            build.arguments = ["swift", "build", "-c", "release"]
            build.currentDirectoryURL = repoDir
            try? build.run(); build.waitUntilExit()
            guard build.terminationStatus == 0 else { print("✗ build failed (Xcode required)"); exit(1) }
            swap(newBinary: repoDir.appendingPathComponent(".build/release/opensky"), into: installDir)
        }
        try? fm.removeItem(at: tmp)
        print("✓ opensky updated → \(rel.tagName)")
    }

    static func swap(newBinary: URL, into installDir: String) {
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: installDir).appendingPathComponent("opensky")
        try? fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)
        // atomic-ish: move old aside, move new in, remove old
        let backup = URL(fileURLWithPath: installDir).appendingPathComponent(".opensky.old")
        try? fm.removeItem(at: backup)
        if fm.fileExists(atPath: dest.path) {
            try? fm.moveItem(at: dest, to: backup)
        }
        do {
            try fm.moveItem(at: newBinary, to: dest)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            try? fm.removeItem(at: backup)
        } catch {
            // restore old binary on any failure
            if fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: backup, to: dest)
            }
            print("✗ update failed: \(error.localizedDescription) (old binary restored)")
            exit(1)
        }
    }

    static func installFallback() -> String {
        let fm = FileManager.default
        let localBin = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        if isWritable(localBin) { return localBin }
        return "/usr/local/bin"
    }

    static func isWritable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent)
        }
        return FileManager.default.isWritableFile(atPath: path)
    }
}
