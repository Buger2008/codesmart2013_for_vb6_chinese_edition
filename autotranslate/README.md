# 自动汉化循环 — 使用说明书

成品文件：`ahk_translate_loop.ahk`（AutoHotkey **v2**，单文件，无其它依赖文件）

---

## 一、它做什么

鼠标点进目标程序的文本框，按 `Ctrl+Alt+S` 开始，脚本就一个框一个框往下跑，`Esc` 随时停：

```
[取原文]  右键菜单键 -> a(全选) -> Ctrl+C
          -> translate.py            输出两行: 第1行 true/false, 第2行预处理后的文本
true  :   (全选) 粘贴第2行
          -> (全选) 等 400ms + 冲消息队列 + 等 300ms 给 STranslate 准备
          -> 右Alt+F 分步慢按 -> 等译文出现 -> 全选 Ctrl+C 取译文
          -> translateposthtml.py    输出一行 -> (全选) 粘贴回去 -> 回车
false :   直接回车
```

然后进入下一个文本框，无限循环。

---

## 二、怎么用

1. **双击** `ahk_translate_loop.ahk`（脚本常驻托盘，不弹窗）
2. 鼠标点进VBLocalize的那个文本框（让焦点在它上面）
3. 按 `Ctrl+Alt+S`
4. 想停按 `Esc`

### 只想验证和 python 的连接（不动任何窗口）

```
"D:\Program\AutoHotkey\v2\AutoHotkey.exe" "D:\buger\Desktop\汉化\auto\release\ahk_translate_loop.ahk" --selftest
```

跑完在同目录生成 `ahk_translate_loop_selftest.txt`，13 项全绿才算正常。

### 日志

同目录 `ahk_translate_loop.log`，每轮都记：原文、translate.py 结果、全选核对、译文、posthtml 结果。

---

## 三、目录结构（同目录调用，整体可搬）

**这个目录就是完整的一套，拷到哪台机器都能直接跑**，脚本只找自己旁边的 py：

```
release\
  ahk_translate_loop.ahk     ← 双击这个
  translate.py               ← 翻译前处理（会 import 下面两个）
  translateprehtml.py
  translatejudge.py
  translateposthtml.py       ← 翻译后处理
  README.md                  ← 本文件
```

| 用途 | 配置项 | 值 |
|---|---|---|
| Python 解释器 | `PYTHON` | `D:\Program\Python3\python.exe`（不在就自动退回 PATH 里的 `python`，并写日志） |
| 翻译前处理 | `PRE_SCRIPT` | `A_ScriptDir "\translate.py"` |
| 翻译后处理 | `POST_SCRIPT` | `A_ScriptDir "\translateposthtml.py"` |

> `translate.py` 会 import 同目录的 `translatejudge.py` / `translateprehtml.py`，脚本已把目标脚本所在目录加进 `sys.path`，不用管。
>
> python 用 `-B` 跑，**不会在目录里生成 `__pycache__` 之类的垃圾**。
>
> 运行产物只有两个，都可以随时删：`ahk_translate_loop.log`（日志）、`ahk_translate_loop_selftest.txt`（自检报告）。

### ⚠ `auto\` 下还有一套原件

`D:\buger\Desktop\汉化\auto\` 里的 `translate*.py` 是原件，**没有动**（`final_test.py` 还在用它们）。
release 里的是副本，从这一刻起**两边会各自独立**：

- 想改 py 逻辑 → 改完记得把改动同步到另一边，或者以后只在一个地方改
- 只改 ahk 的话没这个问题：脚本已经改成同目录调用，放在 `auto\` 或 `release\` 都能跑，各自用自己旁边的那套 py


---

## 四、配置速查（都在文件开头的「用户配置」段）

### 觉得"太快了 / 偶尔没触发"

| 配置 | 当前值 | 作用 |
|---|---|---|
| `T_TRANS_PREPARE` | **300** | 冲完消息队列后, 再给 STranslate 留的准备时间（**最常用**的旋钮） |
| `T_HOTKEY_HOLD_MOD` | 150 | RAlt 按下后等多久再按 F |
| `T_HOTKEY_HOLD_KEY` | 100 | F 按住多久 |
| `T_HOTKEY_HOLD_AFTER` | 150 | F 松开后等多久再松 RAlt |
| `SELECT_SETTLE_EXTRA` | 0 | 追加到"系统菜单延迟"之上 |
| `T_AFTER_ENTER` | 400 | 回车进下一个框后等多久 |

### 全选 / 粘贴相关

| 配置 | 当前值 | 作用 |
|---|---|---|
| `SELECT_SETTLE_MODE` | `"system"` | 全选后等系统自己的菜单延迟(`SPI_GETMENUSHOWDELAY`=400ms)；写成数字则强制 |
| `VERIFY_SELECTION` | `true` | 全选后用 `EM_GETSEL` 问控件"真的全选了吗"，没全选就重来 |
| `SELECT_ALL_BEFORE_PASTE` | `true` | 每次粘贴前先全选（否则会插在光标处而不是替换整段） |
| `USE_MESSAGE_FLUSH` | `true` | 用 `WM_NULL` + `SendMessageTimeout` 确认目标程序处理完了按键 |
| `MENU_KEY` | `{AppsKey}` | 右键菜单键；不管用可换 `{F10}` 或 `+{F10}` |

### 翻译热键

| 配置 | 当前值 | 作用 |
|---|---|---|
| `TRANS_HOTKEY_MODE` | `"step"` | 分步慢按；改 `"string"` 就变回一次连发（老行为） |
| `TRANS_HOTKEY` | `{RAlt down}{f down}{f up}{RAlt up}` | 热键本体（`"string"` 模式用） |
| `TRANS_RETRY` | 1 | 等完没反应就重来几遍 |

### 等待译文

| 配置 | 当前值 | 作用 |
|---|---|---|
| `WAIT_MODE` | `"poll"` | 轮询看文本变没变；改 `"fixed"` 变成死等 `T_TRANS_FIXED` |
| `T_TRANS_WAIT` | 1200 | 按完热键先干等多久再开始看 |
| `T_TRANS_POLL` | 500 | 每隔多久看一次 |
| `T_TRANS_MAX` | 12000 | 最多等多久（超时→判定没翻译成→重试） |
| `T_PY_MAX` | 60000 | 单次 python 调用上限（judge 联网最坏 34s） |

### 其它

| 配置 | 当前值 | 作用 |
|---|---|---|
| `SEND_MODE` | `"Event"` | 像真人按键，兼容老程序；嫌慢改 `"Input"` |
| `KEY_DELAY` / `KEY_DUR` | 30 / 20 | 按键间隔 / 按住时长 |
| `T_MENU_OPEN` / `T_MENU_PICK` | 300 / 200 | 等菜单弹出 / 按完 a 之后 |
| `T_CLIP_WAIT` | 2000 | 等剪贴板出现内容的上限（空文本框会白等这么久） |
| `SHOW_STATUS` | `true` | 右上角显示"运行中 #n" |
| `DEBUG_LOG` | `true` | 写日志 |

---

## 五、日志里怎么定位问题

| 日志行 | 含义 / 对策 |
|---|---|
| `原文: "..."` | 取到的原文。是空的话看下一个框 |
| `translate.py -> need=true/false` | 第1行判定 + 第2行预处理文本 |
| `翻译前基准: "..."` | 粘贴后从盒子读回来的规范文本，**应该和上面 `text=` 一致** |
| `全选核对(...): 选中 0..78 / 共 78 字符` | 真的全选了 ✅ |
| `全选核对(...): 选中 78..78 / 共 78` | **没全选** → 会自动重来；一直这样就是控件/菜单问题 |
| `控件不响应 EM_GETSEL, 跳过核对` | 文本框是自绘控件，核不了，只能靠重试兜 |
| `按翻译热键 (第 1 次, step 模式)` | 热键发出去了 |
| `译文已稳定` | 抓到译文了 ✅ |
| `!! 文本框没有任何变化, 判定这次没翻译成功` | STranslate 没响应热键 → 加大 `T_TRANS_PREPARE` 或 `T_HOTKEY_HOLD_MOD` |
| `等译文超时(12000ms)` | 同上 |
| `已按 Esc, 中止本次调用` | 是你自己按停的，不是错误 |
| `冲消息队列超时/失败` | 目标程序卡住，退化成了纯等待 |

---

## 六、已知限制

- 脚本只发按键，**不管鼠标**；跑的过程中别去点别的窗口，否则按键会打到别处
- 目标文本框如果是自绘控件（不响应 `EM_GETSEL`），"全选是否生效"无法核对，只能靠重试
- `translate.py` 的 judge 会联网，最坏 34 秒；这段时间脚本在等，按 `Esc` 可以中断
- 出错会弹一次对话框并停止循环；按 `Esc` 中断不会弹
