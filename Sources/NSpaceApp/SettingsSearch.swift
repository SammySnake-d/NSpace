import AppKit

/// 设置项搜索索引：**遍历真实已装配的视图树**建索引，不要求每页额外注册。
///
/// 为什么走视图树而不是手写一张 (标题键, 页签) 表：手写表会和页面漂——
/// 加了一项忘了登记，搜索就搜不到，而且没有任何东西会报红。
/// 从渲染出来的控件反查，索引永远等于界面本身。
@MainActor
enum SettingsSearch {

    /// 一条可搜索、可跳转的设置项
    struct Hit {
        /// 显示文本（控件自己的标题/标签）
        let text: String
        /// 所属页签下标（跳转用）
        let tabIndex: Int
        /// 所属页签标题（结果里显示"在哪一页"）
        let tabLabel: String
        /// 真实控件（跳转后滚到它、闪它）
        let view: NSView
    }

    /// 从已装配的 NSTabView 建全量索引
    static func index(_ tabs: NSTabView) -> [Hit] {
        var out: [Hit] = []
        for (i, item) in tabs.tabViewItems.enumerated() {
            guard let root = item.view else { continue }
            for (text, v) in labelled(in: root) {
                out.append(Hit(text: text, tabIndex: i, tabLabel: item.label, view: v))
            }
        }
        return out
    }

    /// 递归收集"带可见文字的控件"。刻意只收这几类——
    /// 收全部 NSView 会把分隔线、容器、空 label 都算进来，结果列表全是噪声。
    private static func labelled(in root: NSView) -> [(String, NSView)] {
        var out: [(String, NSView)] = []
        func walk(_ v: NSView) {
            switch v {
            case let b as NSButton:
                // 勾选框/单选/普通按钮的标题
                let t = b.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append((t, b)) }
            case let f as NSTextField:
                // 只收静态标签（可编辑的是输入框，它的值不是"设置项名字"）
                if !f.isEditable {
                    let t = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { out.append((t, f)) }
                }
            case let p as NSPopUpButton:
                // 下拉本身没标题时用它的选项集当补充可搜文本（"列表/图标/分栏"这类）
                let opts = p.itemTitles.joined(separator: " ")
                if !opts.isEmpty { out.append((opts, p)) }
            default:
                break
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        return out
    }

    /// 匹配：大小写/变音不敏感的子串。命中优先级——前缀命中排在中段命中之前。
    static func matches(_ query: String, in hits: [Hit], limit: Int = 12) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var prefix: [Hit] = []
        var contains: [Hit] = []
        for h in hits {
            let combined = h.text + " " + h.tabLabel
            guard combined.localizedCaseInsensitiveContains(q) else { continue }
            if h.text.lowercased().hasPrefix(q.lowercased()) { prefix.append(h) } else { contains.append(h) }
        }
        return Array((prefix + contains).prefix(limit))
    }

    /// 跳转到某一项：切页 → 滚到可见 → 闪一下高亮。
    /// 闪高亮是必要的：切到一页十几项的页面后，光是"到了这一页"根本找不到是哪一项。
    static func reveal(_ hit: Hit, in tabs: NSTabView) {
        tabs.selectTabViewItem(at: hit.tabIndex)
        hit.view.scrollToVisible(hit.view.bounds.insetBy(dx: -8, dy: -8))
        flash(hit.view)
    }

    /// 在控件外圈闪一层强调色描边（1.2s 后自行消失，不留残留层）
    static func flash(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let ring = CALayer()
        ring.frame = view.bounds.insetBy(dx: -3, dy: -3)
        ring.cornerRadius = 4
        ring.borderWidth = 2
        ring.borderColor = Theme.accent.cgColor
        ring.opacity = 0
        layer.addSublayer(ring)
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0, 1, 1, 0]
        anim.keyTimes = [0, 0.15, 0.75, 1]
        anim.duration = 1.2
        ring.add(anim, forKey: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { ring.removeFromSuperlayer() }
    }
}
