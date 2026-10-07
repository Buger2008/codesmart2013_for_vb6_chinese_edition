#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; ===========================================================================
;  自动汉化循环  —  AutoHotkey v2 (需 2.0 以上)
;
;  用法:
;    1. 鼠标点进目标程序里那个文本框 (让焦点在它上面)
;    2. 按 Ctrl+Alt+S 开始
;    3. 想停就按 Esc
;
;  每一轮做的事:
;    [取原文]  右键菜单键 -> a(全选) -> Ctrl+C
;              -> translate.py            输出两行: 第1行 true/false, 第2行处理后的文本
;    true  :   (全选) 粘贴第2行 -> 右键菜单全选 (读基准)
;              -> 再全选一次 (系统菜单延迟400ms + WM_NULL冲队列 + STranslate准备200ms,
;                 并用 EM_GETSEL 向控件核对“真的全选了吗”, 没全选就重来)
;              -> 右Alt+F 分步慢按; 文本框一直没变就判定没翻译成, 重试
;              -> 等翻译出现 -> 全选 Ctrl+C 取译文
;              -> translateposthtml.py    输出一行 -> (全选) 粘贴回去 -> 回车
;    false :   直接回车
;    然后进入下一个文本框, 无限循环, 直到按 Esc。
;
;  ⚠ 凡是“粘贴”, 前面一定紧跟一次全选 (见 SELECT_ALL_BEFORE_PASTE):
;    因为两次操作之间可能隔着几秒到几十秒 (translate.py 要联网), 那会儿的
;    选中状态早没了, 直接粘会插在光标处而不是替换整段。
;
;  出问题先看日志: 同目录 ahk_translate_loop.log
;  只想验证和 python 的连接 (不动任何窗口): 命令行加 --selftest
; ===========================================================================


; ============================ 用户配置 =====================================

; --- 路径 ---
; 同目录调用: 两个 py 就放在脚本自己所在的目录里, 整个目录可以整体搬走。
;   release\ 里就是完整一套: ahk_translate_loop.ahk + translate.py
;   + translateposthtml.py + translatejudge.py + translateprehtml.py
; 所以同一个脚本在 auto\ 和 release\ 下都能跑, 各自用自己旁边的 py。
global PYTHON      := "D:\Program\Python3\python.exe"     ; 不在就自动退回 PATH 里的 python
global PRE_SCRIPT  := A_ScriptDir "\translate.py"
global POST_SCRIPT := A_ScriptDir "\translateposthtml.py"

; --- 按键方式 ---
;   "Event"  更接近真人按键, 兼容老程序 (默认)
;   "Input"  更快, 个别老程序可能收不到
global SEND_MODE   := "Event"
global KEY_DELAY   := 30          ; 每个键之间间隔(ms)
global KEY_DUR     := 20          ; 每个键按住时长(ms)

; --- 各种等待时间 (ms) ---
; ⚠ 这些是"死等"值 (ADAPTIVE_WAITS=false 时)。
;   2026-10-06 按实测日志把"该快的步骤"全部压到 0:
;     取文本 828ms -> 只留菜单等待;  粘贴后/回车后不再白等;  空框不再等 2 秒
global T_MENU_OPEN   := 300       ; 按下右键菜单键后, 等菜单弹出来 (不能动: 动过就翻译失效)
global T_MENU_PICK   := 200       ; 按 a 选“全选”后 (同上)
global T_AFTER_COPY  := 0         ; Ctrl+C 之后; ClipWait 已经确认剪贴板有内容, 不用再等
global T_CLIP_WAIT   := 600       ; 等剪贴板出现内容的上限; 取文本是本地操作, 不该等太久
global T_AFTER_PASTE := 0         ; Ctrl+V 之后; 粘贴完直接回车, 程序会立刻进下一个框
; ⚠ 这个不能是 0: 回车之后程序要把【下一个框】的内容填进去, 需要一点时间。
;   以前全选要弹右键菜单(约 500ms), 那段时间一直在替我们等 —— 所以设 0 也没事。
;   改成 API 全选(约 1ms)之后这层等待就没了, 必须显式留出: 否则 Ctrl+C 会打在
;   一个还没填内容的框上, 表现为"没取到文本", 和"框本来就空"长得一模一样。
global T_AFTER_ENTER := 150
global T_START_WAIT  := 350       ; 按下 Ctrl+Alt+S 后, 等你松开手

; 自适应等待总开关 (2026-10-06 起默认 false):
;   false = 死等上面那些值 —— 已验证可用 (240 次翻译成功)
;   true  = 能确认就提前走 (菜单窗口 #32768 / 焦点换控件 / WM_NULL 冲队列)
; 实测教训: 打开自适应后, 取文本从 860ms 降到 171ms, 但**翻译连续 4 次全不响应**。
; 怀疑点是"菜单窗口一出现就按 a" —— 菜单窗口存在 != 菜单能接受加速键, 'a' 可能
; 根本没触发"全选", 于是 STranslate 拿不到选中内容; 而取文本/粘贴两条路对这个
; 不敏感 (这个控件的 Ctrl+C/Ctrl+V 不依赖选中), 所以只有翻译会坏, 日志看着还正常。
; 想再试就在单条文本上试, 并且看日志里 [取文本]/[等译文] 的耗时。
global ADAPTIVE_WAITS := false

; --- 翻译等待 ---
; WAIT_MODE = "poll"  : 反复看文本变了没, 一变就继续 (快, 默认)
; WAIT_MODE = "fixed" : 死等 T_TRANS_FIXED 毫秒再一次拿结果
;
; 轮询现在是**免费的**: 读文本走 WM_GETTEXT (不按键、不碰剪贴板、不弹菜单),
; 一次约 1ms。所以间隔可以压得很短, 译文一出现就能立刻发现。
global WAIT_MODE     := "poll"
global T_TRANS_FIXED := 3000      ; fixed 模式死等多久
global T_TRANS_WAIT  := 300       ; 按完右Alt+F 先干等这么久再开始看 (2026-10-06: 1200 -> 300)
global T_TRANS_POLL  := 150       ; 之后每隔多久看一次 (2026-10-06: 500 -> 150)
global T_TRANS_MAX   := 2500      ; **等"第一次出现变化"的上限** (2026-10-06: 12s -> 2.5s)
                                  ;   超过就判定 STranslate 没反应, 不再干等
global T_TRANS_GRACE := 3000      ; 但**一旦已经看到变化**, 再多给这么久去确认稳定 ——
                                  ;   否则刚好卡在 2.5s 边界出现的译文会被丢掉, 然后被
                                  ;   原文覆盖 (那才是真的亏)
global LOG_POLLS     := false     ; 每轮轮询都写一行日志 (排查"翻译没反应"时打开)
global T_PY_MAX      := 60000     ; 单次 python 调用的上限 (judge 联网最坏 34s)

; --- 全选之后的等待: 按 Windows API 手册的系统时间参数来定, 不拍脑袋写数字 ---
;   SPI_GETMENUSHOWDELAY (0x006A) 系统显示右键菜单前等多久, 出厂默认 400ms
;   SPI_GETMESSAGETIMEOUT (0x0028) 消息超时, 拿来当“冲消息队列”的等待上限
; 我们每一步都是“弹右键菜单 -> 选菜单项 -> 立刻按键”, 所以用系统自己的
; 菜单延迟当基准最贴合; 嫌不够就在 SELECT_SETTLE_EXTRA 上再加。
global SELECT_SETTLE_MODE  := "system"   ; "system" = 用系统值; 也可以直接写数字(ms)
global SELECT_SETTLE_EXTRA := 0          ; 在系统值之上再加多少 ms
global T_AFTER_SELECTALL   := 400        ; 下面按系统设置算出来 (算不出来就用 400)
global T_FLUSH_TIMEOUT     := 2000       ; 下面按系统设置算出来

; 光等还不够: 等完再往目标窗口发一个 WM_NULL 把消息队列冲干净。
; 手册里 WM_NULL 的用途就是“想确认一条消息已被处理时发它”; SendMessageTimeout
; 会等窗口过程处理完这条消息才返回 (SMTO_BLOCK), 所以它一返回, 前面排队的
; 按键消息就都已经处理完了 —— 这才是“真的全选好了”, 而不是“估计差不多了”。
global USE_MESSAGE_FLUSH := true

; --- STranslate 的准备时间 ---
; 消息队列冲干净只说明【目标文本框】把按键处理完了, 不代表【STranslate】准备好
; 接手了 —— 它是另一个进程, 有自己的内部状态机 (取词/取选中/建请求/线程调度),
; 这些都不受目标程序消息队列的约束。所以冲完队列之后再单独给它留一段时间,
; 万一还偶尔出现“没准备好”, 就把这个值往上加 (300 -> 400 -> 500)。
global T_TRANS_PREPARE := 300

; --- 全选方式 ---
; true  = 先用 Windows API (EM_SETSEL, 约 1ms, 不弹菜单), 失败才退回右键菜单
; false = 只用右键菜单
;
; 2026-10-06 结论修正:
;   早先我判定"API 会让 Ctrl+C 失效"是**错的** —— 用户手动在探针里按 Ctrl+C
;   能正常复制到剪贴板, 证明 EM_SETSEL 的选区是可复制的, 焦点也没丢。
;   那批"没取到文本"的真实原因见下面 T_AFTER_ENTER 的注释:
;   回车后没等程序把下一个框填好, 而菜单那 500ms 一直在替我们等。
;   现在 T_AFTER_ENTER 已补上, 并且 CopyToClip 会用 WM_GETTEXTLENGTH 分清
;   "框本来就空"和"复制失败", 失败时还会退回菜单重试一次。
global USE_API_SELECT := true

; --- 取文本方式 ---
; true  = 优先用 WM_GETTEXT 直接读控件 (不用全选/不用 Ctrl+C/不弹菜单)
; false = 老路子: 右键菜单全选 + Ctrl+C
; 第一次读会自动交叉验证两种方式的结果, 写进日志; 不一致就以剪贴板为准。
global READ_BY_API_TEXT := true

; --- 慢动作调试 ---
; true = 每一步之后停 T_DEBUG_WAIT 毫秒, 右上角提示"刚才干了什么 + 现在有没有菜单开着"
; 2026-10-06 用它定位到了总病根(Alt 把程序带进菜单模式), 定位完已关闭。
global DEBUG_SLOW   := false
global T_DEBUG_WAIT := 5000

; --- 行为开关 ---
global MENU_KEY := "{AppsKey}"                        ; 菜单键; 不管用可换 "{F10}" 或 "+{F10}"
global TRANS_HOTKEY := "{RAlt down}{f down}{f up}{RAlt up}"   ; 翻译热键: 右Alt+F

; 翻译热键怎么发:
;   "step"   = 分步慢按 (推荐): RAlt按下 -> 等150ms -> F按下 -> 按住100ms
;              -> F松开 -> 等150ms -> RAlt松开
;   "string" = 一次 Send 把 TRANS_HOTKEY 连发出去 (键间隔只有 KEY_DELAY)
; STranslate 是 C# 写的, 多半用键盘钩子判断“按 F 的时候 Alt 在不在”。
; 一次连发的话钩子可能在系统把 Alt 标成按下之前就看到 F, 于是热键不触发
; —— 表现就是时好时坏, 而不像全没触发。
global TRANS_HOTKEY_MODE := "step"
global T_HOTKEY_HOLD_MOD := 150       ; RAlt 按下后, 等多久再按 F
global T_HOTKEY_HOLD_KEY := 100       ; F 按住多久
global T_HOTKEY_HOLD_AFTER := 150     ; F 松开后, 等多久再松 RAlt

; 按下热键后要是文本框一个字都没变, 判定“这次没翻译成功”, 重来几遍
global TRANS_RETRY := 1

; --- 翻译不响应时的止损 (列表里常有几十行内容相同, 不做止损会像"无限循环") ---
global SKIP_KNOWN_FAILED := true  ; 某个文本本会话里翻译失败过, 再遇到就跳过翻译只回车
global MAX_TRANS_FAILS   := 3     ; 连续这么多次翻译完全没反应就停下报警 (0 = 不检查)

; --- 脚本自己的热键 ---
; ⚠ 热键**不在这里**定义 —— 必须用静态定义, 见文件末尾「热键」段。
;   (动态 Hotkey() 注册踩过坑: 报 "Invalid callback function", 热键全废)

; --- 翻译器根本不处理的文本: 直接当"不需要翻译"跳过 ---
; 默认正则: 整串被一对尖括号包起来、里面没有别的尖括号 —— 比如
;   <Click on a list item to see a brief problem description here>
; 这类占位说明 STranslate 会**原样返回**, 脚本等满 12s 再重试 12s 也永远等不到变化,
; 每次遇到都白花 24 秒 (列表里几十行相同内容时看着就像无限循环)。
; 注意不要写成 ^<.*>$ —— 那会把 <strong>File</strong> 这种真该翻译的也跳过。
; 留空 = 不启用这个规则。
global SKIP_TRANS_PATTERN := "^<[^<>]*>$"

; 全选之后向控件核对选中范围 (EM_GETSEL)。
; ⚠ 默认 false: 实测这个控件**不上报真实选中范围** —— 旧版(240 次翻译成功那版)
;   日志里同样是 "选中 37..0 / 共 37 字符", 也就是无论选没选中都报成空。
;   所以它既不能用来判断全选是否生效, 报出来的"没全选"还会误导排查。
;   换别的程序用时可以打开试试; 打开后如果一直报 N..0, 就说明那控件也不支持。
global VERIFY_SELECTION := false

global SELECT_ALL_BEFORE_PASTE := true                ; 每次粘贴前先全选 (保证是“替换整段”而不是“插在光标处”)
global SHOW_STATUS := true                            ; 右上角显示 “运行中 #n”
global DEBUG_LOG   := true                            ; 写日志

; ========================== 下面是实现 =====================================

global running := false
global SCRIPT_VER := "2026-10-06r 关掉慢动作 + 轮询压到150ms (读文本走WM_GETTEXT免费)"
global API_SELECT_STATE := ""       ; ""=没定 / "yes"=在用API / "no"=已退回菜单
global LAST_SELECT_API := false     ; 最近一次全选是不是走 API
global apiFailStreak := 0           ; API 连续失败次数
global READ_VERIFIED := false       ; 读文本的交叉验证做过没有
global SEL_VERIFY_OFF := false      ; 控件不上报选中范围时, 自动关掉核对
global FAILED_TEXTS := Map()        ; 本会话翻译失败过的文本 (止损用)
global transFailStreak := 0         ; 连续失败计数
global ST_REPORT := ""
global LOG_FILE := A_ScriptDir "\ahk_translate_loop.log"
global SELFTEST_REPORT := A_ScriptDir "\ahk_translate_loop_selftest.txt"
global TMPDIR := A_Temp "\ahk_translate_loop"
global IN_TXT  := TMPDIR "\in.txt"
global OUT_TXT := TMPDIR "\out.txt"
global ERR_TXT := TMPDIR "\err.txt"

; 把 in.txt 的内容当成命令行参数交给目标脚本,
; 等价于 `python 目标脚本 "<text>"`, 但文本不经过任何 shell, 特殊字符原样保留。
;   sys.argv[1]=目标脚本  [2]=in.txt  [3]=out.txt  [4]=err.txt
;
; ⚠ 这段 python 代码里**只能用单引号**, 一个双引号都不能有 ——
;   命令行是靠双引号分参数的, 里面再出现双引号会把参数截断, python 会静默失败。
global PY_CODE := "import sys,runpy,os"
    . ";_t=open(sys.argv[2],encoding='utf-8').read()"
    . ";_t=_t[:-1] if _t.endswith('\n') else _t"
    . ";_o=open(sys.argv[3],'w',encoding='utf-8',newline='')"
    . ";_e=open(sys.argv[4],'w',encoding='utf-8',newline='')"
    . ";sys.stdout=_o;sys.stderr=_e"
    . ";sys.path.insert(0,os.path.dirname(os.path.abspath(sys.argv[1])))"
    . ";sys.argv=[sys.argv[1],_t]"
    . ";runpy.run_path(sys.argv[0],run_name='__main__')"

if !DirExist(TMPDIR)
    DirCreate(TMPDIR)

; ---- 同目录调用: python 和两个目标脚本都在脚本自己旁边 ----
if !FileExist(PYTHON) {
    LogLine("[路径] 配置的 python 不存在: " . PYTHON . "  -> 改用 PATH 里的 python")
    PYTHON := "python"
}
if !FileExist(PRE_SCRIPT)
    MsgBox("同目录里找不到 " . PRE_SCRIPT . "`n`n请把 ahk 和 4 个 py 放在同一个目录里。", "汉化循环 - 路径不对", "Icon!")
if !FileExist(POST_SCRIPT)
    MsgBox("同目录里找不到 " . POST_SCRIPT . "`n`n请把 ahk 和 4 个 py 放在同一个目录里。", "汉化循环 - 路径不对", "Icon!")
LogLine("[路径] 脚本目录=" . A_ScriptDir . "  python=" . PYTHON
    . "  前处理=" . PRE_SCRIPT . "  后处理=" . POST_SCRIPT)

; ---- 读 Windows 自己的时间参数, 定出“全选之后等多久” ----
global SYS_MENUSHOWDELAY  := GetSysParam(0x006A, 400)      ; SPI_GETMENUSHOWDELAY
global SYS_MESSAGETIMEOUT := GetSysParam(0x0028, 5000)     ; SPI_GETMESSAGETIMEOUT
global SYS_FGLOCKTIMEOUT  := GetSysParam(0x2000, 200000)   ; SPI_GETFOREGROUNDLOCKTIMEOUT
global SYS_KEYBOARDDELAY  := GetSysParam(0x0016, 1)        ; SPI_GETKEYBOARDDELAY (0..3)

if (SELECT_SETTLE_MODE = "system")
    T_AFTER_SELECTALL := SYS_MENUSHOWDELAY + SELECT_SETTLE_EXTRA
else
    T_AFTER_SELECTALL := SELECT_SETTLE_MODE + SELECT_SETTLE_EXTRA
T_FLUSH_TIMEOUT := SYS_MESSAGETIMEOUT

LogLine("===== 脚本版本 " . SCRIPT_VER . " =====")
LogLine("[系统参数] 菜单显示延迟(SPI_GETMENUSHOWDELAY)=" . SYS_MENUSHOWDELAY
    . "ms -> 全选后等待=" . T_AFTER_SELECTALL . "ms"
    . "  消息超时(SPI_GETMESSAGETIMEOUT)=" . SYS_MESSAGETIMEOUT
    . "ms -> 冲队列上限=" . T_FLUSH_TIMEOUT . "ms"
    . "  键盘延迟(SPI_GETKEYBOARDDELAY)=" . SYS_KEYBOARDDELAY
    . "  前台锁定(SPI_GETFOREGROUNDLOCKTIMEOUT)=" . SYS_FGLOCKTIMEOUT . "ms"
    . "  |  按翻译热键前的等待 = " . T_AFTER_SELECTALL . " + WM_NULL冲队列 + "
    . T_TRANS_PREPARE . "ms = 约 " . (T_AFTER_SELECTALL + T_TRANS_PREPARE) . "ms"
    . "  |  热键发法 = " . TRANS_HOTKEY_MODE
    . " (RAlt按住 " . T_HOTKEY_HOLD_MOD . "ms, F按住 " . T_HOTKEY_HOLD_KEY . "ms)"
    . "  全选核对 = " . (VERIFY_SELECTION ? "开" : "关")
    . "  没反应重试 = " . TRANS_RETRY . " 次"
    . "  |  自适应等待 = " . (ADAPTIVE_WAITS ? "开 (能确认就提前走, 上限不变)" : "关 (固定 Sleep)")
    . "  |  止损: 失败过的文本跳过 = " . (SKIP_KNOWN_FAILED ? "开" : "关")
    . ", 连续失败 " . (MAX_TRANS_FAILS > 0 ? MAX_TRANS_FAILS . " 次就停" : "不检查")
    . ", 跳过正则 = " . (SKIP_TRANS_PATTERN = "" ? "关" : SKIP_TRANS_PATTERN)
    . "  |  全选方式 = " . (USE_API_SELECT ? "Windows API (EM_SETSEL), 失败退回右键菜单" : "右键菜单")
    . "  |  脚本热键 = 开始 ^+s (Ctrl+Shift+S, 不含 Alt) / 探针 ^!+p"
    . "  |  等待: 取文本" . T_AFTER_COPY . "ms/剪贴板上限" . T_CLIP_WAIT
    . "ms/粘贴后" . T_AFTER_PASTE . "ms/回车后" . T_AFTER_ENTER
    . "ms/等译文" . T_TRANS_MAX . "ms(+稳定期" . T_TRANS_GRACE . "ms)")

SendMode(SEND_MODE)
SetKeyDelay(KEY_DELAY, KEY_DUR)

; 命令行带 --selftest: 只测 python 管线, 不碰任何窗口
if (A_Args.Length >= 1 && A_Args[1] = "--selftest")
    RunSelfTest()

; 启动时闪一下, 用来确认"新改的版本到底加载了没有"
; (AHK 不会自动重载 —— 改完文件必须重新运行脚本, 否则托盘里还是旧实例)
ShowStatus("已加载 " . SCRIPT_VER)
Sleep 1800
HideStatus()


; ============================== 主流程 =====================================

RunLoop() {
    global running, FAILED_TEXTS, transFailStreak
    if running
        return
    running := true
    LogLine("========== 开始 (Ctrl+Alt+S) ==========")
    ; 每次重新开始都清空止损记录 —— 万一你刚把 STranslate 修好了, 应该重新试
    FAILED_TEXTS := Map()
    transFailStreak := 0
    Sleep T_START_WAIT

    ; ★ 最关键的一步: 按 Ctrl+Alt+S 时, 系统只吞掉 S, Alt 会传给程序 ——
    ;   程序看到"单独按了一下 Alt"就进入菜单模式, 之后所有按键都被菜单吃掉。
    ;   所以开始循环的第一件事就是把菜单模式退掉。
    CancelMenuMode("开始循环(你按了 Ctrl+Alt+S)")

    n := 0
    iterStart := A_TickCount
    while running {
        n += 1
        ShowStatus("运行中 #" . n)
        if (n > 1)
            LogLine("---------- 第 " . n . " 个文本框 (上一轮共 " . Round((A_TickCount - iterStart) / 1000, 2) . "s) ----------")
        else
            LogLine("---------- 第 " . n . " 个文本框 ----------")
        iterStart := A_TickCount

        ; ---- 0. 每轮开始先确认没在菜单模式 (菜单模式下按键全废) ----
        CancelMenuMode("第 " . n . " 轮开始, 取文本之前")

        ; ---- 1. 取文本 ----
        t0 := A_TickCount
        src := SelectAllCopy()
        readMs := A_TickCount - t0
        if (src = "") {
            LogLine("没取到文本 (空文本框或复制失败) -> 直接回车   [取文本 " . readMs . "ms]")
            GoNextBox()
            continue
        }
        LogLine("原文: " . Repr(src) . "   [取文本 " . readMs . "ms, 焦点 " . FocusDesc() . "]")
        StepHint("1) 取文本完成: " . Repr(SubStr(src, 1, 30))
            . "`n  方式: " . (READ_BY_API_TEXT ? "WM_GETTEXT (不碰剪贴板)" : "菜单全选 + Ctrl+C"))

        ; ---- 2. translate.py ----
        t0 := A_TickCount
        err := "", pre := ""
        if (RunPy(PRE_SCRIPT, ToLf(src), &pre, &err) != 0) {
            StopWithError("translate.py 调用失败", err)
            return
        }
        pyMs := A_TickCount - t0
        lines := SplitLines(pre)
        if (lines.Length = 0) {
            StopWithError("translate.py 没有输出", "脚本: " . PRE_SCRIPT)
            return
        }
        need := (StrLower(Trim(lines[1], " `t`r`n")) = "true")
        body := (lines.Length >= 2) ? JoinLines(lines, 2) : ""
        LogLine("translate.py -> need=" . need . "  text=" . Repr(body) . "   [python " . pyMs . "ms]")
        StepHint("2) translate.py 跑完: need=" . need . ", 耗时 " . pyMs . "ms`n  (这步只跑 python, 不可能弹菜单)")

        ; ---- 止损 1: 翻译器根本不处理的文本 (比如整串 <...>), 直接跳过 ----
        ; 这类文本 STranslate 会原样返回, 等多久都不会变, 每次白花 12s+12s。
        if (need && SKIP_TRANS_PATTERN != "" && RegExMatch(body, SKIP_TRANS_PATTERN)) {
            LogLine("这个文本匹配 SKIP_TRANS_PATTERN (翻译器会原样返回) -> 跳过翻译, 直接回车")
            t0 := A_TickCount
            GoNextBox()
            LogLine("    [回车+等下一个框 " . (A_TickCount - t0) . "ms]")
            continue
        }

        ; ---- 止损 2: 这个文本本会话里翻译失败过, 别再花 12s+12s 重试一遍 ----
        ; 列表里常常有几十行内容一模一样 (比如同一个占位说明), 每行都重试一次的话
        ; 一条 30 秒, 几十行就是十几分钟, 看着就像"卡在这个框上无限循环"。
        if (need && SKIP_KNOWN_FAILED && FAILED_TEXTS.Has(src)) {
            LogLine("这个文本本会话里翻译失败过 -> 跳过翻译, 直接回车")
            t0 := A_TickCount
            GoNextBox()
            LogLine("    [回车+等下一个框 " . (A_TickCount - t0) . "ms]")
            continue
        }

        if need {
            ; ---- 3. 把预处理后的文本粘回去 ----
            t0 := A_TickCount
            PasteText(body)
            pasteMs := A_TickCount - t0
            StepHint("3) 粘贴预处理文本完成 (粘贴前的全选走的是 "
                . (LAST_SELECT_API ? "Windows API —— 不该弹菜单" : "右键菜单 —— 会弹菜单") . ")")

            ; ---- 4. 全选 + 右Alt+F 翻译 (没反应就重来) ----
            t0 := A_TickCount
            base := SelectAllCopy()          ; 顺便拿到“盒子里现在的规范文本”当基准
            baseMs := A_TickCount - t0
            if (base = "")
                base := body
            LogLine("翻译前基准: " . Repr(base) . "   [粘贴 " . pasteMs . "ms, 取基准 " . baseMs . "ms]")
            StepHint("4) 取基准完成: " . Repr(SubStr(base, 1, 30))
                . "`n  方式: " . (READ_BY_API_TEXT ? "WM_GETTEXT (不碰剪贴板)" : "菜单全选 + Ctrl+C"))

            attempt := 0
            translated := base
            while (attempt <= TRANS_RETRY && running) {
                attempt += 1
                ; 按翻译热键前重新全选 —— 上面那次全选离现在隔了几百毫秒 (中间还按了
                ; Ctrl+C), 不能让翻译工具拿到“可能已经丢掉”的选中状态。
                ; SelectAllVerified 里含: 系统菜单延迟 + WM_NULL 冲队列 + STranslate 准备,
                ; 并且会问控件“是不是真的全选了”, 没全选就重来。
                t0 := A_TickCount
                SelectAllVerified("右Alt+F" . (attempt > 1 ? " 第" . attempt . "次" : ""), T_TRANS_PREPARE)
                settleMs := A_TickCount - t0
                LogLine("按翻译热键 (第 " . attempt . " 次, " . TRANS_HOTKEY_MODE . " 模式)   [全选+确认 " . settleMs . "ms]")
                StepHint("5) 全选+确认完成 (走的是 " . (LAST_SELECT_API ? "Windows API" : "右键菜单")
                    . "), 马上要按【右Alt+F】")
                SendTransHotkey()

                ; 右Alt+F 里的 Alt+F 是"打开文件菜单"的标准加速键, 同样会把程序
                ; 带进菜单模式。先让慢动作提示显示"这一步有没有点开菜单", 再退出来。
                menuNow := InMenuMode()
                StepHint("5b) 刚按完【右Alt+F】`n  菜单模式: " . (menuNow ? "★ 是 —— 就是这一步点开的!" : "否"))
                CancelMenuMode("刚按完右Alt+F")

                ; ---- 5. 等译文出现 ----
                t0 := A_TickCount
                polls := 0
                translated := WaitTranslated(base, &polls)
                if (translated != base) {
                    LogLine("    [等译文 " . Round((A_TickCount - t0) / 1000, 2) . "s, 轮询 " . polls . " 次]")
                    break
                }

                ; 文本框一个字都没变 -> 这次翻译根本没发生
                LogLine("!! 文本框没有任何变化, 判定这次没翻译成功   [等了 " . Round((A_TickCount - t0) / 1000, 2) . "s, 轮询 " . polls . " 次]")
            }

            if (translated = base) {
                ; 记下这个文本, 后面再遇到就别再花 24 秒重试了
                FAILED_TEXTS[src] := true
                transFailStreak += 1
                LogLine("!! 重试 " . TRANS_RETRY . " 次仍无译文, 这次按原文继续 (可能 STranslate 没响应热键)"
                    . "   [本会话累计连续失败 " . transFailStreak . " 次]")
                if (MAX_TRANS_FAILS > 0 && transFailStreak >= MAX_TRANS_FAILS) {
                    StopWithError("翻译连续 " . transFailStreak . " 次完全没反应",
                        "文本框一个字都没变, 说明 STranslate 根本没在工作。`n`n"
                        . "先查: STranslate 是否在运行、右Alt+F 手动按有没有反应、"
                        . "前台锁定值 HKCU\Control Panel\Desktop\ForegroundLockTimeout。`n`n"
                        . "(不想让它停就把 MAX_TRANS_FAILS 改成 0)")
                    return
                }
            } else {
                transFailStreak := 0
            }
            LogLine("译文: " . Repr(translated))
            StepHint("6) 等译文结束: " . Repr(SubStr(translated, 1, 30)))

            ; ---- 6. translateposthtml.py ----
            t0 := A_TickCount
            err2 := "", post := ""
            if (RunPy(POST_SCRIPT, ToLf(translated), &post, &err2) != 0) {
                StopWithError("translateposthtml.py 调用失败", err2)
                return
            }
            post := Trim(post, "`r`n")
            LogLine("translateposthtml.py -> " . Repr(post) . "   [python " . (A_TickCount - t0) . "ms]")
            StepHint("7) translateposthtml.py 跑完: " . Repr(SubStr(post, 1, 30)) . "`n  (这步只跑 python)")

            ; ---- 7. 粘回去 + 回车 (PasteText 内部会先自己全选一次) ----
            t0 := A_TickCount
            PasteText(post)
            LogLine("    [粘回译文 " . (A_TickCount - t0) . "ms]")
            StepHint("8) 粘回译文完成 (粘贴前的全选走的是 "
                . (LAST_SELECT_API ? "Windows API —— 不该弹菜单" : "右键菜单 —— 会弹菜单") . ")")
        } else {
            LogLine("不需要翻译 -> 直接回车")
        }

        CancelMenuMode("回车之前")
        t0 := A_TickCount
        GoNextBox()
        LogLine("    [回车+等下一个框 " . (A_TickCount - t0) . "ms]")
        StepHint("9) 已按回车, 准备进下一个框`n  (然后回到第 1 步继续)")
    }

    HideStatus()
    LogLine("========== 已停止 (Esc) ==========")
}

StopLoop() {
    global running
    if running {
        running := false
        HideStatus()
        LogLine("收到 Esc, 正在停止...")
    }
}

StopWithError(title, detail) {
    global running
    ; 用户自己按了 Esc 导致的中断, 不算错误, 不弹窗
    if !running {
        LogLine("(Esc 中断) " . title . " >> " . detail)
        return
    }
    running := false
    HideStatus()
    LogLine("!! " . title . " >> " . detail)
    MsgBox(title . "`n`n" . detail . "`n`n(循环已停止, 详见同目录 ahk_translate_loop.log)", "汉化循环 - 出错", "Icon!")
}


; ============================== 按键动作 ===================================

; ============================================================================
;  全选
;
;  首选: Windows API —— 给焦点控件发 EM_SETSEL(0,-1), 标准 Edit 控件(含 VB6
;        文本框)会立刻全选。纯消息, 不弹菜单, 约 1ms。
;        (2026-10-06 由探针 Ctrl+Alt+P 目视确认: 确实整段高亮)
;
;  兜底: 右键菜单 -> a。API 发不出去(拿不到焦点/消息失败)时自动走这条。
;
;  ⚠ 这个控件的 EM_GETSEL 是常数桩(永远返回 "长度..0", 收起选中/全选/菜单全选
;    读数都一样), 所以**没法用 API 自动核对选中范围**。防线是:
;      · USE_API_SELECT 一键关掉, 立刻回到右键菜单那条已验证的路
;      · 翻译连续 MAX_TRANS_FAILS 次没反应会自动停下报警
;      · 日志里"文本框没有任何变化"会连续出现
; ============================================================================
SelectAll(forceMenu := false) {
    global MENU_KEY, T_MENU_OPEN, T_MENU_PICK, ADAPTIVE_WAITS, T_FLUSH_TIMEOUT
    global USE_API_SELECT, API_SELECT_STATE, LAST_SELECT_API, apiFailStreak

    t0 := A_TickCount
    LAST_SELECT_API := false

    if (!forceMenu && USE_API_SELECT && API_SELECT_STATE != "no") {
        why := ""
        if SelectAllByAPI(&why) {
            LAST_SELECT_API := true
            apiFailStreak := 0
            if (API_SELECT_STATE != "yes") {
                API_SELECT_STATE := "yes"
                LogLine("★ 全选改用 Windows API (EM_SETSEL): 不再弹右键菜单, 每次省约 500ms")
            }
            return A_TickCount - t0
        }
        apiFailStreak += 1
        LogLine("EM_SETSEL 全选没成 (" . why . ") -> 这次退回右键菜单  [连续 " . apiFailStreak . " 次]")
        if (apiFailStreak >= 3) {
            API_SELECT_STATE := "no"
            LogLine("!! EM_SETSEL 连续 3 次没成 -> 以后都退回右键菜单全选")
        }
    }

    ; ---- 兜底: 右键菜单 (已验证可用的那条路, 一个字都没改) ----
    Send(MENU_KEY)
    if ADAPTIVE_WAITS {
        WaitMenuState(true, T_MENU_OPEN)      ; 菜单一出现就走
        Send("a")
        WaitMenuState(false, T_MENU_PICK)     ; 菜单一消失就走
        hwnd := WinExist("A")                 ; 但"全选"可能还没执行完
        if hwnd
            FlushWindowQueue(hwnd, T_FLUSH_TIMEOUT)   ; 冲队列 = 确认它执行完了
    } else {
        Sleep T_MENU_OPEN
        Send("a")
        Sleep T_MENU_PICK
    }
    return A_TickCount - t0
}

; 用 Windows API 全选。成功返回 true (消息被控件处理了)。
; 注意: 没法核对选中范围(EM_GETSEL 是常数桩), 只能确认"消息发出去并被处理"。
SelectAllByAPI(&why) {
    why := ""
    hwnd := GetFocusHwnd()
    if !hwnd {
        why := "拿不到焦点控件"
        return false
    }
    res := 0
    ; EM_SETSEL 0x00B1, wParam=0 lParam=-1 = 全选
    if !SendMsgTimeout(hwnd, 0x00B1, 0, -1, 800, &res) {
        why := "EM_SETSEL 消息发送失败/超时"
        return false
    }
    return true
}

; 把当前焦点控件的选中范围读成一行字 (探针用)。
; ⚠ 这个控件是常数桩, 读数不随选中变化 —— 只当"控件答不答"用。
SelSignature(hwnd) {
    if !TryGetSel(hwnd, &s, &e, &n)
        return "(控件不响应 EM_GETSEL)"
    return s . ".." . e . " / 共 " . n . " 字符"
}

; ============================================================================
;  前台程序是不是正处在"菜单模式"?
;
;  用 GetGUIThreadInfo 的 flags 判断 (手册里的 GUI_INMENUMODE / GUI_POPUPMENUMODE):
;    · 菜单栏被 Alt 激活 (还没下拉)  -> GUI_INMENUMODE
;    · 下拉菜单正开着              -> 两个都置位
;
;  为什么要它: 翻译热键是"右Alt+F", 而 **Alt+F 在 Windows 里就是"打开文件菜单"的
;  标准加速键**。如果 STranslate 没把按键吞干净, 程序自己会进入菜单模式 ——
;  这时后续按键全被菜单吃掉, 用户也会看到菜单被点开 (文件菜单里正好有"关闭(C)")。
; ============================================================================
InMenuMode() {
    hwnd := WinExist("A")
    if !hwnd
        return false
    tid := DllCall("GetWindowThreadProcessId", "Ptr", hwnd, "Ptr", 0, "UInt")
    if !tid
        return false
    size := (A_PtrSize = 8) ? 72 : 48          ; sizeof(GUITHREADINFO)
    buf := Buffer(size, 0)
    NumPut("UInt", size, buf)                   ; cbSize
    if !DllCall("GetGUIThreadInfo", "UInt", tid, "Ptr", buf, "Int")
        return false
    flags := NumGet(buf, 4, "UInt")             ; cbSize 后面就是 flags
    return (flags & 0x00000004) || (flags & 0x00000010)
}

; 慢动作调试: 每步之后停一下, 显示"刚才干了什么"以及"现在有没有菜单开着"
StepHint(msg) {
    global DEBUG_SLOW, T_DEBUG_WAIT
    if !DEBUG_SLOW
        return
    ToolTip("【慢动作 " . (T_DEBUG_WAIT / 1000) . "s】" . msg
        . "`n当前菜单模式: " . (InMenuMode() ? "★★ 是 (菜单被点开了) ★★" : "否"), A_ScreenWidth - 800, 8)
    Sleep T_DEBUG_WAIT
    ToolTip()
}

; ============================================================================
;  退出"菜单模式" —— 2026-10-06 找到的总病根
;
;  任何**带 Alt 的热键**(我们自己的 Ctrl+Alt+S、翻译的 右Alt+F) 都会让程序进入
;  菜单模式: 注册热键时系统只吞掉字母键, **Alt 的按下/松开是原样传给程序的**,
;  程序看到"单独按了一下 Alt", Windows 就把菜单栏激活了。
;
;  进入菜单模式后, 之后所有按键都被菜单吃掉 —— 表现就是:
;    · 脚本注入的 Ctrl+C 复制不到东西 (手动按却可以, 因为那时菜单已被点掉)
;    · 时好时坏
;    · 你看到菜单栏弹出来 (里面正好有"关闭(C)")
;
;  所以: 每个关键动作前查一次, 在菜单模式里就发 Esc 退出来。
;  (Send 发出的键不会触发 AHK 自己的 Esc 停止热键, 所以安全)
; ============================================================================
CancelMenuMode(where) {
    if !InMenuMode()
        return false
    LogLine("!! [" . where . "] 程序正处于菜单模式 (被 Alt 带进去的) -> 发 Esc 退出")
    Send("{Esc}")
    Sleep 120
    stillIn := InMenuMode()
    LogLine("   -> " . (stillIn ? "Esc 之后【仍在】菜单模式!" : "已退出菜单模式"))
    return !stillIn
}

; 选中范围是不是"全选"?
; ⚠ 对本程序这个控件没用: 它的 EM_GETSEL 是常数桩 (永远返回 "长度..0"),
;   三种状态(收起选中/API全选/菜单全选)读数完全一样 —— 所以这个判定在本控件上
;   恒为真, 不能当核对依据。保留它只是为了换别的程序时还能用。
SelLooksFull(s, e, n) {
    if (n <= 0)
        return true                       ; 空文本框, 没什么可选
    return (s = 0 && e >= n) || (e = 0 && s >= n)
}

; ============================================================================
;  全选探针 (热键 ^!+p = Ctrl+Alt+Shift+P) —— 不用脚本测, 让你用眼睛看
;
;  用法: 鼠标点进目标文本框 -> 按 Ctrl+Alt+Shift+P -> 按浮窗提示一步步看
;
;  它做三步, 每步停下来让你看:
;    1) 按一下 → 把选中收起来         (高亮应该消失)
;    2) 发 EM_SETSEL 全选             (看整段高亮: 蓝色还是灰色?)
;    3) 右键菜单全选                  (再看一次: 颜色和第 2 步一样吗?)
;
;  怎么读结果 (Windows 的规矩):
;      有焦点时的选中高亮 = 蓝色
;      失去焦点后的选中高亮 = 灰色
;    · 第 2 步是灰色、第 3 步是蓝色  -> 你说的"API 之后脱离焦点"成立
;    · 两步颜色一样(都蓝)            -> 焦点没丢, 问题在别处
;    · 第 2 步根本没高亮             -> EM_SETSEL 没生效
;
;  只改选中范围, 不动文本。循环运行中不执行。
; ============================================================================
ProbeSelectAll() {
    global running, T_MENU_OPEN, T_MENU_PICK, MENU_KEY

    if running {
        ToolTip("循环运行中 —— 先按 Esc 停下, 再按 Ctrl+Alt+Shift+P 试探针", A_ScreenWidth - 520, 8)
        Sleep 1500
        ToolTip()
        return
    }

    hwnd := GetFocusHwnd()
    if !hwnd {
        ToolTip("没找到焦点控件 —— 先用鼠标点进目标程序的那个文本框", A_ScreenWidth - 520, 8)
        Sleep 1800
        ToolTip()
        return
    }

    ; ---- 第 1 步: 收起选中 (只动光标, 不改文本) ----
    Send("{Right}")
    ToolTip("探针 1/3: 已收起选中 —— 高亮应该没了`n2 秒后做第 2 步", A_ScreenWidth - 560, 8)
    Sleep 2000

    ; ---- 第 2 步: Windows API 全选 ----
    res := 0
    SendMsgTimeout(hwnd, 0x00B1, 0, -1, 800, &res)      ; EM_SETSEL(0,-1)
    ToolTip("探针 2/3: 已用【Windows API】全选`n请盯住文本框: 整段高亮是什么颜色?`n蓝色=有焦点 / 灰色=丢了焦点", A_ScreenWidth - 560, 8)
    Sleep 4000

    ; ---- 第 3 步: 右键菜单全选 (已知能复制的那种) ----
    Send(MENU_KEY)
    Sleep T_MENU_OPEN
    Send("a")
    Sleep T_MENU_PICK
    ToolTip("探针 3/3: 已用【右键菜单】全选`n再看一次: 颜色和第 2 步一样吗?`n(这一步是已知能复制的基准)", A_ScreenWidth - 560, 8)
    Sleep 4000
    ToolTip()

    LogLine("探针(目视) 依次执行: 收起选中 -> API全选 -> 菜单全选; 等你报告高亮颜色")
}


; 全选之后、按下一个键之前调用。三步:
;   1) 按系统自己的“菜单显示延迟”(SPI_GETMENUSHOWDELAY, 默认 400ms) 等一等
;   2) 发 WM_NULL 把目标窗口的消息队列冲干净 (等它真的处理完, 不是猜)
;   3) extra: 再等一小段, 留给目标程序之外的第三方工具 (STranslate) 准备
; 手动的右键菜单全选之后, 程序可能还要跑一小会儿才把选中状态落到控件上;
; 只 Sleep 一个数字是赌, 冲队列才是确认。而第三方工具连“确认”都做不到
; (它的状态我们看不见), 只能额外留时间。
SettleAfterSelectAll(what, extra := 0) {
    global T_AFTER_SELECTALL, USE_MESSAGE_FLUSH, T_FLUSH_TIMEOUT, LAST_SELECT_API

    ; 走 API 全选时: EM_SETSEL 是同步消息, 它返回就代表控件已经把选中设好了 ——
    ; 既不用等"菜单显示延迟"(根本没弹菜单), 也不用 WM_NULL 冲队列确认。
    ; 只剩 extra: 那是留给 STranslate 自己的准备时间, 跟选中无关。
    if LAST_SELECT_API {
        if (extra > 0)
            Sleep extra
        return true
    }

    Sleep T_AFTER_SELECTALL          ; 1) 系统菜单延迟

    if USE_MESSAGE_FLUSH {           ; 2) 冲队列, 确认文本框已处理完全选
        hwnd := WinExist("A")
        if !hwnd
            LogLine("拿不到前台窗口 (" . what . "), 只做了等待")
        else if !FlushWindowQueue(hwnd, T_FLUSH_TIMEOUT)
            LogLine("冲消息队列超时/失败 (" . what . "), 用的是纯等待")
    }

    if (extra > 0)                   ; 3) 第三方工具的准备时间
        Sleep extra

    return true
}

; 全选 + 等待 + (能核对就)核对该控件是不是真的全选了; 核对不过就重来。
; 有些控件不出全选效果 (菜单没打开、焦点跑掉、'a' 落进文本框变成字符),
; 光“等”是发现不了这种事的, 所以要问控件本身。
SelectAllVerified(what, extra := 0) {
    global VERIFY_SELECTION, SEL_VERIFY_OFF

    loop 2 {
        i := A_Index
        SelectAll()
        SettleAfterSelectAll(what, extra)

        if (!VERIFY_SELECTION || SEL_VERIFY_OFF)
            return true

        hwnd := GetFocusHwnd()
        if !hwnd {
            LogLine("全选核对(" . what . " 第" . i . "次): 拿不到焦点控件, 跳过核对")
            return true                      ; 核不了, 不折腾
        }
        if !TryGetSel(hwnd, &selStart, &selEnd, &selTotal) {
            LogLine("全选核对(" . what . " 第" . i . "次): 控件不响应 EM_GETSEL, 跳过核对")
            return true                      ; 非标准控件, 只能按原样走
        }
        LogLine("全选核对(" . what . " 第" . i . "次): 选中 " . selStart . ".." . selEnd
            . " / 共 " . selTotal . " 字符")

        if (selTotal <= 0)
            return true                      ; 空文本框, 没什么可选
        if (selStart = 0 && selEnd >= selTotal)
            return true                      ; 真的全选了

        LogLine("    ↑ 没有全选, 重来一次")
    }

    ; 重来还是不行 —— 多半是这个控件压根不上报选中范围, 别在它身上浪费时间
    SEL_VERIFY_OFF := true
    LogLine("!! 全选核对(" . what . "): 连续两次都不是全选, 判定该控件不上报选中范围, 以后不再核对")
    return false
}

; 按翻译热键。
;   "step"   分步慢按: 修饰键要“按住”足够久, 让 STranslate 的键盘钩子
;            能明确看到“按 F 的时候 RAlt 是按下状态”。
;   "string" 一次连发 (老行为, 快但容易被钩子漏掉)。
SendTransHotkey() {
    global TRANS_HOTKEY_MODE, TRANS_HOTKEY
    global T_HOTKEY_HOLD_MOD, T_HOTKEY_HOLD_KEY, T_HOTKEY_HOLD_AFTER

    if (TRANS_HOTKEY_MODE != "step") {
        Send(TRANS_HOTKEY)
        return
    }

    Send("{RAlt down}")
    Sleep T_HOTKEY_HOLD_MOD
    Send("{f down}")
    Sleep T_HOTKEY_HOLD_KEY
    Send("{f up}")
    Sleep T_HOTKEY_HOLD_AFTER
    Send("{RAlt up}")
}

; 取文本。优先用 WM_GETTEXT 直接读控件 —— 不用全选、不用 Ctrl+C、不弹菜单。
;
; 为什么改这条: 2026-10-06 日志证明"脚本注入的 Ctrl+C 拿不到内容" ——
;   同一个框(8 字符), API 全选后复制失败, 退回右键菜单全选后**还是失败**;
;   而用户手动按 Ctrl+C 就能复制到。既然全选是好的、坏的是 Ctrl+C,
;   那就绕开 Ctrl+C: 这个控件认 WM_GETTEXTLENGTH(诊断里"共 8 字符"就是它给的),
;   那它极可能也认 WM_GETTEXT。
;
; 第一次读会做一次交叉验证: 同时用"菜单全选+Ctrl+C"读一遍, 两个结果都写日志。
; 不一致就以剪贴板为准, 并记下不一致 —— 这样万一 WM_GETTEXT 给的文本不对, 能立刻发现。
SelectAllCopy() {
    global READ_BY_API_TEXT, READ_VERIFIED

    if READ_BY_API_TEXT {
        hwnd := GetFocusHwnd()
        if hwnd {
            txt := ""
            if TryReadControlText(hwnd, &txt) {

                ; ⚠ 菜单模式下焦点会被菜单栏抢走, 这时读到的是**菜单栏自己的文字**
                ;   ("Menu Bar", 正好 8 个字符), 不是文本框内容 —— 之前那些
                ;   "文本框里有 8 个字符却复制不出来" 就是这个。
                ;   发现就发 Esc 退出菜单模式, 再读一次。
                if (txt = "Menu Bar") {
                    LogLine("!! 焦点被菜单栏抢走了 (读到 'Menu Bar') -> 发 Esc 退出菜单模式后重读")
                    Send("{Esc}")
                    Sleep 200
                    hwnd2 := GetFocusHwnd()
                    txt2 := ""
                    if (hwnd2 && TryReadControlText(hwnd2, &txt2) && txt2 != "Menu Bar") {
                        LogLine("   -> 重读成功: " . Repr(SubStr(txt2, 1, 40)) . "  (焦点 " . FocusDesc() . ")")
                        txt := txt2
                    } else {
                        LogLine("   -> 重读还是不对 (焦点 " . FocusDesc() . "), 这次退回 全选+Ctrl+C")
                        return SelectAllCopyByClipboard()
                    }
                }

                if !READ_VERIFIED {
                    READ_VERIFIED := true
                    clip := SelectAllCopyByClipboard()
                    same := (txt = clip)
                    LogLine("读文本交叉验证: WM_GETTEXT=" . Repr(SubStr(txt, 1, 40))
                        . "   菜单+Ctrl+C=" . Repr(SubStr(clip, 1, 40))
                        . "   焦点=" . FocusDesc()
                        . (same ? "   【一致】" : "   【不一致! 本次以剪贴板为准】"))
                    if !same
                        return clip
                }
                return txt
            }
            LogLine("WM_GETTEXT 读不到 (焦点 " . FocusDesc() . ") -> 这次退回 全选+Ctrl+C")
        }
    }
    return SelectAllCopyByClipboard()
}

; 把当前焦点控件描述成一行字 (类名 + 前 20 个字), 排查"焦点跑哪去了"用
FocusDesc() {
    hwnd := GetFocusHwnd()
    if !hwnd
        return "(没有焦点控件)"
    cls := ""
    try cls := WinGetClass("ahk_id " . hwnd)
    txt := ""
    TryReadControlText(hwnd, &txt)
    return cls . " '" . SubStr(txt, 1, 20) . "'"
}

; 老路子: 全选 + Ctrl+C
SelectAllCopyByClipboard() {
    SelectAll()
    return CopyToClip()
}

; 直接问控件要文本 (WM_GETTEXT)。
; 返回 true 表示控件回答了 (空文本框也算回答, 此时 text 为空串)。
TryReadControlText(hwnd, &text) {
    text := ""
    len := 0
    if !SendMsgTimeout(hwnd, 0x000E, 0, 0, 800, &len)      ; WM_GETTEXTLENGTH
        return false
    if (len <= 0)
        return true                                        ; 空文本框
    buf := Buffer((len + 1) * 2, 0)
    res := 0
    if !SendMsgTimeout(hwnd, 0x000D, len + 1, buf.Ptr, 800, &res)   ; WM_GETTEXT
        return false
    text := StrGet(buf, "UTF-16")
    return true
}

; 复制一次: 清空剪贴板 -> Ctrl+C -> 等内容。成功返回 true
CopyOnce() {
    global T_AFTER_COPY, T_CLIP_WAIT
    try A_Clipboard := ""
    Send("^c")
    if !ClipWait(T_CLIP_WAIT / 1000, 0)
        return false
    Sleep T_AFTER_COPY
    return true
}

; 取文本。剪贴板空的时候要分清两种情况 ——
;   · 文本框本来就是空的      -> 正常, 该按回车进下一个框
;   · 框里有字却没复制到      -> 复制失败, 走 API 全选时退回右键菜单重试一次
; 判据用 WM_GETTEXTLENGTH 问控件 (这个控件认它, 探针里"共 N 字符"就是它给的)。
CopyToClip() {
    global LAST_SELECT_API

    if CopyOnce()
        return A_Clipboard

    hwnd := GetFocusHwnd()
    len := 0
    if (hwnd && SendMsgTimeout(hwnd, 0x000E, 0, 0, 500, &len) && len > 0) {
        LogLine("!! 复制失败: 文本框里有 " . len . " 个字符, 剪贴板却是空的"
            . (LAST_SELECT_API ? "  (这次全选走的是 API)" : "  (这次全选走的是右键菜单)"))
        if LAST_SELECT_API {
            LogLine("   -> 退回右键菜单全选, 重试一次")
            SelectAll(true)                  ; 强制走菜单
            if CopyOnce()
                return A_Clipboard
            LogLine("   -> 重试仍然失败")
        }
    } else {
        LogLine("文本框是空的 (WM_GETTEXTLENGTH=" . len . "), 不是复制失败")
    }
    return ""
}

PasteText(t) {
    global T_AFTER_PASTE, SELECT_ALL_BEFORE_PASTE
    A_Clipboard := ToCrLf(t)
    Sleep 60                       ; 先让剪贴板就位
    if SELECT_ALL_BEFORE_PASTE {
        ; 粘贴前重新全选: 上一次全选可能是几百毫秒甚至几十秒前的事
        ; (中间还夹着 translate.py), 那时候的选中状态早就不可靠了。
        ; 不全选就会插在光标处, 而不是替换整段。
        SelectAllVerified("Ctrl+V")
    }
    Send("^v")
    Sleep T_AFTER_PASTE
}

; 按完右Alt+F 后反复“全选+复制”, 一发现内容和基准不一样、且连续两次一样, 就认为翻译好了
; 返回 (文本, 轮询次数)。轮询次数 + 是否变化 是判断"STranslate 到底动没动"的关键证据。
WaitTranslated(baseline, &polls) {
    global running, WAIT_MODE, T_TRANS_FIXED, T_TRANS_WAIT, T_TRANS_POLL, T_TRANS_MAX, T_TRANS_GRACE
    global LOG_POLLS

    polls := 0
    if (WAIT_MODE = "fixed") {
        Sleep T_TRANS_FIXED
        cur := SelectAllCopy()
        polls := 1
        return (cur != "") ? cur : baseline
    }

    Sleep T_TRANS_WAIT
    prev := baseline
    changed := false
    deadline := A_TickCount + T_TRANS_MAX                 ; 等"第一次变化"的上限
    hardDeadline := deadline + T_TRANS_GRACE              ; 已经看到变化后, 再给点时间确认稳定
    while running {
        cur := SelectAllCopy()
        polls += 1
        if LOG_POLLS
            LogLine("    轮询#" . polls . ": " . Repr(SubStr(cur, 1, 40)))
        if (cur != "") {
            if changed {
                if (cur = prev) {
                    LogLine("译文已稳定 (轮询 " . polls . " 次)")
                    return cur
                }
                prev := cur
            } else if (cur != baseline) {
                LogLine("    第 " . polls . " 次轮询看到内容变了")
                changed := true
                prev := cur
            }
        }
        ; 没看到变化 -> 到 T_TRANS_MAX 就放弃 (不干等)
        ; 已经看到变化 -> 用更宽的 hardDeadline, 免得刚好卡边界的译文被丢掉后又被原文覆盖
        if (A_TickCount > (changed ? hardDeadline : deadline)) {
            LogLine("等译文超时(" . T_TRANS_MAX . "ms" . (changed ? " + 稳定期 " . T_TRANS_GRACE . "ms" : "")
                . "), 轮询了 " . polls . " 次, 内容"
                . (changed ? "变过但没稳定" : "一次都没变") . " -> 判定 STranslate 没反应")
            return prev
        }
        Sleep T_TRANS_POLL
    }
    return prev
}


; ============================== python 调用 ================================

; 跑目标脚本。成功返回 0, 失败返回 -1, 并把输出/错误写进 outText / errText。
RunPy(scriptPath, text, &outText, &errText) {
    global running, PYTHON, PY_CODE, IN_TXT, OUT_TXT, ERR_TXT, T_PY_MAX
    outText := "", errText := ""

    SplitPath(scriptPath, , &scriptDir)
    if !DirExist(scriptDir) {
        errText := "目录不存在: " . scriptDir
        return -1
    }

    ; 写输入 (UTF-8 无 BOM)
    try {
        if FileExist(IN_TXT)
            FileDelete(IN_TXT)
        f := FileOpen(IN_TXT, "w", "UTF-8-RAW")
        f.Write(text)
        f.Close()
    } catch as e {
        errText := "写 " . IN_TXT . " 失败: " . e.Message
        return -1
    }
    try FileDelete(OUT_TXT)
    try FileDelete(ERR_TXT)

    ; -B: 不写 __pycache__ (别在目录里留垃圾); -X utf8: 管道输出也用 UTF-8
    cmd := '"' . PYTHON . '" -B -X utf8 -c "' . PY_CODE . '" "'
        . scriptPath . '" "' . IN_TXT . '" "' . OUT_TXT . '" "' . ERR_TXT . '"'
    pid := 0
    try {
        Run(cmd, scriptDir, "Hide", &pid)     ; ⚠ v2: PID 只能从第4个参数拿, Run 的返回值是空的
    } catch as e {
        errText := "启动 python 失败: " . e.Message . "`n`npython: " . PYTHON . "`n" . cmd
        return -1
    }
    if (pid = 0) {
        errText := "python 没被启动 (PID=0)。`n`n命令:`n" . cmd
        return -1
    }

    start := A_TickCount
    while ProcessExist(pid) {
        if !running {
            try ProcessClose(pid)
            errText := "已按 Esc, 中止本次调用"
            return -1
        }
        if (A_TickCount - start > T_PY_MAX) {
            try ProcessClose(pid)
            errText := "python 超过 " . T_PY_MAX . "ms 没结束, 已强杀"
            return -1
        }
        Sleep 50
    }

    madeOut := (FileExist(OUT_TXT) != "")
    madeErr := (FileExist(ERR_TXT) != "")
    if (!madeOut && !madeErr) {
        errText := "python 没有产出任何文件, 命令行可能没被正确解析。`n`n命令:`n" . cmd
        return -1
    }
    outText := madeOut ? FileRead(OUT_TXT, "UTF-8") : ""
    errText := madeErr ? FileRead(ERR_TXT, "UTF-8") : ""
    if (Trim(outText, "`r`n") = "" && Trim(errText, "`r`n") != "")
        return -1
    return 0
}


; ============================== Win32 ======================================

; 读一个系统参数 (SystemParametersInfoW, 值按 DWORD 取)。
; 手册: https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-systemparametersinfoa
GetSysParam(action, default) {
    v := 0
    try {
        ok := DllCall("user32\SystemParametersInfoW"
            , "UInt", action          ; uiAction
            , "UInt", 0               ; uiParam
            , "UInt*", &v             ; pvParam (DWORD)
            , "UInt", 0               ; fWinIni
            , "Int")                  ; 返回 BOOL
        if ok
            return v
    }
    return default
}

; 给窗口发一条消息并等它被处理完 (带超时, 不卡死脚本)。
; 手册 SendMessageTimeout: 跨线程时“函数不会返回, 直到窗口过程处理完这条消息”;
; fuFlags = SMTO_BLOCK(0x1) | SMTO_ABORTIFHUNG(0x2); 返回值非零 = 成功。
; res 拿回消息处理结果 (lpdwResult)。
SendMsgTimeout(hwnd, msg, wp, lp, timeout, &res) {
    res := 0
    try {
        r := DllCall("user32\SendMessageTimeoutW"
            , "Ptr", hwnd             ; hWnd
            , "UInt", msg             ; Msg
            , "Ptr", wp               ; wParam
            , "Ptr", lp               ; lParam
            , "UInt", 0x0003          ; fuFlags = SMTO_BLOCK | SMTO_ABORTIFHUNG
            , "UInt", timeout         ; uTimeout
            , "Ptr*", &res            ; lpdwResult
            , "Ptr")                  ; 返回 LRESULT (0 = 失败/超时)
        return (r != 0)
    }
    return false
}

; 冲消息队列: 给窗口发一条 WM_NULL 并等它被处理完。
;   手册 WM_NULL: “申请确认某条消息已被处理时, 应用程序发送 WM_NULL”
;   它返回就意味着: 之前排进该线程队列的按键消息都已处理完。
; 返回 true=冲干净了 / false=超时或失败 (对方卡住), 调用方退化成纯等待。
FlushWindowQueue(hwnd, timeout) {
    res := 0
    return SendMsgTimeout(hwnd, 0x0000, 0, 0, timeout, &res)
}

; 问控件: 现在选中的是哪一段? (标准 Edit/RichEdit 才有答案)
;   WM_GETTEXTLENGTH  0x000E -> 总长度
;   EM_GETSEL         0x00B0 -> 低16位=起点, 高16位=终点 (终点是“最后一个字符之后”)
; 这两个消息都在 0..WM_USER 范围内, 系统会自动跨进程编组, 所以能问到别的程序。
; 返回 true 表示控件回答了 (此时 start/end/total 有效); false 表示问不出来。
TryGetSel(hwnd, &start, &end, &total) {
    start := -1, end := -1, total := -1
    res := 0
    if !SendMsgTimeout(hwnd, 0x000E, 0, 0, 800, &res)
        return false
    total := res
    if !SendMsgTimeout(hwnd, 0x00B0, 0, 0, 800, &res)
        return false
    start := res & 0xFFFF
    end := (res >> 16) & 0xFFFF
    return true
}

; 当前焦点控件的 HWND (0 = 没有)
GetFocusHwnd() {
    ctl := ControlGetFocus("A")
    if (ctl = "")
        return 0
    try
        return ControlGetHwnd(ctl, "A")
    return 0
}

; 右键菜单是不是正开着?
; 标准 Win32 右键菜单的窗口类是 #32768; 只看属于当前前台程序那个进程的,
; 免得被别的程序残留的菜单骗到。
MenuIsUp() {
    hwnd := WinExist("ahk_class #32768")
    if !hwnd
        return false
    try {
        return (WinGetPID(hwnd) = WinGetPID("A"))
    }
    return false
}

; 等菜单出现(want=true)/消失(want=false), 最多 cap 毫秒。
; 等不到就等满 cap —— 所以最坏情况和优化前的固定 Sleep 完全一样。
WaitMenuState(want, cap) {
    t0 := A_TickCount
    while (A_TickCount - t0 < cap) {
        if (MenuIsUp() = want)
            break
        Sleep 10
    }
    return A_TickCount - t0
}

; 回车之后等“焦点换到下一个控件”。连续两次探到同一个新控件才算数,
; 免得被切换过程中的瞬时焦点骗到。等不到就等满 cap。
WaitNextBox(prevHwnd, cap) {
    t0 := A_TickCount
    seen := 0
    while (A_TickCount - t0 < cap) {
        Sleep 25
        cur := GetFocusHwnd()
        if (cur && cur != prevHwnd) {
            if (cur = seen)
                break
            seen := cur
        } else {
            seen := 0
        }
    }
    return A_TickCount - t0
}

; 回车进下一个文本框 (返回实际等了多久)
GoNextBox() {
    global T_AFTER_ENTER, ADAPTIVE_WAITS
    before := ADAPTIVE_WAITS ? GetFocusHwnd() : 0
    Send("{Enter}")
    if ADAPTIVE_WAITS
        return WaitNextBox(before, T_AFTER_ENTER)
    Sleep T_AFTER_ENTER
    return T_AFTER_ENTER
}


; ============================== 小工具 =====================================

; ⚠ 注意: 函数名不能和任何局部变量重名 (v2 里同名会让调用变成“调用变量”)。
;    所以这里叫 SplitLines, 而不是 Lines —— RunLoop 里有局部变量 lines。
SplitLines(text) {
    t := Trim(text, "`r`n")
    if (t = "")
        return []
    return StrSplit(t, "`n", "`r")
}

JoinLines(arr, start := 1) {
    s := ""
    i := start
    while (i <= arr.Length) {
        if (i > start)
            s .= "`n"
        s .= arr[i]
        i += 1
    }
    return s
}

ToLf(t) {
    t := StrReplace(t, "`r`n", "`n")
    return StrReplace(t, "`r", "`n")
}

ToCrLf(t) {
    t := ToLf(t)
    return StrReplace(t, "`n", "`r`n")
}

Repr(s) {
    r := StrReplace(s, "`r", "\r")
    r := StrReplace(r, "`n", "\n")
    r := StrReplace(r, "`t", "\t")
    return '"' . r . '"'
}

LogLine(msg) {
    global DEBUG_LOG, LOG_FILE
    if !DEBUG_LOG
        return
    try FileAppend(FormatTime(A_Now, "HH:mm:ss") . "  " . msg . "`r`n", LOG_FILE, "UTF-8")
}

ShowStatus(t) {
    global SHOW_STATUS
    if SHOW_STATUS
        ToolTip(t, A_ScreenWidth - 240, 8)
}
HideStatus() {
    ToolTip()
}


; ============================== 自检 =======================================

RunSelfTest() {
    global running, ST_REPORT
    running := true
    ST_REPORT := ""
    bad := 0

    Say("=== AHK <-> python 管线自检 ===")
    Say("python : " . PYTHON)
    Say("")

    ; ---- 回归检查: 局部变量 lines + 函数 SplitLines 不能撞名 ----
    ; (老 bug: 函数叫 Lines, RunLoop 里有局部变量 lines, AHK v2 会把 Lines(pre)
    ;  当成“调用变量 lines”, 报 "This local variable has not been assigned a value")
    lines := SplitLines("true`nhello")
    okReg := (lines.Length = 2 && lines[1] = "true" && lines[2] = "hello")
    Say((okReg ? "[通过] " : "[不符] ") . "回归检查: 局部变量 lines 与 SplitLines() 共存")
    if !okReg
        bad += 1

    ; ---- 回归检查: Send 用到的键名必须合法 ----
    ; (键名写错时 Send 会抛运行时错误, 直接弹窗中断)
    badKeys := ""
    for k in ["AppsKey", "RAlt", "LAlt", "f", "a", "c", "v", "Enter", "F10"]
        if (GetKeyName(k) = "")
            badKeys .= k . " "
    okKey := (badKeys = "")
    Say((okKey ? "[通过] " : "[不符] ") . "回归检查: 键名合法 (" . MENU_KEY . " / " . TRANS_HOTKEY . ")")
    if !okKey {
        Say("        非法键名: " . badKeys)
        bad += 1
    }

    ; ---- 自适应等待的 helper 不能抛异常 (跑起来才炸是最糟的) ----
    okAd := true
    try {
        m := MenuIsUp()                          ; 现在没开菜单, 应为 false
        w := WaitMenuState(true, 60)             ; 等不到就等满 60ms
        f := GetFocusHwnd()                      ; 0 或某个 HWND 都正常
        w2 := WaitNextBox(f, 60)
        okAd := (m = false || m = true) && (w >= 55) && (w2 >= 55)
    } catch as e {
        okAd := false
        Say("        抛异常: " . e.Message)
    }
    Say((okAd ? "[通过] " : "[不符] ") . "回归检查: 自适应等待 helper (MenuIsUp / WaitMenuState / WaitNextBox)")
    if !okAd
        bad += 1

    ; ---- SKIP_TRANS_PATTERN 必须能编译, 且不能误伤该翻译的文本 ----
    okPat := true
    try {
        if (SKIP_TRANS_PATTERN != "") {
            hitSkip := RegExMatch("<Click on a list item to see a brief problem description here>", SKIP_TRANS_PATTERN)
            hitKeep1 := RegExMatch("<strong>File</strong>", SKIP_TRANS_PATTERN)   ; 该翻译, 不能跳
            hitKeep2 := RegExMatch("普通文本", SKIP_TRANS_PATTERN)               ; 不该跳
            okPat := (hitSkip != 0) && (hitKeep1 = 0) && (hitKeep2 = 0)
            Say((okPat ? "[通过] " : "[不符] ") . "回归检查: 跳过正则 " . SKIP_TRANS_PATTERN
                . "  (跳过 <...> = " . (hitSkip ? "是" : "否")
                . ", 跳过 <strong>File</strong> = " . (hitKeep1 ? "是(错!)" : "否") . ")")
        } else {
            Say("[通过] 跳过正则: 未启用")
        }
    } catch as e {
        okPat := false
        Say("[不符] 跳过正则无法编译: " . e.Message)
    }
    if !okPat
        bad += 1

    ; ---- 全选判定逻辑 (换别的程序时用; 本控件 EM_GETSEL 是常数桩, 判定恒为真) ----
    okSel := SelLooksFull(0, 37, 37) && SelLooksFull(37, 0, 37)      ; 正向/反向全选都算
        && !SelLooksFull(37, 37, 37) && !SelLooksFull(0, 0, 37)       ; 空选中不算
        && SelLooksFull(0, 0, 0)                                      ; 空文本框算
    Say((okSel ? "[通过] " : "[不符] ") . "回归检查: 全选判定函数 (本控件读数是常数, 只作兜底)")
    if !okSel
        bad += 1

    ; ---- 回归检查: Hotkey() 动态注册 (本脚本不用, 但要知道怎么写) ----
    ; 2026-10-06 实测 (AHK 2.0.29): 命名函数引用**传不进去**
    ;   Hotkey(key, 裸函数名)      -> Invalid callback function
    ;   Hotkey(key, 变量持函数引用) -> Invalid callback function
    ;   Hotkey(key, Func("名字"))  -> Invalid base
    ;   Hotkey(key, "名字")        -> Parameter #2 of Hotkey is invalid
    ;   Hotkey(key, (*) => ...)    -> OK   ← 只有匿名箭头函数能用
    ; 曾经因为用动态注册, 两个热键全没注册上、按下去毫无反应。
    ; 所以本脚本的热键一律用**静态定义** (^!s:: 这种, 加载时就校验)。
    okHk := true
    try {
        Hotkey("^!+F11", (*) => 0)     ; 唯一可用的写法
    } catch as e {
        okHk := false
        Say("        Hotkey() 注册失败: " . e.Message)
    }
    Say((okHk ? "[通过] " : "[不符] ") . "回归检查: Hotkey() 只接受匿名箭头函数 (热键用静态定义)")
    if !okHk
        bad += 1

    ; ---- 探针用的 helper 不能抛异常 ----
    okProbe := true
    try {
        sig := SelSignature(A_ScriptHwnd)      ; 自家窗口, 读不到也该返回字符串
        okProbe := (sig != "")
    } catch as e {
        okProbe := false
        Say("        抛异常: " . e.Message)
    }
    Say((okProbe ? "[通过] " : "[不符] ") . "回归检查: 探针 helper (SelSignature)")
    if !okProbe
        bad += 1

    ; ---- 系统时间参数 (SystemParametersInfo) ----
    Say("系统时间参数:")
    Say("  SPI_GETMENUSHOWDELAY        = " . SYS_MENUSHOWDELAY . " ms  -> 全选之后等待 " . T_AFTER_SELECTALL . " ms")
    Say("  SPI_GETMESSAGETIMEOUT       = " . SYS_MESSAGETIMEOUT . " ms  -> 冲队列上限 " . T_FLUSH_TIMEOUT . " ms")
    Say("  SPI_GETKEYBOARDDELAY        = " . SYS_KEYBOARDDELAY . "  (0..3)")
    Say("  SPI_GETFOREGROUNDLOCKTIMEOUT= " . SYS_FGLOCKTIMEOUT . " ms")
    Say("  按翻译热键前的总等待        = " . T_AFTER_SELECTALL . " ms (系统菜单延迟) + WM_NULL 冲队列 + "
        . T_TRANS_PREPARE . " ms (STranslate 准备) = 约 " . (T_AFTER_SELECTALL + T_TRANS_PREPARE) . " ms")
    okSys := (SYS_MENUSHOWDELAY > 0 && T_AFTER_SELECTALL > 0)
    Say((okSys ? "[通过] " : "[不符] ") . "回归检查: SystemParametersInfo 读得到系统时间参数")
    if !okSys
        bad += 1

    ; ---- 翻译热键的配置 ----
    Say("翻译热键: " . TRANS_HOTKEY_MODE . " 模式  (RAlt 按住 " . T_HOTKEY_HOLD_MOD
        . " ms -> F 按住 " . T_HOTKEY_HOLD_KEY . " ms -> RAlt 松开前再等 " . T_HOTKEY_HOLD_AFTER . " ms)")
    Say("  没翻译成时重试 " . TRANS_RETRY . " 次;  全选核对 = " . (VERIFY_SELECTION ? "开" : "关")
        . ";  自适应等待 = " . (ADAPTIVE_WAITS ? "开" : "关 (固定 Sleep, 已验证可用)"))

    ; ---- SendMessageTimeout 通用封装 (WM_GETTEXTLENGTH 问自己) ----
    dummy := 0
    okMsg := SendMsgTimeout(A_ScriptHwnd, 0x000E, 0, 0, 1000, &dummy)
    Say((okMsg ? "[通过] " : "[不符] ") . "回归检查: SendMessageTimeout 通用封装可用")
    if !okMsg
        bad += 1

    ; ---- 冲消息队列的 DllCall 能不能用 (拿自己的脚本窗口试) ----
    okFlush := FlushWindowQueue(A_ScriptHwnd, 2000)
    Say((okFlush ? "[通过] " : "[不符] ") . "回归检查: SendMessageTimeout(WM_NULL) 可用")
    if !okFlush
        bad += 1

    ; (脚本, 输入, 期望第1行, 期望文本)
    cases := [
        [PRE_SCRIPT,  "书签已删除。",                          "false", "书签已删除。"],
        [PRE_SCRIPT,  "Invalid file name",                     "true",  "Invalid file name"],
        [PRE_SCRIPT,  "Check out the \b&entire \bproject",     "true",  "Check out the <strong>entire</strong> <strong>project</strong>"],
        [PRE_SCRIPT,  "\ulUnderlined text",                    "false", "\ulUnderlined text"],
        [POST_SCRIPT, "<strong>只有</strong>大家都帮助他，他<strong>才会成功</strong>", "", "\b只有 大家都帮助他，他\b才会成功 "],
        [POST_SCRIPT, "普通文本",                              "",     "普通文本"],
        [POST_SCRIPT, "50% of " . Chr(34) . "C:\path\" . Chr(34) . " & <tag> 100%", "", "50% of " . Chr(34) . "C:\path\" . Chr(34) . " & <tag> 100%"],
        [POST_SCRIPT, "第一行`n第二行",                         "",     "第一行`n第二行"]
    ]

    for c in cases {
        script := c[1], input := c[2], want1 := c[3], want2 := c[4]
        out := "", err := ""
        rc := RunPy(script, ToLf(input), &out, &err)
        name := (script = PRE_SCRIPT) ? "translate.py" : "translateposthtml.py"
        if (rc != 0) {
            bad += 1
            Say("[失败] " . name . "  " . Repr(input))
            Say("        错误: " . StrReplace(Trim(err, "`r`n"), "`n", " | "))
            continue
        }
        if (script = PRE_SCRIPT) {
            ls := SplitLines(out)
            got1 := (ls.Length >= 1) ? StrLower(Trim(ls[1], " `t`r`n")) : ""
            got2 := (ls.Length >= 2) ? JoinLines(ls, 2) : ""
            ok := (got1 = want1 && got2 = want2)
            Say((ok ? "[通过] " : "[不符] ") . name . "  " . Repr(input))
            Say("        第一行: " . got1 . "  (期望 " . want1 . ")")
            Say("        文  本: " . Repr(got2))
            if !ok
                Say("        期  望: " . Repr(want2))
            bad += !ok
        } else {
            got := Trim(out, "`r`n")
            ok := (got = want2)
            Say((ok ? "[通过] " : "[不符] ") . name . "  " . Repr(input))
            Say("        输  出: " . Repr(got))
            if !ok
                Say("        期  望: " . Repr(want2))
            bad += !ok
        }
    }

    Say("")
    Say(bad ? ("自检失败: " . bad . " 项不符") : "自检全部通过")

    try {
        if FileExist(SELFTEST_REPORT)
            FileDelete(SELFTEST_REPORT)
        FileAppend(ST_REPORT, SELFTEST_REPORT, "UTF-8")
    }
    ExitApp(bad ? 1 : 0)
}

; 自检输出: 一边攒进 ST_REPORT, 一边打到 stdout
Say(s) {
    global ST_REPORT
    ST_REPORT .= s . "`r`n"
    try FileAppend(s . "`n", "*")
}


; ============================== 热键 =======================================
; ⚠ 这里必须用**静态定义** (^+s:: 这种), 不能用 Hotkey() 动态注册 ——
;   2026-10-06 踩过: 动态注册时把函数引用塞进数组传, AHK 报
;   "Invalid callback function", 两个热键全没注册上, 按下去毫无反应。
;   静态定义还有个好处: 写错了在**加载时**就报错(自检能发现), 不会等到运行时。
;
; ⚠⚠ **开始热键里绝对不能有 Alt** (这就是折腾了一整天的总病根):
;   注册热键时系统只吞掉字母键, **Alt 的按下/松开会原样传给程序** ——
;   程序看到"单独按了一下 Alt", Windows 就把菜单栏激活(进入菜单模式),
;   焦点被菜单栏抢走, 之后脚本发的 Ctrl+C / 回车 / 全选全被菜单吃掉:
;     · 取文本读到的其实是菜单栏自己的文字 "Menu Bar"(正好 8 个字符)
;     · EM_SETSEL 打在菜单栏上, Ctrl+C 复制不出东西
;     · 时好时坏, 而且你怎么查"全选"都查不出问题
;   所以开始热键用 Ctrl+Shift+S (不含 Alt)。
;
; 语法: ^=Ctrl !=Alt +=Shift #=Win

^+s::RunLoop()              ; 开始 / 停止循环 (Ctrl+Shift+S, 特意不带 Alt)
^!+p::ProbeSelectAll()      ; 全选探针 (Ctrl+Alt+Shift+P)

#HotIf running
Esc::StopLoop()
#HotIf
