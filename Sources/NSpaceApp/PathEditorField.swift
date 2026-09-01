import AppKit
import PathComplete

/// 路径编辑器：⌘L/点击空白呼出；输入即补全（PathComplete 胶囊）；Enter 导航、Esc 取消
@MainActor
final class PathEditorField: NSTextField, NSTextFieldDelegate {
    /// 落点是目录 → 进入该目录
    var onCommit: ((URL) -> Void)?
    /// 落点是文件、或 .app/.bundle 这类"盘上是目录、用户眼里是一个东西"的包 → 进父目录并选中（Finder 语义）
    var onRevealFile: ((URL) -> Void)?
    var onCancel: (() -> Void)?
    /// 失焦复位（删除清空、点击他处、切走 App 后）：面包屑回显当前目录，绝不残留空白
    var onReset: (() -> Void)?
    /// 无效路径的就地文字反馈（不弹窗——spec 做工不变量）
    var onInvalid: ((String) -> Void)?
    /// 相对路径的解析基准 = 当前浏览目录（进程 CWD 对文件管理器没有意义）
    var baseDirectory: (() -> URL)?

    private let completer: any PathCompleting = PathCompleter()
    private var completing = false
    /// controlTextDidChange 是否正在栈上（用于证明 complete 触发在文本变更事务之外）
    private var inTextDidChange = false
    /// 刚拒绝过一次提交（路径无效）：Enter 会让 AppKit 结束编辑会话，若照常走失焦复位，
    /// 地址栏会连同刚弹出的错误提示一起被关掉——用户输错一个字就被踢出输入框，还没看清报什么错。
    /// Finder ⌘⇧G 的做法是留在框里让你就地改，这里对齐。
    private var rejectedJustNow = false
    /// 上一次文本长度（UTF-16）：用来区分"用户敲了一个字符"与"粘贴涌入一大段"
    private var lastTextLength = 0
    /// I-54 探针：补全实际被触发的次数（验证粘贴不弹补全）
    private(set) var uiTestCompletionTriggerCount = 0
    /// 提交解析正在后台跑（连按 Enter 不叠加）
    private var resolving = false
    /// I-30 探针：末次补全候选数
    private(set) var uiTestLastCompletionCount = -1
    /// I-30 探针：末次补全是否在文本变更事务【之外】触发（true=已延迟；同步 bug 时为 false）
    private(set) var uiTestCompletionWasDeferred = false

    init() {
        super.init(frame: .zero)
        delegate = self
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        placeholderString = L10n.t("addressbar.placeholder")
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        registerForDraggedTypes([.fileURL])   // 拖文件/文件夹进来即填成路径
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func beginEditing(with path: String) {
        rejectedJustNow = false
        stringValue = path
        lastTextLength = (path as NSString).length   // 程序赋值不发 controlTextDidChange，基线得手动对齐
        window?.makeFirstResponder(self)
        // ⌘L 即「改地址」：全选当前路径，输入/粘贴直接替换（与 Finder ⌘⇧G / Safari 同款）
        currentEditor()?.selectAll(nil)
    }

    // MARK: 路径解析（把剪贴板里千奇百怪的形态收敛成一个落点）

    enum Resolution: Equatable {
        case directory(URL)     // 进入
        case file(URL)          // 进父目录并选中（含 .app/.bundle 等包）
        case unreadable(URL)    // 存在但没读权限
        case notFound           // 各候选解释都不存在
        case empty              // 空输入 = 取消
    }

    /// 用户粘进地址栏的路径串形态千奇百怪：Finder/Safari 复制链接给 `file:///…`（空格还会 percent
    /// 编码成 %20），终端与文本编辑器复制带尾随换行，拖进终端的带反斜杠转义，有人手打带引号。
    /// 旧实现只 `trimmingCharacters(in: .whitespaces)`（**不含 \n**）+ 展开 `~`，于是用户报的
    /// "有时候粘贴文件夹也无法跳转，很奇怪"——不是玄学，是取决于剪贴板里到底是哪种形态。
    ///
    /// 这里把输入展开成一串候选解释，调用方取第一个在盘上真实存在者。**原样候选永远排最前**，
    /// 所以名字里真的含反斜杠/引号的文件不会被"聪明"的反转义误伤。
    nonisolated static func candidates(_ raw: String, base: URL?) -> [String] {
        var out: [String] = []
        func push(_ candidate: String) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let expanded = (trimmed as NSString).expandingTildeInPath
            let absolute = expanded.hasPrefix("/")
                ? expanded
                : (base.map { $0.appendingPathComponent(expanded).path } ?? expanded)
            let standardized = (absolute as NSString).standardizingPath
            // 盘上是 NFD、剪贴板常给 NFC——两种 Unicode 归一化都试（中文/带音标名字必踩）
            for form in [standardized,
                         standardized.precomposedStringWithCanonicalMapping,
                         standardized.decomposedStringWithCanonicalMapping]
            where !out.contains(form) {
                out.append(form)
            }
        }

        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return [] }
        push(source)                                                    // ① 原样（最高优先）
        if source.lowercased().hasPrefix("file://") {                   // ② Finder/Safari 的 file:// URL
            if let url = URL(string: source), url.isFileURL { push(url.path) }
            if let decoded = source.removingPercentEncoding { push(String(decoded.dropFirst(7))) }
            push(String(source.dropFirst(7)))
        }
        if let decoded = source.removingPercentEncoding, decoded != source { push(decoded) }  // ③ 裸 percent 编码
        if source.count >= 2, let head = source.first, let tail = source.last,                // ④ 成对引号
           (head == "\"" && tail == "\"") || (head == "'" && tail == "'") {
            push(String(source.dropFirst().dropLast()))
        }
        if source.contains("\\") {                                      // ⑤ 拖进终端那种反斜杠转义
            var unescaped = ""
            var escaping = false
            for ch in source {
                if escaping { unescaped.append(ch); escaping = false }
                else if ch == "\\" { escaping = true }
                else { unescaped.append(ch) }
            }
            push(unescaped)
        }
        return out
    }

    /// 解析当前输入的落点。纯读盘、无副作用，便于自测直接断言。
    func resolve(_ raw: String) -> Resolution {
        Self.resolve(raw, base: baseDirectory?())
    }

    /// 与实例状态无关的纯解析（**必须可离开主线程调用**：失效的网络卷 / 自动挂载点上 stat
    /// 会阻塞几十秒，在主线程做就是整个 App 转菊花）。
    nonisolated static func resolve(_ raw: String, base: URL?) -> Resolution {
        let list = candidates(raw, base: base)
        guard !list.isEmpty else { return .empty }
        let fm = FileManager.default
        for path in list {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
                // 断链符号链接：fileExists 会跟随链接因而判假，但这条链接在列表里明明看得见。
                // attributesOfItem 是 lstat 语义（只看链接本身），据此当文件处理——进父目录选中它。
                if (try? fm.attributesOfItem(atPath: path)) != nil {
                    return .file(caseCanonical(URL(fileURLWithPath: path)))
                }
                continue
            }
            let url = caseCanonical(URL(fileURLWithPath: path))
            // .app/.bundle/.rtfd 等包：盘上是目录，但用户当它是"一个东西"——按 Finder 语义选中而非钻进去
            let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
            guard isDir.boolValue, !isPackage else { return .file(url) }
            guard fm.isReadableFile(atPath: path) else { return .unreadable(url) }
            return .directory(url)
        }
        return .notFound
    }

    /// 大小写归一。APFS/HFS+ 默认大小写不敏感：用户给的大小写可能与盘上不同，照搬会让面包屑显示
    /// 错误的名字、也让按名字定位对不上。**只在"仅大小写不同"时才采纳规范路径**——`canonicalPath`
    /// 同时会解析符号链接（`/tmp` → `/private/tmp`），那会改掉用户看到的路径层级，不是这里想要的。
    nonisolated static func caseCanonical(_ url: URL) -> URL {
        guard let canonical = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath,
              canonical != url.path,
              canonical.compare(url.path, options: .caseInsensitive) == .orderedSame
        else { return url }
        return URL(fileURLWithPath: canonical)
    }

    // MARK: 补全（输入即触发 complete:，防重入）

    func controlTextDidChange(_ notification: Notification) {
        rejectedJustNow = false   // 用户已动手改路径，上一轮拒绝翻篇（防标志滞留吞掉之后的真失焦复位）
        let newLength = (stringValue as NSString).length
        let typedOneChar = newLength == lastTextLength + 1
        lastTextLength = newLength
        guard !completing, currentEditor() is NSTextView else { return }
        // 粘贴（一次涌入多个字符）不弹补全。这是用户报的"有时候我 ⌘L 粘贴的是文件夹的时候也无法跳转，
        // 很奇怪"的第二个真因：补全 popup 会接管事件循环并吃掉紧随其后的那次 Enter（去采纳候选而非导航）。
        // 为什么"有时候"——PathCompleter 只列目录：粘文件夹路径必有候选、必弹 popup；粘 .apk 没候选、不弹。
        // 用户手敲字符时（+1）照常补全，I-30 的"首键即出候选"契约不受影响。
        guard typedOneChar else { return }
        // I-30：complete(nil) 必须【延迟到下一 runloop】触发，不可在 controlTextDidChange 内同步调用。
        // 同步调用时首次输入的补全 popup 被文本变更事务吞掉（首键无补全，需第二键才浮出）；
        // 异步派发让文本变更先落定，补全 popup 首键即出。
        inTextDidChange = true
        defer { inTextDidChange = false }
        DispatchQueue.main.async { [weak self] in
            guard let self, let editor = self.currentEditor() as? NSTextView else { return }
            self.completing = true
            // UITEST 无头环境：AppKit 补全 popup 会进入嵌套事件循环且无事件可退（主线程栈实锤
            // NSTextViewCompletionController 挂死、饿死看门狗）。自测只核"事务外触发"契约与候选数
            //（completions 回调仍走），不弹真 popup；产品路径不变。
            if UISelfTest.isEnabled {
                var idx = -1
                _ = self.control(self, textView: editor,
                                 completions: [],
                                 forPartialWordRange: editor.rangeForUserCompletion,
                                 indexOfSelectedItem: &idx)
            } else {
                editor.complete(nil)
            }
            self.completing = false
        }
    }

    func control(_ control: NSControl, textView: NSTextView,
                 completions words: [String], forPartialWordRange charRange: NSRange,
                 indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        index.pointee = -1
        uiTestCompletionTriggerCount += 1
        // I-30 契约核实：complete 必须在 controlTextDidChange 返回后才触发（否则首键 popup 被吞）
        uiTestCompletionWasDeferred = !inTextDidChange
        // 对整行内容补全（系统默认按词切分，路径需整行语义）
        let full = completer.complete(stringValue)
        uiTestLastCompletionCount = full.count
        // PathComplete 契约返回的是**完整绝对路径**，AppKit 却只把候选写回 charRange（末段词）。
        // 原样返回的话，采纳任一候选就拼成 /Users/me//Users/me/Downloads/ 这种垃圾，再 Enter 必然 shake。
        // 这里裁成"该填进 charRange 的那一段"，采纳后才是正确路径。全程按 NSString 长度算，中文名不错位。
        let text = stringValue as NSString
        guard charRange.location != NSNotFound, NSMaxRange(charRange) <= text.length else { return [] }
        let head = text.substring(to: charRange.location) as NSString
        return full.compactMap { candidate in
            let ns = candidate as NSString
            // 候选与「charRange 之前那段」对不上时（例如输入 `~`、候选却是展开后的绝对路径），
            // 没有任何"替换这一段"的写法能拼出正确路径——干脆不给候选、不弹 popup。
            // 用户仍可按 Tab 走我们自己实现的补全：那条路径直接整体改写 stringValue，恒正确。
            guard ns.hasPrefix(head as String) else { return nil }
            return ns.substring(from: head.length)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab 在路径输入框里是「补全」，不是「切走焦点」（Finder ⌘⇧G / 终端 / 浏览器地址栏皆然）。
            // 旧行为是走 AppKit 默认的移焦：编辑框随即失焦复位，用户打了一半的路径连同编辑态一起蒸发。
            completeToCommonPrefix()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }

    /// 提交当前输入。解析要读盘，**必须离开主线程**：失效的网络卷 / 自动挂载点上 stat 会阻塞几十秒，
    /// 在主线程做就是整个 App 转菊花。期间保持编辑态，解析完回主线程落地。
    private func submit() {
        guard !resolving else { return }          // 连按 Enter 不叠加解析
        let raw = stringValue
        let base = baseDirectory?()
        resolving = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.resolve(raw, base: base)
            }.value
            guard let self else { return }
            self.resolving = false
            // 解析期间用户可能已经改了内容或关掉了地址栏——结果作废，别把人拽到不相干的地方
            guard !self.isHidden, self.stringValue == raw else { return }
            switch result {
            case .empty:                 self.onCancel?()
            case .directory(let url):    self.onCommit?(url)
            case .file(let url):         self.onRevealFile?(url)
            case .unreadable:            self.reject(L10n.t("addressbar.error.denied"))
            case .notFound:              self.reject(L10n.t("addressbar.error.notFound"))
            }
        }
    }

    /// Tab 补全：唯一候选直接填入；多个候选补到最长公共前缀；补不动就 beep（有歧义，让用户自己再敲）。
    private func completeToCommonPrefix() {
        let candidates = completer.complete(stringValue)
        guard !candidates.isEmpty else { NSSound.beep(); return }
        let target = candidates.count == 1 ? candidates[0] : Self.longestCommonPrefix(candidates)
        let current = stringValue as NSString
        guard (target as NSString).length > current.length, target.hasPrefix(stringValue) else {
            NSSound.beep(); return
        }
        stringValue = target
        lastTextLength = (target as NSString).length
        currentEditor()?.moveToEndOfLine(nil)
    }

    nonisolated static func longestCommonPrefix(_ items: [String]) -> String {
        guard var prefix = items.first else { return "" }
        for item in items.dropFirst() {
            while !prefix.isEmpty, !item.hasPrefix(prefix) { prefix.removeLast() }
            if prefix.isEmpty { break }
        }
        return prefix
    }

    // MARK: 拖放（把拖进来的文件/文件夹变成路径——Finder 前往面板与各家浏览器地址栏都支持）

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedURL(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptDrop(from: sender.draggingPasteboard)
    }

    /// 投放落地（与 NSDraggingInfo 解耦的接缝：自测用私有 NSPasteboard 驱动，绝不碰用户真实剪贴板）
    @discardableResult
    func acceptDrop(from pasteboard: NSPasteboard) -> Bool {
        guard let url = fileURL(on: pasteboard) else { return false }
        beginEditing(with: url.path)   // 填入并全选：直接回车前往，或继续改
        return true
    }

    /// 拖拽载荷里的第一个文件 URL（非文件 URL 一律不接）
    func droppedURL(from sender: any NSDraggingInfo) -> URL? {
        fileURL(on: sender.draggingPasteboard)
    }

    private func fileURL(on pasteboard: NSPasteboard) -> URL? {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])
        return objects?.first as? URL
    }

    // MARK: 失焦复位（删除清空、点击他处、切走 App 后，绝不残留空白地址栏）

    func controlTextDidEndEditing(_ notification: Notification) {
        // onCommit / onRevealFile / onCancel 路径会先隐藏编辑框再转移 firstResponder，
        // 此时 isHidden 已为 true——跳过，避免二次复位。
        // 只有「用户点击他处 / 按 Tab 切走 / 窗口失活」造成的失焦（编辑框仍可见）才需要复位。
        guard !isHidden else { return }
        // 必须延迟到下一 runloop：在本回调栈里改 firstResponder 会与 AppKit 的结束编辑事务重入。
        // 实测该重入会扰动窗口/焦点时序，让随后的"外部打开"落到错误的窗口（I-52 由此确定性失败）。
        // 同 controlTextDidChange 里 complete(nil) 的延迟处理（I-30），一个套路。
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isHidden else { return }
            // 焦点又回到地址栏 = 根本不是"用户走开"。典型：编辑中再按一次 ⌘L，beginEditing 重设
            // stringValue 会让 AppKit 结束上一轮编辑并回调到这里——照常复位就把用户正在用的地址栏关了。
            // currentEditor() 非 nil 即"本控件正在被编辑"，是这件事最直接的判据。
            if self.currentEditor() != nil { return }
            if self.rejectedJustNow {
                // 路径输错导致的结束编辑：把焦点还回来并全选，用户直接重敲即可，别把人踢出去
                self.rejectedJustNow = false
                self.window?.makeFirstResponder(self)
                self.currentEditor()?.selectAll(nil)
                return
            }
            // 区分两种"结束编辑"：
            //  · 焦点落到本窗口里的另一个控件 = 用户在窗内点了别处，是真放弃编辑 → 复位（bug#3 那条路径）
            //  · 整个 App/窗口失活（⌘Tab 切走 / ⌘H 隐藏 / ⌘M 最小化）：AppKit 会把 firstResponder
            //    收回窗口本身（不是某个 NSView）。这不算放弃编辑，照常复位会把已经打了一半、
            //    或粘好还没回车的路径连同编辑态一起丢掉。Safari/Chrome 切回来内容都还在，这里对齐。
            let responder = self.window?.firstResponder as? NSView
            let movedWithinWindow = responder != nil && responder !== self && responder?.window === self.window
            guard NSApp.isActive || movedWithinWindow else { return }
            self.onReset?()
        }
    }

    /// 无效路径就地反馈：抖动 + beep + 地址栏内联红字（不弹窗——spec 做工不变量）
    private func reject(_ message: String) {
        rejectedJustNow = true
        shake()
        onInvalid?(message)
    }

    private func shake() {
        NSSound.beep()
        guard let layer else { return }
        // 基准必须取 layer 当前的 position.x，不能用 frame.midX：AppKit 图层背衬视图的
        // anchorPoint 是 (0,0)，layer.position 等于 frame 原点而非中心——按 midX 做基准会让
        // 地址栏先"瞬移"到自身半宽处再弹回，看起来像整条控件抽风，而不是抖动示意。
        let baseX = layer.position.x
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [0, -6, 6, -4, 4, 0].map { baseX + $0 }
        animation.duration = 0.3
        layer.add(animation, forKey: "shake")
    }

    /// UISelfTest（I-55）：末次抖动动画的关键帧（验证基准点取的是 layer.position.x 而非 frame.midX）
    var uiTestShakeValues: [CGFloat] {
        (layer?.animation(forKey: "shake") as? CAKeyframeAnimation)?
            .values?.compactMap { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } } ?? []
    }
}
