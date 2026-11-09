import Foundation

/// 环境目录（Chrome user-data-dir）的文件操作。
public enum ProfileFiles {
    /// 复制/备份时跳过的内容：缓存、运行时锁文件、崩溃报告、可以重新下载的组件。
    static let skippedNames: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "GrShaderCache", "ShaderCache", "GraphiteDawnCache", "DawnGraphiteCache",
        "DawnWebGPUCache", "CacheStorage", "ScriptCache", "Crashpad", "component_crx_cache", "extensions_crx_cache",
        "optimization_guide_model_store", "OptimizationHints", "Safe Browsing", "SafetyTips", "BrowserMetrics",
        "SingletonLock", "SingletonSocket", "SingletonCookie", "DevToolsActivePort", "RunningChromeVersion",
    ]

    static func shouldSkip(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return skippedNames.contains(name) || name.hasPrefix("BrowserMetrics")
    }

    /// 递归复制，跳过缓存等。目标目录不能已存在。
    public static func copyData(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dst.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: dst.path])
        }
        try fm.createDirectory(at: dst, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try copyContents(of: src, into: dst)
    }

    private static func copyContents(of src: URL, into dst: URL) throws {
        let fm = FileManager.default
        for item in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            if shouldSkip(item) { continue }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            let target = dst.appendingPathComponent(item.lastPathComponent)
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try copyContents(of: item, into: target)
            } else {
                try fm.copyItem(at: item, to: target)
            }
        }
    }
}
