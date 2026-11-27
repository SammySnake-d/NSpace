import Foundation
import NSpaceContracts

// BatchRename 胶囊唯一对外契约面（Axiom 3）

public struct BatchRenameError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public let path: String?

    public init(_ cls: ErrorClass, _ message: String, path: String? = nil) {
        self.errorClass = cls
        self.localizedDescription = message
        self.path = path
    }
}

public enum BatchRenameCase: String, Sendable, CaseIterable {
    case lowercase
    case uppercase
    case titlecase
}

public enum BatchRenameSequencePosition: String, Sendable, CaseIterable {
    case prefix
    case suffix
    case replace
}

public enum BatchRenameExtMode: Sendable, Equatable {
    case keep
    case lowercase
    case uppercase
    case replace(String)
}

public enum BatchRenameRule: Sendable, Equatable {
    case replaceText(find: String, replacement: String, matchCase: Bool, useRegex: Bool, applyToExtension: Bool)
    case addAffix(prefix: String, suffix: String)
    case numberSequence(base: String, start: Int, step: Int, padding: Int, position: BatchRenameSequencePosition)
    case changeCase(BatchRenameCase)
}

public struct BatchRenamePreview: Sendable, Equatable {
    public let source: URL
    public let currentName: String
    public let newName: String
    public let changed: Bool
    public let issue: String?

    public init(source: URL, currentName: String, newName: String, changed: Bool, issue: String?) {
        self.source = source
        self.currentName = currentName
        self.newName = newName
        self.changed = changed
        self.issue = issue
    }

    public var isValid: Bool { issue == nil }
}

public enum BatchRenamePlanner {
    /// 纯规划入口：为每个源推导预览新名并做同批冲突、非法字符与外部碰撞校验
    public static func preview(
        sources: [URL],
        rule: BatchRenameRule,
        extMode: BatchRenameExtMode = .keep,
        externalExists: ((URL, String) -> Bool)? = nil
    ) -> [BatchRenamePreview] {
        guard !sources.isEmpty else { return [] }

        var regex: NSRegularExpression?
        var regexError: String?
        if case let .replaceText(find, _, matchCase, useRegex, _) = rule,
           useRegex, !find.isEmpty {
            let options: NSRegularExpression.Options = matchCase ? [] : [.caseInsensitive]
            do {
                regex = try NSRegularExpression(pattern: find, options: options)
            } catch {
                regexError = "正则表达式无效"
            }
        }

        // 记录所有参与本批重命名的源，互换或链式移动（如 a->b, b->c）不算外部冲突
        var sourceKeysByParent: [String: Set<String>] = [:]
        var sourceInodes: Set<BatchRenameNode.EntryIdentity> = []
        for url in sources {
            let parent = url.deletingLastPathComponent().path
            sourceKeysByParent[parent, default: []].insert(url.lastPathComponent.lowercased())
            if let eid = BatchRenameNode.entryIdentity(url) {
                sourceInodes.insert(eid)
            }
        }

        var draftNames: [(url: URL, current: String, proposed: String, earlyIssue: String?)] = []
        var targetCountsByParent: [String: [String: Int]] = [:]

        for (index, url) in sources.enumerated() {
            let current = url.lastPathComponent
            let isDir = isPlainDirectory(url)
            let (stem, ext) = splitName(current, isDirectory: isDir)

            if let regexError {
                draftNames.append((url, current, current, regexError))
                continue
            }

            let (newStem, newExtFromRule) = Self.transformName(
                current: current,
                stem: stem,
                ext: ext,
                isDirectory: isDir,
                index: index,
                rule: rule,
                regex: regex
            )

            let finalExt = applyExtMode(newExtFromRule, mode: extMode, isDirectory: isDir)
            let proposed = finalExt.isEmpty ? newStem : "\(newStem).\(finalExt)"

            var issue: String?
            if proposed.isEmpty {
                issue = "新文件名不能为空"
            } else if proposed.contains("/") || proposed == "." || proposed == ".." {
                issue = "包含非法路径字符"
            }

            let parent = url.deletingLastPathComponent().path
            targetCountsByParent[parent, default: [:]][proposed.lowercased(), default: 0] += 1
            draftNames.append((url, current, proposed, issue))
        }

        return draftNames.map { item in
            let parentURL = item.url.deletingLastPathComponent()
            let parentPath = parentURL.path
            let key = item.proposed.lowercased()
            var issue = item.earlyIssue

            if issue == nil, (targetCountsByParent[parentPath]?[key] ?? 0) > 1 {
                issue = "批次内名称冲突"
            }

            let changed = item.proposed != item.current
            if issue == nil, changed {
                let dst = parentURL.appendingPathComponent(item.proposed)
                if let externalExists {
                    let isBatchSource = sourceKeysByParent[parentPath]?.contains(key) ?? false
                    if !isBatchSource && externalExists(parentURL, item.proposed) {
                        issue = "目标已存在同名项"
                    }
                } else if let dstInode = BatchRenameNode.entryIdentity(dst),
                          !sourceInodes.contains(dstInode) {
                    issue = "目标已存在同名项"
                }
            }

            return BatchRenamePreview(
                source: item.url,
                currentName: item.current,
                newName: item.proposed,
                changed: changed,
                issue: issue
            )
        }
    }

    static func splitName(_ name: String, isDirectory: Bool) -> (stem: String, ext: String) {
        if isDirectory { return (name, "") }
        // 隐藏文件如 `.gitignore` 无扩展名；`.env.local` 取 `.env` + `local`
        let ns = name as NSString
        let dot = ns.range(of: ".", options: .backwards)
        guard dot.location != NSNotFound, dot.location > 0, dot.location + 1 < ns.length else {
            return (name, "")
        }
        return (ns.substring(to: dot.location), ns.substring(from: dot.location + 1))
    }

    private static func transformName(
        current: String,
        stem: String,
        ext: String,
        isDirectory: Bool,
        index: Int,
        rule: BatchRenameRule,
        regex: NSRegularExpression?
    ) -> (String, String) {
        switch rule {
        case let .replaceText(find, replacement, matchCase, _, applyToExtension):
            if applyToExtension {
                let full = applyReplace(in: current, find: find, replacement: replacement,
                                        matchCase: matchCase, regex: regex)
                return splitName(full, isDirectory: isDirectory)
            }
            return (applyReplace(in: stem, find: find, replacement: replacement,
                                 matchCase: matchCase, regex: regex), ext)
        case let .addAffix(prefix, suffix):
            return ("\(prefix)\(stem)\(suffix)", ext)
        case let .numberSequence(base, start, step, padding, position):
            let seqNum = start + index * max(1, step)
            let width = max(1, padding)
            let numStr = String(format: "%0\(width)d", seqNum)
            let nextStem: String = switch position {
            case .prefix: "\(numStr)\(base)\(stem)"
            case .suffix: "\(stem)\(base)\(numStr)"
            case .replace: "\(base)\(numStr)"
            }
            return (nextStem, ext)
        case let .changeCase(mode):
            return (applyCase(stem, mode: mode), ext)
        }
    }

    private static func isPlainDirectory(_ url: URL) -> Bool {
        let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isDir = vals?.isDirectory ?? url.hasDirectoryPath
        let isPkg = vals?.isPackage ?? false
        return isDir && !isPkg
    }

    private static func applyReplace(
        in input: String,
        find: String,
        replacement: String,
        matchCase: Bool,
        regex: NSRegularExpression?
    ) -> String {
        guard !find.isEmpty else { return input }
        if let regex {
            let range = NSRange(location: 0, length: (input as NSString).length)
            return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: replacement)
        }
        let options: String.CompareOptions = matchCase ? [] : [.caseInsensitive]
        return input.replacingOccurrences(of: find, with: replacement, options: options)
    }

    private static func applyCase(_ input: String, mode: BatchRenameCase) -> String {
        switch mode {
        case .lowercase: input.lowercased()
        case .uppercase: input.uppercased()
        case .titlecase: input.localizedCapitalized
        }
    }

    private static func applyExtMode(_ ext: String, mode: BatchRenameExtMode, isDirectory: Bool) -> String {
        if isDirectory { return "" }
        switch mode {
        case .keep: return ext
        case .lowercase: return ext.lowercased()
        case .uppercase: return ext.uppercased()
        case .replace(let custom):
            let trimmed = custom.hasPrefix(".") ? String(custom.dropFirst()) : custom
            return trimmed
        }
    }
}
