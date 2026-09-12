#!/usr/bin/env bash
# UI 冒烟：无需任何系统权限的自动化 UX 回归（frame 持久化端到端 + 视图/布局尺寸稳定
# + 任务窗空态 + 暂存入架 + 搜索面板）。产物 /tmp/nspace-ui/{report.txt,*.png}
set -uo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh >/dev/null 2>&1 || { echo "构建失败"; exit 1; }
pkill -x NSpace 2>/dev/null; sleep 0.5
rm -rf /tmp/nspace-ui

BIN=build/NSpace.app/Contents/MacOS/NSpace
# 阶段A：设定 frame 900x520 并退出（触发 autosave）
NSPACE_UITEST=1 NSPACE_UITEST_SETFRAME="900,520" "$BIN" >/dev/null 2>&1
# 阶段B：重启断言恢复 + 跑全场景
NSPACE_UITEST=1 NSPACE_UITEST_EXPECTFRAME="900,520" "$BIN" >/dev/null 2>&1
CODE=$?
echo "==== UI 冒烟报告 (exit=$CODE) ===="
cat /tmp/nspace-ui/report.txt 2>/dev/null || echo "(无报告)"
echo "截图: $(ls /tmp/nspace-ui/*.png 2>/dev/null | wc -l | tr -d ' ') 张 → /tmp/nspace-ui/"

# M17 新增断言存在性校验（防断言被误删/跑空即"绿"）：报告须含以下 PASS 行
REPORT=/tmp/nspace-ui/report.txt
require_pass() {
  if ! grep -qF "PASS $1" "$REPORT" 2>/dev/null; then
    echo "✗ 缺 M17 断言或未通过: $1"; CODE=1
  fi
}
require_pass "无 NSToolbar"
require_pass "甲板标签行高 40"
require_pass "甲板工具条行高 36"
require_pass "工作区标签条存在于甲板"
require_pass "版本徽章存在于甲板标签条"
require_pass "版本徽章无更新态文字"
require_pass "⌘T 新建工作区"
require_pass "⌘W 关闭工作区"
require_pass "侧栏列全高贯通"
require_pass "折叠/展开 3 轮窗口尺寸与右列布局不漂移"
require_pass "暂存架 contentGroup 居中"
require_pass "暂存架常态动作条隐藏"

# I-19/I-21 回归断言（v0.9.3）
require_pass "全局搜索面板含「包含隐藏文件」开关且可见"
require_pass "⌘W 分层：先关顶层设置窗"
require_pass "⌘W 分层：主窗工作区未被误关"
require_pass "⌘W 关闭后 MRU 回退到上一个活跃工作区"
require_pass "关最后窗口后 Dock 重开有窗"
# I-22 回归（v0.10.1）
require_pass "侧栏按钮折叠后再点可真展开"
# I-24b 回归（v0.11.0）
require_pass "分栏首列内容真渲染"
require_pass "列头排序真生效[name]"
require_pass "列头排序真生效[dateModified]"
require_pass "列头排序真生效[size]"
require_pass "列头排序真生效[kind]"
require_pass "列头排序真生效[created]"
require_pass "列头排序真生效[added]"
require_pass "目录右键打开=App 内导航"
require_pass "全局热键注册成功"
require_pass "全局热键呼出/隐藏切换真生效"

# M23 全功能自测矩阵（v0.11.0）：全部验「真实效果」而非「没崩溃」
require_pass "视图模式[list]对应视图真在层级且可见"
require_pass "视图模式[icons]对应视图真在层级且可见"
require_pass "视图模式[columns]对应视图真在层级且可见"
require_pass "布局 quad 真实呈现 4 窗格"
require_pass "布局 single 真实呈现 1 窗格"
require_pass "导航进入沙箱路径生效"
require_pass "导航进入子目录路径生效"
require_pass "导航后退路径真变回上级"
require_pass "导航前进路径真恢复"
require_pass "导航上层路径真变父级"
require_pass "新建窗格标签 → 标签数+1 且活动路径正确"
require_pass "关闭窗格标签 → 标签数复原"
require_pass "显示隐藏文件开关真实翻转模型状态"
require_pass "窗格标签栏开关真实翻转控制状态"
require_pass "新建文件夹真实落盘"
require_pass "制作副本真实落盘"
require_pass "重命名真实生效"
require_pass "移到废纸篓真实生效"
require_pass "沙箱守卫: 新建文件夹目标在自建夹具内"
require_pass "沙箱守卫: 制作副本源在自建夹具内"
require_pass "沙箱守卫: 重命名目标在自建夹具内"
require_pass "沙箱守卫: 移废纸篓目标在自建夹具内"
require_pass "拷贝路径 → 剪贴板内容正确"
require_pass "条目右键菜单含全部关键项"
require_pass "条目右键菜单诚实禁用：非归档选中无「解压」项"
require_pass "右键「复制」enabled 随选中态正确切换"
require_pass "空白区目录菜单项数=6 且含新建文件夹/新建文件/粘贴/简介/终端"
require_pass "任务窗手动开→可见"
require_pass "任务窗手动关→隐藏"
require_pass "显示简介面板出现"
require_pass "显示简介面板可关闭"
require_pass "设置页[settings.tab.archive] makeView 无约束歧义"
require_pass "设置页[settings.tab.behavior] makeView 无约束歧义"
require_pass "设置页[settings.tab.permissions] makeView 无约束歧义"
require_pass "设置页[settings.tab.appearance] makeView 无约束歧义"
require_pass "快捷键注册表默认绑定读取正确"
require_pass "侧栏含书签分组且种子书签行"
# I-31 搜索结果行右键菜单（v0.13.x）
require_pass "搜索结果右键菜单 items>0 且含「拷贝路径」"
require_pass "搜索结果右键菜单含定位/加入暂存架/显示简介"
require_pass "搜索结果右键「拷贝路径」→ 剪贴板内容==该路径"

# I-30 回归：⌘L 路径编辑首键一次生效 + 补全在文本变更事务外触发（首键 popup 不被吞）
require_pass "I-30 ⌘L 后首键 '/' 字符一次生效"
require_pass "I-30 首键即触发补全候选"
require_pass "I-30 补全在文本变更事务之外触发"

# I-32 回归（多选删除后选中清空，三视图同验；验"真实效果"：视图层选中真空 + 状态栏无"已选"）
require_pass "多选删除后选中清空[list]"
require_pass "多选删除后选中清空[icons]"
require_pass "多选删除后选中清空[columns]"
require_pass "沙箱守卫[list]: I-32 移废纸篓目标在自建夹具内"
require_pass "沙箱守卫[icons]: I-32 移废纸篓目标在自建夹具内"
require_pass "沙箱守卫[columns]: I-32 移废纸篓目标在自建夹具内"

# I-37 回归：面包屑地址栏宽度自适应（深层级/长名不溢出 + 中间折叠全层级永远可达；验"真实效果"）
require_pass "沙箱守卫: I-37 深层链在自建夹具内"
require_pass "I-37 面包屑不溢出"
require_pass "I-37 「…」折叠段存在且菜单项数==折叠层级数"
require_pass "I-37 点折叠菜单项 → 窗格真跳到该层级"
require_pass "I-37 可见末段 toolTip==完整名"
require_pass "I-37 窄窗格仍不溢出"
# M26 列表「年/月」分组（验真实效果：组头/折叠/过滤/跨排序选中/开关）
require_pass "沙箱守卫[m26]: 分组夹具 6 文件在自建夹具内"
require_pass "M26 分组组头数==3 相对桶标题正确各组2项"
require_pass "M26 组头是背景条不可折叠"
require_pass "M26 仅显示此组表仅剩该组+药丸可见，显示全部还原"
require_pass "M26 跨组重排序后选中按 URL 仍在"
require_pass "M26 关闭分组组头数==0 恢复单线"

# I-39 回归：⌘↑/⌘↓ 互逆导航（上层自动选中来源子目录 / 下层选中驱动优先 / 无选中回退历史 / 守卫吞键）
require_pass "I-39 ⌘↑ 上层后自动选中来源子目录"
require_pass "I-39 ⌘↓ 进入所选文件夹（选中驱动，非历史兜底）"
require_pass "I-39 ⌘↓ 无选中时回退最近历史直接子级"
require_pass "I-39 ⌘↓ 落表视图被吞不跳选（守卫真实生效）"

# I-38/I-40 回归：搜索结果流不打断选中 + 局部按根近排序（同层字典序/符号链接口径/根外沉底）+ 路径列常驻
require_pass "I-40 局部搜索按离根近者优先排序（直接子级最先）"
require_pass "I-40 结果表常驻路径列实渲染父目录路径"
require_pass "I-40 同层字典序（a.txt 先于 aa.txt，全序核验）"
require_pass "I-40 解析路径口径命中仍按深度排序（符号链接根不失效）"
require_pass "I-40 根外命中沉底为最后一行"
require_pass "I-38 流式新批次到达后选中项不丢不漂（行号位移仍锁同一 URL）"

# M27 冲突体验（三按钮取消/合并/替换 + 「应用到此文件夹」checkbox 按文件夹批量 + 文件冲突合并禁用）
require_pass "M27 checkbox 批量一次只作用一个文件夹"
require_pass "M27 逐文件夹批量：面板出现次数==文件夹数（2 文件夹→2 次）"
require_pass "M27 未勾 checkbox 只决议当前一条（逐条推进）"
require_pass "M27 取消 → 决议返回 nil（整体放弃）"
require_pass "M27 面板四按钮(取消/合并/两者保留/替换)+左下「应用到此文件夹」checkbox（自绘真渲染）"
require_pass "M27 文件冲突「两者保留」可用"
require_pass "M27 文件冲突「合并」禁用（仅文件夹可合并，诚实不可点）"

# I-34 大小列单行不折行 + M26 v2 图标视图分组（section/折叠/过滤/选中跨 rebuild）
require_pass "I-34 大小列单行不折行（usesSingleLineMode + 头部截断）"
require_pass "M26v2 图标视图分组 section==3 相对桶标题正确"
require_pass "M26v2 图标视图组头是背景条不可折叠"
require_pass "M26v2 图标视图仅显示此组+药丸，显示全部还原"
require_pass "M26v2 图标视图选中按 URL 跨 rebuild 保持"

# 窗口尺寸持久化根因（用户报告"更新后尺寸回默认"）：自管恢复权威、不与 macOS 原生恢复竞争
require_pass "窗口尺寸自管恢复：isRestorable=false（不与 macOS 原生恢复竞争）"

# I-42 全局搜索卡死根因：大结果集流式累积 O(n) 不卡 + 达上限截断提示（引擎侧上限见 SearchEngineTests）
require_pass "I-42 大结果流式累积 O(n) 不卡"
require_pass "I-42 达结果上限显示「仅显示前 N 条」截断提示"

# M29 人性化时间：相对分桶（今天/昨天/本周/本月/今年更早/往年）+ 日期列本年隐年份
require_pass "M29 相对分桶 6 桶 keyTitle 落位正确"
require_pass "M29 日期列本年隐年份/非本年显年份"
# I-49 组排序错乱（今天被挤到最底）：foldersFirst 下组仍按相对时间新近排
require_pass "I-49 foldersFirst 下组仍按新近排：今天(仅文件)在最前不被文件夹桶挤到末尾"

# I-46 窗口尺寸被测试污染根因：UITEST 帧键隔离（不写产品 windowFrame）
require_pass "I-46 UITEST 帧键隔离（写 windowFrame.uitest 不碰产品 windowFrame）"
require_pass "I-46 UITEST 侧栏宽键隔离"
# I-43 点选区内收敛卡顿（AppKit 双击间隔~0.5s 等待）：纯单击已选多选行抢先收敛谓词
require_pass "I-43 点选区内收敛谓词：纯单击多选已选行=抢先收敛，修饰键/双击/选区外/单选=不介入"
# M28 搜索智能排序（frecency+匹配融合）：开关开=高频次命中最前 / 关=回退到达序
require_pass "M28 智能排序开：高 frecency 命中排最前"
require_pass "M28 智能排序关：回退到达序"
require_pass "M28/I-47 UITEST 存储隔离（frecency/session 写临时目录不碰用户真实数据）"
# I-47 重启回 home：导航即落盘（非干净退出也不丢），否则位置只在干净退出才保存
require_pass "I-47 导航即落盘：会话记住导航目录"
# I-50 排序不持久化：改排序即落盘（非干净退出也不丢）
require_pass "I-50 改排序即落盘：会话记住排序列/方向"
# I-52 外部/浏览器 reveal 落点可配：默认现有窗口新标签(不弹新窗)/新窗口
require_pass "I-52 外部打开默认「新标签」：复用现有窗口不弹新窗"
require_pass "I-52 外部打开「新窗口」：弹新窗"
# I-44 第三方"打开文件位置"真定位选中（select 参数此前被丢弃）：接通 + 列表 + 图标视图模式感知
require_pass "I-44 openWindow(selecting:) 真定位选中目标文件"
require_pass "I-44 列表视图 reveal 真定位选中目标文件"
require_pass "I-44 图标视图 reveal 真定位选中目标文件（视图模式感知，非硬编码 listVC）"
# I-48 reveal 定位后选中无蓝色高亮：定位后表格获焦（选中显强调蓝）
require_pass "I-48 reveal 后表格获焦（选中显蓝色强调，非未强调灰）"
# I-45 Quick Look 收起淡出（不再缩到图标点）：收起态 sourceFrame=.zero，开启态=图标矩形
require_pass "I-45 QL 收起 sourceFrame 淡出(.zero)、开启为图标矩形缩放"

# I-53~I-57 地址栏三 bug（⌘L 全选 / 粘贴路径 Enter 跳转 / 失焦后回显）——用户报告
require_pass "沙箱守卫[I-53]: 地址栏回归夹具在自建临时目录内"
require_pass "I-53 ⌘L 呼出后地址栏文本全选"
require_pass "I-53 Enter 文件夹路径 → 导航到该文件夹"
require_pass "I-53 文件夹导航后编辑框已退出（面包屑回显）"
require_pass "I-53 Enter 文件路径（.apk）→ 导航父目录并选中该文件"
require_pass "I-53 文件 reveal 后编辑框已退出（面包屑回显）"
require_pass "I-53 Enter 不存在路径 → 不跳转（仍在原目录）"
require_pass "I-53 清空地址栏后失焦 → 编辑框退出，面包屑回显当前路径"
require_pass "I-53 编辑中退回上级 → 编辑框退出+面包屑回显新目录"
require_pass "沙箱守卫[I-54]: 路径解析矩阵夹具在自建临时目录内"
require_pass "I-54 路径解析矩阵 26/26 通过"
require_pass "I-54 ⌘L 全选后粘贴整段替换（非追加）"
require_pass "I-54 无效路径 → 不跳转 + 内联提示 + 留在输入框可就地改"
require_pass "I-54 删空地址栏后 ⌘R 刷新 → 菜单动作经响应链送达且编辑框退出"
require_pass "I-54 粘贴当前目录内的文件 → 原地选中"
require_pass "I-54 粘贴不弹补全"
require_pass "I-54 补全候选是末段而非整条绝对路径"
require_pass "沙箱守卫[I-55]: 边界修复夹具在自建临时目录内"
require_pass "I-55 大小写与盘上不一致的路径仍能定位选中"
require_pass "I-55 粘贴隐藏文件路径 → 自动显示隐藏文件并选中"
require_pass "I-55 目标目录已载入仍找不到目标 → pending 定位作废"
require_pass "I-55 Tab 补全唯一候选且仍留在输入框"
require_pass "I-55 多候选 Tab 补到最长公共前缀"
require_pass "I-55 地址栏已注册 fileURL 拖放类型"
require_pass "I-55 拖文件到地址栏 → 填成其路径"
require_pass "I-55 补全候选 head 对不上时全裁"
require_pass "I-55 抖动以 layer.position.x 为基准"
require_pass "I-55 分栏模式粘贴文件路径也能选中"
require_pass "I-56 编辑地址栏时切布局：焦点仍在某个控件上而非掉回窗口"
require_pass "I-56 读盘途中切视图模式，待定位目标搬到新视图"
require_pass "I-57 窗口失 key：空地址栏自收、有内容一律保留"
require_pass "I-57 退出编辑后面包屑真回显当前目录且 field editor 已释放"
require_pass "I-57 ⌘L 经真实响应链送达且全选"
require_pass "I-57 同一目录的不同写法不重复压后退栈"
# I-58 排序指示器反向同步（模型→列头；此前product代码里根本不存在这条链）——用户报告
require_pass "I-58 模型改排序后列头指示器同步"
require_pass "I-58 重建列后指示器仍在"
# I-59 空白处 ⌘⇧C 回落到当前目录（三视图）——用户报告
require_pass "沙箱守卫[I-59]: 拷贝路径夹具在自建临时目录内"
require_pass "I-59 空选中拷贝路径回落到当前目录"
# I-60 冷启动外部打开排队（Chrome「在访达中显示」开新窗而非新标签）——用户报告
require_pass "沙箱守卫[I-60]: 外部打开排队夹具在自建临时目录内"
require_pass "I-60 会话未就绪的外部打开只排队不开窗"
require_pass "I-60 冲刷后落到现有窗口新标签"
# I-61 面包屑命中盒（用户报告：地址栏要点到文件夹正中心才跳转，偏一点变成输入模式）
require_pass "沙箱守卫[I-61]: 命中盒夹具在自建临时目录内"
require_pass "I-61 段命中盒占满地址栏全高"
require_pass "I-61 箭头命中盒占满地址栏全高"
require_pass "I-61 段名左右留命中余量"
require_pass "I-61 全高命中点触发导航（非编辑模式）"
require_pass "I-61 内容右缘之右仍是空白点击进编辑"
require_pass "I-61 极窄栏仍不溢出且层级全可达"
require_pass "I-61 每级总宽与改前一致"
require_pass "I-61 点非活动窗格地址栏 → 该窗格被激活"
# I-62 废纸篓（用户报告：缺少废纸篓功能，右上角垃圾桶钮点了没用/常灰）
require_pass "沙箱守卫[I-62]: 废纸篓夹具在自建临时目录内"
require_pass "I-62 空选中时甲板垃圾桶钮仍可用"
require_pass "I-62 点垃圾桶钮 → 应用内跳到废纸篓"
require_pass "I-62 废纸篓内容真被列出"
require_pass "I-62 拖到垃圾桶钮 → 真移到废纸篓"
require_pass "I-62 前往菜单含「废纸篓」项并接 goTrash"
require_pass "I-62 按窗口反查控制器"
# I-63 清空废纸篓（不可逆，Eraser 胶囊）+ 放回原处（TrashLedger 胶囊）
require_pass "沙箱守卫[I-63]: 清空夹具在自建临时目录内"
require_pass "I-63 垃圾桶钮右键菜单含「清空废纸篓」"
require_pass "I-63 清空废纸篓真删内容且保留篓本身"
require_pass "I-63 清倒确认回车只取消"
require_pass "I-63 放回原处闭环"
require_pass "I-63 无台账记录的项不许假装能放回"
require_pass "I-63 条目菜单按位置切换放回/移入"
# I-64 地址栏右端的「清倒」按钮（用户报告：藏在右键菜单里等于没有）
require_pass "I-64 「清倒」钮只在废纸篓出现"
require_pass "I-64 真点「清倒」打开本窗确认，默认取消"
require_pass "I-64 取消清倒不删除任何项目"
require_pass "I-64 编辑地址时「清倒」钮收起、退出编辑后回来"
require_pass "I-64 废纸篓子文件夹里不显示「清倒」"
# I-65 ⌘V 粘成新文件 / 单击已选中项重命名 / 底部空白区 / 新建文件快捷键（五条用户报告）
require_pass "沙箱守卫[I-65]: 粘贴/重命名夹具在自建临时目录内"
require_pass "I-65 剪贴板推导：图片优先于文本、空内容不成文件"
require_pass "I-65 ⌘V 把剪贴板内容粘成新文件"
require_pass "I-65 单击重命名谓词：仅「单选+点已选中行+无修饰+单击」为真"
require_pass "I-65 列表底部留白可右键出新建菜单"
require_pass "I-65 新建文件有快捷键且不与新建文件夹冲突"
# I-66 设置项搜索框（用户要：所有配置都能搜索并跳转到对应配置项）
require_pass "I-66 设置项索引从真实视图树建起"
require_pass "I-66 输入即出结果"
require_pass "I-66 点结果跳到对应页签"
require_pass "I-66 清空搜索后结果区收起"
# I-67 复制/剪切不许清掉选中（用户报告：⌘C 之后选中框不见了）
require_pass "沙箱守卫[I-67]: 剪贴板选中夹具在自建临时目录内"
require_pass "I-67 复制/剪切后选中不丢"
# I-68 侧栏点一次就跳 + 高亮跟随窗格（用户报告：点「下载」没反应，得先点别的再点回来）
require_pass "I-68 换目录后侧栏高亮不再指着旧位置"
require_pass "I-68 点已高亮的侧栏行仍然跳转"
require_pass "I-68 停在书签目录时侧栏高亮指向它"
# I-69 新标签继承派生标签的排序/隐藏/视图模式（用户报告：new tab 没记住修改日期排序）
require_pass "沙箱守卫[I-69]: 新标签夹具在自建临时目录内"
require_pass "I-69 新标签继承排序/隐藏/视图模式"
require_pass "I-69 新标签列头指示器随继承的排序"
require_pass "I-64 子目录夹具放回原处"

echo "==== M17 断言校验完毕 (exit=$CODE) ===="
# 测试沙箱铁律收尾（I-46 / M28 / I-47）：清理 UITEST 隔离态，绝不留测试残留在用户真实域
defaults delete com.nspace.NSpace "windowFrame.uitest" 2>/dev/null || true
rm -rf "$TMPDIR/nspace-uitest-support" /tmp/nspace-uitest-support "$TMPDIR/nspace-uitest-frecency" /tmp/nspace-uitest-frecency 2>/dev/null || true
exit $CODE
