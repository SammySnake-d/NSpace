import Foundation

/// 本地化辅助：全部 UI 串经此处；zh-Hans 为 base（脚本把 lproj 拷入 .app，走 Bundle.main）
enum L10n {
    static func t(_ key: String, _ comment: String = "") -> String {
        NSLocalizedString(key, comment: comment)
    }

    /// 带插值的本地化（%@/%d 格式串必须走这里——直接把值传给 t() 会被当成 comment 吞掉）
    static func f(_ key: String, _ args: any CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: args)
    }
}
