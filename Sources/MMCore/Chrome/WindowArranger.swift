import AppKit
import ApplicationServices

/// 用辅助功能接口（AXUIElement）排列各环境的 Chrome 窗口。需要用户在"系统设置 → 隐私与安全性 → 辅助功能"里授权。
@MainActor
public enum WindowArranger {
    /// 是否已授权；prompt 为 true 时，未授权会弹出系统的授权提示。
    public static func isTrusted(prompt: Bool) -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public enum Layout: String, CaseIterable, Sendable {
        /// 网格平铺
        case grid
        /// 层叠
        case cascade
    }

    /// 计算网格中每个窗口的位置（纯函数，便于测试）。frame 使用屏幕坐标（左上角为原点，与 AX 一致）。
    public static func gridFrames(count: Int, in area: CGRect, gap: CGFloat = 6) -> [CGRect] {
        guard count > 0 else { return [] }
        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        let w = (area.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
        let h = (area.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
        return (0..<count).map { i in
            let r = i / cols, c = i % cols
            return CGRect(x: area.minX + gap + CGFloat(c) * (w + gap), y: area.minY + gap + CGFloat(r) * (h + gap),
                          width: w, height: h).integral
        }
    }

    public static func cascadeFrames(count: Int, in area: CGRect, step: CGFloat = 32) -> [CGRect] {
        guard count > 0 else { return [] }
        let w = min(1440, area.width * 0.75), h = min(900, area.height * 0.8)
        return (0..<count).map { i in
            let off = CGFloat(i % 12) * step
            return CGRect(x: area.minX + 20 + off, y: area.minY + 20 + off, width: w, height: h).integral
        }
    }

    /// 排列这些进程的主窗口（每个进程取第一个普通窗口）。返回实际排列的窗口数。
    @discardableResult
    public static func arrange(pids: [Int32], layout: Layout, screen: NSScreen? = NSScreen.main) -> Int {
        guard let screen, isTrusted(prompt: true) else { return 0 }
        // NSScreen.visibleFrame 是左下角原点；AX 用的是主屏左上角原点
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let v = screen.visibleFrame
        let area = CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)

        let windows: [AXUIElement] = pids.compactMap { mainWindow(of: $0) }
        let frames = layout == .grid ? gridFrames(count: windows.count, in: area) : cascadeFrames(count: windows.count, in: area)
        for (win, f) in zip(windows, frames) {
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            var origin = f.origin, size = f.size
            if let pos = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pos) }
            if let sz = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sz) }
        }
        for pid in pids { NSRunningApplication(processIdentifier: pid)?.activate(options: []) }
        return windows.count
    }

    private static func mainWindow(of pid: Int32) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return nil }
        return list.first { w in
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &role)
            return (role as? String) == (kAXStandardWindowSubrole as String)
        } ?? list.first
    }
}
