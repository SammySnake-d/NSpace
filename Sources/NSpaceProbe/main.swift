import Foundation

// CLI-First 探针：绕过 UI 编排单独驱动每个胶囊节点（L-readonly / L-irreversible）。
// 不进 .app、不进生产二进制。M1 起每接入一个胶囊就加一个子命令。

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    nspace-probe — NSpace 胶囊节点活体探针
    用法:
      nspace-probe <子命令> [参数…]
    子命令: (随胶囊接入逐个增加)
    """)
    exit(2)
}

guard let command = args.first else { usage() }

switch command {
default:
    FileHandle.standardError.write("未知子命令: \(command)\n".data(using: .utf8)!)
    usage()
}
