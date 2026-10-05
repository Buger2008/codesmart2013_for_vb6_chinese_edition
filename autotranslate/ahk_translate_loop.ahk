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

; --- 各种等待时间 (ms), 卡壳了就调大 ---
global T_MENU_OPEN   := 300       ; 按下右键菜单键后, 等菜单弹出来
global T_MENU_PICK   := 200       ; 按 a 选“全选”后
global T_AFTER_COPY  := 150       ; Ctrl+C 之后
global T_CLIP_WAIT   := 2000      ; 等剪贴板出现内容的上限; 空文本框会白等这么久
global T_AFTER_PASTE := 150       ; Ctrl+V 之后
global T_AFTER_ENTER := 400       ; 回车进下一个文本框后
global T_START_WAIT  := 350       ; 按下 Ctrl+Alt+S 后, 等你松开手

; --- 翻译等待 ---
; WAIT_MODE = "poll"  : 反复“全选+复制”看文本变了没, 一变就继续 (快, 默认)
; WAIT_MODE = "fixed" : 死等 T_TRANS_FIXED 毫秒再一次拿结果 (翻译工具怕打扰时用这个)
global WAIT_MODE     := "poll"
global T_TRANS_FIXED := 3000      ; fixed 模式死等多久
global T_TRANS_WAIT  := 1200      ; 按完右Alt+F 先干等这么久再开始看
global T_TRANS_POLL  := 500       ; 之后每隔多久看一次译文出没出来
global T_TRANS_MAX   := 12000     ; 最多等这么久; 一发现译文变了就立刻继续, 不会白等
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

; 全选之后向控件核对选中范围 (EM_GETSEL)。能用就核对+重试, 用不了就跳过
global VERIFY_SELECTION := true

global SELECT_ALL_BEFORE_PASTE := true                ; 每次粘贴前先全选 (保证是“替换整段”而不是“插在光标处”)
global SHOW_STATUS := true                            ; 右上角显示 “运行中 #n”
global DEBUG_LOG   := true                            ; 写日志

; ========================== 下面是实现 =====================================

global running := false
global SEL_VERIFY_OFF := false      ; 控件不上报选中范围时, 自动关掉核对
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
    . "  没反应重试 = " . TRANS_RETRY . " 次")

SendMode(SEND_MODE)
SetKeyDelay(KEY_DELAY, KEY_DUR)

; 命令行带 --selftest: 只测 python 管线, 不碰任何窗口
if (A_Args.Length >= 1 && A_Args[1] = "--selftest")
    RunSelfTest()


; ============================== 主流程 =====================================

RunLoop() {
    global running
    if running
        return
    running := true
    LogLine("========== 开始 (Ctrl+Alt+S) ==========")
    Sleep T_START_WAIT

    n := 0
    while running {
        n += 1
        ShowStatus("运行中 #" . n)
        LogLine("---------- 第 " . n . " 个文本框 ----------")

        ; ---- 1. 右键菜单全选 + 复制, 取原文 ----
        src := SelectAllCopy()
        if (src = "") {
            LogLine("没取到文本 (空文本框或复制失败) -> 直接回车")
            Send("{Enter}")
            Sleep T_AFTER_ENTER
            continue
        }
        LogLine("原文: " . Repr(src))

        ; ---- 2. translate.py ----
        err := "", pre := ""
        if (RunPy(PRE_SCRIPT, ToLf(src), &pre, &err) != 0) {
            StopWithError("translate.py 调用失败", err)
            return
        }
        lines := SplitLines(pre)
        if (lines.Length = 0) {
            StopWithError("translate.py 没有输出", "脚本: " . PRE_SCRIPT)
            return
        }
        need := (StrLower(Trim(lines[1], " `t`r`n")) = "true")
        body := (lines.Length >= 2) ? JoinLines(lines, 2) : ""
        LogLine("translate.py -> need=" . need . "  text=" . Repr(body))

        if need {
            ; ---- 3. 把预处理后的文本粘回去 ----
            PasteText(body)

            ; ---- 4. 全选 + 右Alt+F 翻译 (没反应就重来) ----
            base := SelectAllCopy()          ; 顺便拿到“盒子里现在的规范文本”当基准
            if (base = "")
                base := body
            LogLine("翻译前基准: " . Repr(base))

            attempt := 0
            translated := base
            while (attempt <= TRANS_RETRY && running) {
                attempt += 1
                ; 按翻译热键前重新全选 —— 上面那次全选离现在隔了几百毫秒 (中间还按了
                ; Ctrl+C), 不能让翻译工具拿到“可能已经丢掉”的选中状态。
                ; SelectAllVerified 里含: 系统菜单延迟 + WM_NULL 冲队列 + STranslate 准备,
                ; 并且会问控件“是不是真的全选了”, 没全选就重来。
                SelectAllVerified("右Alt+F" . (attempt > 1 ? " 第" . attempt . "次" : ""), T_TRANS_PREPARE)
                LogLine("按翻译热键 (第 " . attempt . " 次, " . TRANS_HOTKEY_MODE . " 模式)")
                SendTransHotkey()

                ; ---- 5. 等译文出现 ----
                translated := WaitTranslated(base)
                if (translated != base)
                    break

                ; 文本框一个字都没变 -> 这次翻译根本没发生
                LogLine("!! 文本框没有任何变化, 判定这次没翻译成功")
            }

            if (translated = base) {
                LogLine("!! 重试 " . TRANS_RETRY . " 次仍无译文, 这次按原文继续 (可能 STranslate 没响应热键)")
            }
            LogLine("译文: " . Repr(translated))

            ; ---- 6. translateposthtml.py ----
            err2 := "", post := ""
            if (RunPy(POST_SCRIPT, ToLf(translated), &post, &err2) != 0) {
                StopWithError("translateposthtml.py 调用失败", err2)
                return
            }
            post := Trim(post, "`r`n")
            LogLine("translateposthtml.py -> " . Repr(post))

            ; ---- 7. 粘回去 + 回车 (PasteText 内部会先自己全选一次) ----
            PasteText(post)
        } else {
            LogLine("不需要翻译 -> 直接回车")
        }

        Send("{Enter}")
        Sleep T_AFTER_ENTER
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

; 右键菜单 -> a (全选)
SelectAll() {
    global MENU_KEY, T_MENU_OPEN, T_MENU_PICK
    Send(MENU_KEY)
    Sleep T_MENU_OPEN
    Send("a")
    Sleep T_MENU_PICK
}

; 全选之后、按下一个键之前调用。三步:
;   1) 按系统自己的“菜单显示延迟”(SPI_GETMENUSHOWDELAY, 默认 400ms) 等一等
;   2) 发 WM_NULL 把目标窗口的消息队列冲干净 (等它真的处理完, 不是猜)
;   3) extra: 再等一小段, 留给目标程序之外的第三方工具 (STranslate) 准备
; 手动的右键菜单全选之后, 程序可能还要跑一小会儿才把选中状态落到控件上;
; 只 Sleep 一个数字是赌, 冲队列才是确认。而第三方工具连“确认”都做不到
; (它的状态我们看不见), 只能额外留时间。
SettleAfterSelectAll(what, extra := 0) {
    global T_AFTER_SELECTALL, USE_MESSAGE_FLUSH, T_FLUSH_TIMEOUT

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

; 右键菜单全选后 Ctrl+C, 返回剪贴板文本 (失败返回 "")
SelectAllCopy() {
    global T_AFTER_COPY
    SelectAll()
    return CopyToClip()
}

CopyToClip() {
    global T_AFTER_COPY, T_CLIP_WAIT
    try A_Clipboard := ""
    Send("^c")
    if !ClipWait(T_CLIP_WAIT / 1000, 0)
        return ""
    Sleep T_AFTER_COPY
    return A_Clipboard
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
WaitTranslated(baseline) {
    global running, WAIT_MODE, T_TRANS_FIXED, T_TRANS_WAIT, T_TRANS_POLL, T_TRANS_MAX

    if (WAIT_MODE = "fixed") {
        Sleep T_TRANS_FIXED
        cur := SelectAllCopy()
        return (cur != "") ? cur : baseline
    }

    Sleep T_TRANS_WAIT
    prev := baseline
    changed := false
    deadline := A_TickCount + T_TRANS_MAX
    while running {
        cur := SelectAllCopy()
        if (cur != "") {
            if changed {
                if (cur = prev) {
                    LogLine("译文已稳定")
                    return cur
                }
                prev := cur
            } else if (cur != baseline) {
                changed := true
                prev := cur
            }
        }
        if (A_TickCount > deadline) {
            LogLine("等译文超时(" . T_TRANS_MAX . "ms), 用当前内容继续")
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
    Say("  没翻译成时重试 " . TRANS_RETRY . " 次;  全选核对 = " . (VERIFY_SELECTION ? "开" : "关"))

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

^!s::RunLoop()

#HotIf running
Esc::StopLoop()
#HotIf
