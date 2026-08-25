import AppKit

/// L1 轻量吐司（方法论三级通知模型）：非阻断成功反馈，2s 自动隐退。
/// 用于"已拷贝路径/已拷贝 N 项/已添加书签"这类操作确认——消除"操作后界面死寂"。
@MainActor
enum Toast {
    private static var current: NSView?

    static func show(_ text: String, in window: NSWindow?) {
        guard let contentView = window?.contentView else { return }
        current?.removeFromSuperview()

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let pill = NSVisualEffectView()
        pill.material = .hudWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 16
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        contentView.addSubview(pill)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -8),
            pill.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.bottomAnchor, constant: -32),
        ])
        current = pill
        pill.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            pill.animator().alphaValue = 1
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard current === pill else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                pill.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    pill.removeFromSuperview()
                    if current === pill { current = nil }
                }
            })
        }
    }
}
