import Foundation

/// 本地化辅助：全部 UI 串经此处；zh-Hans 为 base（脚本把 lproj 拷入 .app，走 Bundle.main）
enum L10n {
    static func t(_ key: String, _ comment: String = "") -> String {
        NSLocalizedString(key, comment: comment)
    }
}
