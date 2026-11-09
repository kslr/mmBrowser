import Foundation

/// 在 Chrome 启动前写入/更新它的配置文件（Chrome 未运行时才能写，否则会被它覆盖）。
///
/// 只写不受完整性校验的项（名称、主题色、定位权限、语言、WebRTC 等），每次启动前都会更新。
/// 受校验的项（如启动时恢复会话）由 `ProfileInitializer` 通过 Chrome 自己的设置接口写入。
public enum ProfileSeed {
    public static func apply(profile: Profile, language: String, userDataDir: URL) throws {
        let fm = FileManager.default
        let defaultDir = userDataDir.appendingPathComponent("Default", isDirectory: true)
        let prefsURL = defaultDir.appendingPathComponent("Preferences")
        let localStateURL = userDataDir.appendingPathComponent("Local State")
        let firstRun = !fm.fileExists(atPath: prefsURL.path)
        try fm.createDirectory(at: defaultDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // Preferences
        var prefs = try readJSON(prefsURL)
        let color = skColor(hex: profile.effectiveThemeColor)
        set(&prefs, "profile.name", profile.name)
        set(&prefs, "profile.default_content_setting_values.geolocation",
            profile.geolocation == .block ? 2 : 3)  // 2 = 禁止，3 = 询问
        set(&prefs, "browser.theme.user_color", color)
        set(&prefs, "browser.theme.user_color2", color)
        set(&prefs, "browser.theme.color_variant", 1)   // tonal spot，与"自定义 Chrome"里选颜色的效果一致
        set(&prefs, "browser.theme.color_variant2", 1)
        set(&prefs, "intl.accept_languages", CountryLocale.acceptLanguage(for: language))
        set(&prefs, "intl.selected_languages", CountryLocale.acceptLanguage(for: language))
        set(&prefs, "webrtc.ip_handling_policy", "disable_non_proxied_udp")
        set(&prefs, "webrtc.multiple_routes_enabled", false)
        set(&prefs, "webrtc.nonproxied_udp_enabled", false)
        set(&prefs, "media_router.enable_media_router", false)  // 关掉投屏发现，避免在局域网里发 mDNS
        if firstRun {
            set(&prefs, "browser.has_seen_welcome_page", true)
            set(&prefs, "browser.check_default_browser", false)
            set(&prefs, "credentials_enable_service", true)          // 保存密码
            set(&prefs, "profile.password_manager_enabled", true)
        }
        try writeJSON(prefs, to: prefsURL)

        // Local State（profile 选择器、头像菜单里显示的名称）
        var state = try readJSON(localStateURL)
        set(&state, "profile.info_cache.Default.name", profile.name)
        set(&state, "profile.info_cache.Default.is_using_default_name", false)
        set(&state, "profile.info_cache.Default.profile_highlight_color", color)
        set(&state, "profile.info_cache.Default.default_avatar_fill_color", color)
        set(&state, "profile.last_used", "Default")
        if firstRun {
            set(&state, "browser.has_seen_welcome_page", true)
        }
        try writeJSON(state, to: localStateURL)
    }

    /// `#RRGGBB` → Chrome 存的 SkColor（0xFFRRGGBB，按 int32 存储，所以是负数）。
    static func skColor(hex: String) -> Int {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let rgb = UInt32(s, radix: 16) ?? 0x5F6368
        return Int(Int32(bitPattern: 0xFF00_0000 | (rgb & 0xFF_FFFF)))
    }

    // MARK: - JSON 工具

    static func readJSON(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func writeJSON(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 按点号路径写入嵌套字典。注意 key 本身不能含点（我们用到的都不含）。
    static func set(_ dict: inout [String: Any], _ path: String, _ value: Any) {
        let keys = path.split(separator: ".").map(String.init)
        setNested(&dict, keys[...], value)
    }

    private static func setNested(_ dict: inout [String: Any], _ keys: ArraySlice<String>, _ value: Any) {
        guard let first = keys.first else { return }
        if keys.count == 1 {
            dict[first] = value
            return
        }
        var child = dict[first] as? [String: Any] ?? [:]
        setNested(&child, keys.dropFirst(), value)
        dict[first] = child
    }
}
