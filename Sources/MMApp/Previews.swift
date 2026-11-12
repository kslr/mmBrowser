#if DEBUG
import Foundation
import MMCore

extension AppModel {
    /// SwiftUI 预览用：数据放在临时目录并填入和截图自检一样的演示数据，不碰正式数据目录。
    static let preview: AppModel = {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmBrowser-preview-\(UUID().uuidString)", isDirectory: true)
        let model = AppModel(paths: AppPaths(root: root))
        SnapshotRunner.seedDemoData(model)
        return model
    }()
}
#endif
