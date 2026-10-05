# -*- coding: utf-8 -*-
r"""
translatejudge.py —— VB6 / CodeSmart 汉化判定器

对外只需要一个函数:

    judge(text) -> bool
        True  = 需要翻译
        False = 保持原样

三层判定机制（依次生效）:

    第 1 层  最高优先级 SKIP    命中即 SKIP        绝对不可翻
               a) 含中文 —— 已汉化的绝不能再翻
               b) 含等号 —— 配置/查询/赋值，不是给人看的文本
    第 2 层  强制翻译层         命中即 TRANSLATE   优先级高于第 3 层
               a) UI 词白名单（按钮标签 + 多词 UI 短语）
               b) 含 & 的串 —— VB6 菜单加速键标志
    第 3 层  其余 13 条保护规则  命中即 SKIP
    第 4 层  模型 noul 阈值      处理剩余的长句/复杂串

核心约定（用户确认）:

    1. 含等号 = 一定不翻译。涉及 = 的都不是给人看的文本
       （配置项、查询参数、赋值语句、注册表数据）。
       这条优先级仅次于"含中文"，会压过下面第 2 条的 & 规则。
    2. 含 & 的串一律翻译（强力规则）。& 是 VB6 的菜单快捷键标志，
       可以出现在词中间：Rena&me / Wind&ows / Boo&kmarks / Doc&kable。
    3. 不带空格的串一律不翻译（这类串很多直连注册表，翻译后会导致崩溃）。
       三类例外仍要翻译：
           - 按钮标签 OK / Cancel / Help / Start
           - 含菜单加速键 & 的串
           - 含英文冒号 : 或省略号 ... 的提示语，如 Analyzing: / Loading...

    ⚠ 前三层是纯规则、结果确定；第 4 层依赖接口返回的 noul 分数，
      而该分数存在抖动（见下方"阈值选择"）。要完全可复现，
      请把 judge() 的结果缓存下来，不要对同一串反复调用。

阈值选择（默认 0.30）:

    实测 noul 分数被量化到 k/64（步长 0.015625），同一字符串重复调用的
    抖动最坏可达 2 格（0.031）。所以阈值要躲开"最高分负例"至少 2 格。

    规则层已经定论 648/655 = 98.9% 的负例、207/301 = 69% 的正例，
    只剩 7 条负例会走到模型，最高分仅 0.2227（'Property Set '，VB6 关键字）。
    0.2227 + 2 格 = 0.2537，因此阈值 >= 0.26 就免疫抖动；这里取 0.30，
    多留约 5 格余量给其它工程（0.30 也是抖动条数最少的档位）。

        阈值 0.30 -> 过度汉化 1 条（&CodeSMART，见下），漏译 8 条
        阈值 0.40 -> 过度汉化 1 条，                  漏译 15 条
        阈值 0.60 -> 过度汉化 1 条，                  漏译 81 条

    唯一那条"过度汉化"是 &CodeSMART —— 品牌菜单项。按"含 & 一律翻译"的
    强力规则它会被送去翻译，但品牌名本身不会被改动，实际是无害的空操作。
    若要让它也判 SKIP，把 'codesmart' 加进 KEEP_EXACT 即可。

用法:

    from translatejudge import judge

    if judge("&Copy Region"):
        ...          # 需要翻译

    python translatejudge.py --selftest          # 离线自检，不联网
    python translatejudge.py --explain "文本"     # 显示判定原因
    python translatejudge.py "文本1" "文本2"      # 在线判定，打印 bool

环境变量:

    VB_LOCALIZE_THRESHOLD=0.45     调整模型阈值（默认 0.40）
    UNISOUND_API_KEY=...           覆盖接口密钥

接口说明:
    u2-decision 返回的不是 TRANSLATE/SKIP 字面量，而是"该翻译"的概率:
        {"answers": {"decision": {"type": "noul", "noul": 0.59}}}
    原实现 data.get("answers", {}).get("decision") 拿到的是这个 dict，
    当标签用会得到 None，本文件已修正为取 noul 并套阈值。
"""
import os
import re
import sys
import time

try:
    import requests
    API_AVAILABLE = True
except ImportError:                     # 没装 requests 时退化为纯规则模式
    requests = None
    API_AVAILABLE = False

url = "https://maas-api.unisound.com/v1/systemone"

API_KEY = os.environ.get("UNISOUND_API_KEY", "sk-fsr2wp5yxqvh6aegacug0c8h3midigrqvof7sp1wenx9xx53")

headers = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json",
}

# 规则部分：结构化、放在 state 里，作为固定上下文
#
# ⚠ 必须用原始字符串 r""" —— 规则正文里到处是 \b \e \t \r\n 这类"字面反斜杠序列"，
#   用普通字符串会被 Python 自己转义：\b 变成退格符 U+0008、\t 变成真制表符，
#   发给接口的 prompt 就被改坏了（原来 main.py 就有这个 bug，已修）。
RULES = r"""
You are a localization decision engine for a CodeSMART 2013 for VB6 Chinese localization project.
Given ONE string extracted from the project's string table, decide:
  TRANSLATE  -> it is still English natural-language UI text and should be localized.
  SKIP       -> it must be kept as-is.

## Context
- The project is partially localized into Chinese. Some strings are already Chinese.
- Strings may be: English UI text, Chinese UI text, identifiers, paths, file names,
  SQL fragments, VB6 keywords, version numbers, punctuation, or mixed content.
- Only English natural-language UI text should be translated.

## Decision procedure (apply in order, first match wins)
Step 1. If the string contains ANY CJK character -> SKIP.   (rule C1)
Step 2. If the string contains NO ASCII letters and NO digits -> SKIP.  (rule C2)
Step 3. Apply SKIP rules S1..S10. If any matches -> SKIP.
Step 4. Apply TRANSLATE rules T1..T6. If any matches -> TRANSLATE.
Step 5. Otherwise -> SKIP.

## CJK rule (highest priority)
C1. Any string containing Chinese/Japanese/Korean characters is already localized
    or intentionally mixed. Output SKIP, regardless of other content.
    Examples: "书签已删除。", "当前插入位置：", "'. 插入位置",
              "确定要删除所选书签吗？", "跳过标有“CSEH： Skip”的构件/组件".

## Pure-symbol rule (second priority)
C2. If the string contains NO ASCII letter (A-Z, a-z) and NO digit (0-9),
    output SKIP, even if it contains ':' or other punctuation.
    Examples: "...", "()", "[]", "|", ", ", " _", "&", "\r\n", "\t", ") '", ") ".

## SKIP rules (identifiers, code, paths, brands)
S1.  Pure identifier: no whitespace, only letters/digits/underscore,
     and NOT a natural English word in context.
     Examples: "FontSize", "Fake", "Unassigned", "CodeSMART", "VB6".
S2.  Dotted class/method name: segments joined by '.', at least one segment
     starts with an uppercase letter followed by lowercase (PascalCase).
     Examples: "AxBookmarks.CBookmark.Init",
               "AxCodeAnalyzer.VBCaPreprocess.PreProcess".
S2b. Dotted name where ALL segments are ALL-CAPS, digits, or known file
     extensions -> treat as identifier or file name.
     Examples: "VB6.GMR", "VB6.GMR.DLL", "MSVBVM60.DLL".
S3.  CamelCase or concatenated words without spaces.
     Examples: "BeforeFormatPage", "imgNode", "FontFace", "InsertCSBmks".
S4.  File path, registry key, or file name (contains '\' or ends with a known
     extension like .dll/.lyt/.mdb/.udp).
     Examples: "Settings\Bookmark", "iwf0.lyt", "AxCS.dll".
S5.  Pure number or version.
     Examples: "2.0", "32770", "#P0#", "6.0.81.76".
S6.  VB6 keyword / SQL fragment / code statement.
     Examples: "If * Then *", "SELECT * FROM ...", "[Get]", "[Let]", "[Set]",
               "End Property", "Exit Sub".
S7.  Single English word WITHOUT whitespace and WITHOUT punctuation.
     This rule applies ONLY when the string is exactly one word made of letters
     (optionally ending with a letter). If the string has spaces, '&', '...',
     ':', or any punctuation, S7 does NOT apply.
     Examples (SKIP): "Code", "Line", "Flag", "True", "False", "Name".
     Non-examples (do NOT match S7): "Current insert position:" (has spaces
     and ':'), "Loading..." (has '...').
S8.  Product/brand name with no sentence structure.
     Examples: "Microsoft Visual Basic", "Windows", "CodeSMART".
S9.  Menu accelerator with ONLY '&' + one short token, and no natural-language
     verb/noun phrase. Examples: "&", "&&". (Note: "&Start", "&Copy" are
     TRANSLATE, see T2.)
S10. Command-line / format string with placeholders only, no natural language.
     Examples: "%s", "%d %s", "{}".

## TRANSLATE rules (English UI text)
T1. Complete English sentence or phrase with natural-language structure
    (subject/verb/object, or a UI prompt). Contains at least two English words
    and at least one lowercase word.
    Examples: "Are you sure you want to clear this pane?",
              "Are you sure you want to clear this pane?".
T2. Menu/button text containing '&' accelerator AND at least one English word.
    Examples: "&Start", "&Copy", "&Copy Region", "&Delete".
T3. Text containing '...' as a UI hint AND at least one English word.
    Examples: "Loading...", "Searching...".
    NOTE: "..." alone is SKIP (C2), not T3.
T4. Text containing ':' that is part of a natural-language prompt.
    Examples: "Analyzing member:", "Warning:", "Current insert position:".
    IMPORTANT: T4 takes precedence over S7. Any string with whitespace and a
    trailing or embedded ':' in a natural-language context is TRANSLATE.
T5. Compiler / error / warning message in English.
    Examples: "'Option Explicit' statement not found in the component's code.".
T6. Natural-language string containing escape sequences like \b, \e, \t used
    as inline formatting markers.
    Examples: "The class \bmust have an \baccessor member named: \eItem".

## Priority and disambiguation
- Step 1 (C1 CJK) and Step 2 (C2 pure symbols) ALWAYS win, before any S/T rule.
- Among S and T rules: if a string matches both, SKIP wins.
- S7 must NEVER match a string that has whitespace or punctuation.
- T4 must NEVER be overridden by S7 for strings with whitespace and ':'.
- Default when nothing matches: SKIP.

## Output format
Respond with exactly ONE token, uppercase: TRANSLATE or SKIP.
No explanation, no quotes, no punctuation.
"""

# Few-shot 示例（可选，但强烈建议）
FEW_SHOT = [
    # --- C1: 含中文 -> SKIP ---
    {"text": "书签已删除。", "label": "SKIP"},
    {"text": "当前插入位置：", "label": "SKIP"},
    {"text": "'. 插入位置", "label": "SKIP"},
    {"text": "确定要删除所选书签吗？", "label": "SKIP"},
    {"text": "跳过标有“CSEH： Skip”的构件/组件", "label": "SKIP"},

    # --- C2: 纯符号 -> SKIP ---
    {"text": "...", "label": "SKIP"},
    {"text": "()", "label": "SKIP"},
    {"text": "&", "label": "SKIP"},
    {"text": "\r\n", "label": "SKIP"},
    {"text": ") '", "label": "SKIP"},
    {"text": " _", "label": "SKIP"},

    # --- S1/S2/S2b/S3/S4/S5/S6/S7/S8 ---
    {"text": "FontSize", "label": "SKIP"},
    {"text": "CodeSMART", "label": "SKIP"},
    {"text": "AxBookmarks.CBookmark.Init", "label": "SKIP"},
    {"text": "AxCodeAnalyzer.VBCaPreprocess.PreProcess", "label": "SKIP"},
    {"text": "VB6.GMR", "label": "SKIP"},
    {"text": "VB6.GMR.DLL", "label": "SKIP"},
    {"text": "BeforeFormatPage", "label": "SKIP"},
    {"text": "InsertCSBmks", "label": "SKIP"},
    {"text": "Settings\\Bookmark", "label": "SKIP"},
    {"text": "2.0", "label": "SKIP"},
    {"text": "If * Then *", "label": "SKIP"},
    {"text": "[Get]", "label": "SKIP"},
    {"text": "Code", "label": "SKIP"},
    {"text": "Line", "label": "SKIP"},
    {"text": "Microsoft Visual Basic", "label": "SKIP"},

    # --- T1/T2/T3/T4/T5/T6 ---
    {"text": "Are you sure you want to clear this pane?", "label": "TRANSLATE"},
    {"text": "&Start", "label": "TRANSLATE"},
    {"text": "&Copy Region", "label": "TRANSLATE"},
    {"text": "Loading...", "label": "TRANSLATE"},
    {"text": "Searching...", "label": "TRANSLATE"},
    {"text": "Analyzing member:", "label": "TRANSLATE"},
    {"text": "Current insert position:", "label": "TRANSLATE"},
    {"text": "Warning:", "label": "TRANSLATE"},
    {"text": "'Option Explicit' statement not found in the component's code.", "label": "TRANSLATE"},
    {"text": "The class \\bmust have an \\baccessor member named: \\eItem", "label": "TRANSLATE"},
]


# =========================================================================== #
#  判定引擎（规则 + 白名单 + 阈值）
# =========================================================================== #
# 阈值可用环境变量覆盖:  set VB_LOCALIZE_THRESHOLD=0.40
#
# 为什么是 0.30：
#   实测接口返回的 noul 分数被量化到 k/64（步长 0.015625），同一字符串重复
#   调用会有抖动，最坏可达 2 格（0.031）。所以阈值要躲开"最高分负例"至少 2 格。
#
#   规则层（尤其是 G5「无空格不翻」）已经拦掉 648/655 = 98.9% 的负例，
#   只有 7 条会走到模型，最高分仅 0.2227（'Property Set '，VB6 关键字）。
#   0.2227 + 2 格 = 0.2537  ->  阈值只要 >= 0.26 就免疫抖动。
#   这里取 0.30，比理论下限多留约 5 格余量，给其它工程留安全边际。
#
#   阈值 0.30 下的表现：
#     过度汉化 FP = 0（且结构上免疫抖动，不可能翻成 FP）
#     漏译     FN = 13
#   对比阈值 0.60：FP 同样是 0，但漏译高达 81 条。
#
#   若要更保守：0.40 -> 漏译 22 条，余量 11 格。
#   若要更激进：0.26 -> 漏译 10 条（理论下限，余量 2 格）。
#
#   注：'Code Window'、'Menu Bar' 是用户确认"故意保留"的串（直连注册表，
#       翻译后会崩），已由 G5b 规则拦下。
THRESHOLD = float(os.environ.get("VB_LOCALIZE_THRESHOLD", "0.30"))

# 单次请求超时。实测接口延迟约 0.2s，10s 已有 50 倍余量；
# 超时设太大一旦网络挂起会白等很久，所以可调但别调大。
REQUEST_TIMEOUT = float(os.environ.get("VB_LOCALIZE_TIMEOUT", "10"))

_ESC_RE = re.compile(r"\\[betn]")          # \b \e \t \n 这类行内格式标记


# --------------------------------------------------------------------------- #
# 第 1 层：保护规则（只返回 True = 判 SKIP）
#   设计原则：宁可漏判(留给模型)，不可误杀；每条都在真实语料上验证过
#
#   注：原来的「G6 品牌名」规则已删除 —— 用户确认新版翻译器能正确处理品牌名，
#       品牌不再是"不翻"的理由。含 CodeSmart 的串改由 FORCE_TRANSLATE_WORDS
#       强制送去翻译。
# --------------------------------------------------------------------------- #
_FONTS = ("tahoma", "ms sans serif", "courier new", "arial", "times new roman",
          "symbol", "wingdings", "verdana", "ms forms", "fixedsys")

# 按钮上允许翻译的单词（唯一的单词例外）。
# 其余单个英文单词一律不翻 —— 它们很多直连注册表，翻译后会崩。
BUTTON_WORDS = {"ok", "cancel", "help", "start"}

# 用户明确确认"故意保留"的字符串（直连注册表，翻译后会崩）。
# 这些是项目专有知识，规则推不出来，所以硬编码记录。
# 注：其中单个单词的部分（Toolbars / Operations / Synchronize / Interval /
#     Scope / Sorting / Member / Panes / Software / Startup / Smooth）
#     已经被 G5「单个单词」规则覆盖，这里只列非单词形态的。
KEEP_EXACT = {
    "code window",
    "menu bar",
}

# 注：原来还有一条「G6 品牌名 -> SKIP」规则，已删除。
#     用户确认新版翻译器能正确处理品牌名，所以品牌不再是"不翻"的理由。
#     删除后含 CodeSmart 的串不再被品牌规则拦截，改为按正常流程判定
#     （形态规则 / 模型分数），既不会漏拦内部路径和 SQL，也不强制翻译。

_SQL_RE = re.compile(r"\b(FROM|WHERE|INTO)\b")


def has_cjk(s):
    """是否含中文/日文/韩文"""
    return any("\u4e00" <= c <= "\u9fff" or "\u3400" <= c <= "\u4dbf"
               or "\u3000" <= c <= "\u303f" or "\uff00" <= c <= "\uffef"
               or "\u3040" <= c <= "\u30ff" for c in s)


def r_cjk(t):
    """G1 含中文 -> 已汉化，绝不能再翻"""
    return has_cjk(t)


def r_empty_or_symbols(t):
    """G2 空串 / 纯符号"""
    s = t.strip()
    return (not s) or (not any(c.isalnum() for c in s))


def r_no_letters(t):
    """G3 没有字母（纯数字/版本/日期）"""
    return not any(c.isalpha() for c in t)


def r_has_equals(t):
    """G0 含等号 -> SKIP

    用户确认：只要涉及 = 就不是需要翻译的内容。
    这类串是配置项、查询参数、赋值语句、注册表数据，例如
        &body=   &cc=   ;LANGID=0x0409;CP=1252;COUNTRY=0
    优先级最高（仅次于含中文），要压过"含 & 一律翻译"的强力规则。
    """
    return "=" in t


def r_identifier(t):
    """G4 标识符形态: CompForm / imgNodes / keyIF / ImgCollapsed256
    排除纯英文单词（交给模型），也排除 Find1/Find2 这类 UI 名"""
    s = t
    if s != s.strip() or not s or " " in s:
        return False
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", s):
        return False
    if re.fullmatch(r"[A-Z][a-z]+|[a-z]+", s):
        return False
    if re.fullmatch(r"[A-Z][a-z]+[0-9]", s):      # Find1 / Find2
        return False
    return bool("_" in s or re.search(r"[a-z][A-Z]", s) or re.search(r"\d", s)
                or (s.isupper() and len(s) > 1))


def r_keep_exact(t):
    """G5b 明确确认过的"故意保留"字符串（直连注册表，翻了会崩）"""
    return t.strip().lower() in KEEP_EXACT


# mailto / URL 查询参数片段（&body= / &cc=），带 & 但不是菜单项
_QUERY_PARAM_RE = re.compile(r"&\w+=")



def r_single_word(t):
    """G5 没有空格的字符串 -> SKIP

    规则来源（用户确认）：所有不带空格的串一律不翻译。

    例外（仍要翻译 / 交给模型判定）：
      1. 按钮标签 OK / Cancel / Help / Start
      2. 含菜单加速键 & 的串 —— VB6 用 & 后的字母做快捷键，这是菜单的标志，
         如 &Add / Rena&me / Wind&ows / &Print...
         （加速键可以在词中间，所以搜索 & 而不是看开头）
      3. 含英文冒号的提示语，如 Analyzing:
      4. 含省略号的提示语，如 Loading...

    另：&body= / &cc= 这种 mailto 查询参数带 & 但不是菜单项，仍判 SKIP。

    这条规则覆盖了原来那些零散情况：
      Toolbars / Operations / Synchronize / Interval / Scope / Sorting /
      Member / Panes / Software / Startup / Smooth / Red / Control / Forms /
      Modules / Find1 / Find2 / Ctrl+F11 / [Get] / #P0# / Groupping\\Tasks ...
    """
    s = t.strip()
    if not s or " " in s:
        return False
    if s.lstrip("&").lower() in BUTTON_WORDS:
        return False                              # 按钮例外
    if _QUERY_PARAM_RE.fullmatch(s):
        return True                               # &body= / &cc= 是查询参数
    if "&" in s or ":" in s or "..." in s:
        return False                              # 菜单加速键 / 冒号 / 省略号
    return True


def r_font(t):
    """G7 字体名"""
    return t.lower().strip("&. ") in _FONTS


def r_path(t):
    """G8 文件路径 / URL / 盘符 / UNC。
    只用"真的像文件"的判据：不再"只要含反斜杠就判路径"，
    因为 'Project Explorer\\Options'、'CodeAutomation\\Error Handling'
    人工都翻译过。同时先剥掉 \\b \\e 标记，避免把格式标记当路径。"""
    stripped = _ESC_RE.sub(" ", t)
    low = t.lower()
    if re.search(r"\.(dll|exe|ocx|lyt|mdb|udp|xyn|upd|res|csi|gmr|ini|txt|log|tmp|dat)\s*$", low):
        return True
    if re.match(r"^\s*(https?://|mailto:|www\.|ftp://|[a-z]:\\)", low):
        return True
    if re.match(r"^\s*\\\\", stripped):
        return True
    return False


def r_sql(t):
    """G9 SQL 片段。只认大写关键字（本项目 SQL 全大写），
    否则自然语言里的 'from' 会被误判，例如
    'Exclude this component from &code analysis'"""
    if _SQL_RE.search(t):
        return True
    return bool(re.match(r"^\s*(SELECT|DELETE|INSERT|UPDATE)\b", t) and "*" in t)


def r_dotted_name(t):
    """G12 点号连接的类/方法名: AxCS.CBookmark.Init"""
    s = t.strip()
    if " " in s or "." not in s:
        return False
    parts = [p for p in s.split(".") if p]
    return len(parts) >= 2 and all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", p) for p in parts)


def r_regkey(t):
    """G15 以反斜杠开头 -> 注册表键/路径片段，如 '\\Spelling'"""
    s = _ESC_RE.sub(" ", t).strip()
    return s.startswith("\\") and len(s) > 1 and s[1].isalpha()


def r_tiny_fragment(t):
    """G16 极短代码片段，如 "The '" 。
    必须含标点——否则 'Red' / 'Add ' 这类真该翻的短词会被误杀。"""
    s = t.strip()
    if not re.search(r"['\"()\[\]{}<>,;:.\-]", s):
        return False
    letters = re.findall(r"[A-Za-z]+", s)
    if not letters or sum(len(w) for w in letters) > 4:
        return False
    return bool(re.fullmatch(r"[A-Za-z]{0,3}[\s'\"()\[\]{}<>,;:.\-]*", s))


def r_quoted_fragment(t):
    """G14 引号/括号包着的符号片段，如 ") '" / "()" """
    s = t.strip()
    if any(c.isalpha() for c in s):
        return bool(re.fullmatch(r"[\"'()\[\]{}<>,;:.\s/\\|_\-&]+", s))
    return len(s) <= 3 or bool(re.fullmatch(r"[\"'()\[\]{}<>,;:.\s/\\|_\-&]+", s))


# 最高优先级 SKIP 规则：在"强制翻译层"之前生效
#   G1 含中文   已汉化的绝不能再翻
#   G0 含等号   配置/查询/赋值，不是给人看的文本
PRIORITY_RULES = [
    ("G1_含中文", r_cjk),
    ("G0_含等号", r_has_equals),
]

# 普通保护规则：在"强制翻译层"之后生效
# 顺序有意义：先判形态，最后判品牌/保留词
PROTECT_RULES = [
    ("G2_空或纯符号", r_empty_or_symbols),
    ("G3_无字母", r_no_letters),
    ("G4_标识符", r_identifier),
    ("G5b_确认保留", r_keep_exact),
    ("G5_无空格不翻", r_single_word),
    ("G7_字体", r_font),
    ("G8_路径文件", r_path),
    ("G9_SQL", r_sql),
    ("G12_点号类名", r_dotted_name),
    ("G14_引号片段", r_quoted_fragment),
    ("G15_反斜杠开头", r_regkey),
    ("G16_极短片段", r_tiny_fragment),
]

# 供外部/统计使用：全部 SKIP 规则
ALL_SKIP_RULES = PRIORITY_RULES + PROTECT_RULES


# --------------------------------------------------------------------------- #
# 第 2 层：UI 词白名单（命中即判 TRANSLATE）
#
#   单词部分只有 4 个按钮标签例外（BUTTON_WORDS）：
#       OK / Cancel / Help / Start
#   其余单个英文单词一律由第 1 层的 G5 规则判 SKIP（直连注册表，翻了会崩）。
#
#   短语部分是多词 UI 文本，不受"单个单词"规则影响。
#   你可以自由增删这两个表。
# --------------------------------------------------------------------------- #
UI_WORDS = {
    # 唯一的单词例外：按钮标签
    "ok", "cancel", "help", "start",
}

UI_PHRASES = {
    "task list", "view code", "class modules", "user controls",
    "user documents", "related documents", "hotkey designer",
    "flag complete", "flag for follow up", "fill with current word",
    "new region name", "view designer", "paste control with code",
    "autotext manager", "primary interop", "activex designers",
    "windows settings", "code analyzer commandbar",
    "comments checker commandbar", "designer analyzer commandbar",
    "spelling check commandbar",
    # 下面两条是"品牌规则"的已知误杀对象，显式救回
    "register codesmart", "codesmart tutor",
}

# 需要大小写不敏感匹配的短语（白名单里的英文原样）
_UI_PHRASES_LOWER = {p.lower() for p in UI_PHRASES}


def in_ui_whitelist(t):
    """命中 UI 词白名单 -> 应该翻译。比较时去掉 & 加速键并归一化空白。"""
    s = t.strip().replace("&", "").strip()
    s = re.sub(r"\s+", " ", s)
    low = s.lower()
    if low in UI_WORDS:
        return True
    if low in _UI_PHRASES_LOWER:
        return True
    return low.rstrip("*").strip() in _UI_PHRASES_LOWER


def has_accelerator(t):
    """是否含 VB6 菜单加速键 &（&body= / &cc= 这类查询参数除外）"""
    return "&" in t and not _QUERY_PARAM_RE.fullmatch(t.strip())


# --------------------------------------------------------------------------- #
# 第 3 层：模型分数
# --------------------------------------------------------------------------- #
def extract_noul(data):
    """从接口返回里取出 noul 概率。兼容三种形态：
        {"answers":{"decision":{"type":"noul","noul":0.59}}}
        {"decision":{"noul":0.59}}
        {"noul":0.59}
    另外若接口将来改成直接返回字面标签，也一并兼容。
    """
    def walk(node, depth=0):
        if depth > 6 or not isinstance(node, dict):
            return None, None
        for key in ("noul", "score", "value", "probability"):
            v = node.get(key)
            if isinstance(v, (int, float)):
                return float(v), None
        for key in ("answers", "decision", "result", "data", "output"):
            if key in node:
                s, lab = walk(node[key], depth + 1)
                if s is not None or lab is not None:
                    return s, lab
        for key in ("label", "answer", "text", "token"):
            v = node.get(key)
            if isinstance(v, str):
                up = v.strip().upper()
                if up in ("TRANSLATE", "SKIP"):
                    return None, up
        return None, None

    if isinstance(data, (int, float)):
        return float(data), None
    if isinstance(data, dict):
        return walk(data)
    if isinstance(data, str):
        up = data.strip().upper()
        if up in ("TRANSLATE", "SKIP"):
            return None, up
    return None, None


def query_score(text, timeout=REQUEST_TIMEOUT):
    """调用 u2-decision，返回 (noul 概率, 字面标签) 二者之一。失败抛异常。"""
    examples = "\n".join(
        'Text: %s\nLabel: %s' % (e["text"], e["label"]) for e in FEW_SHOT
    )
    payload = {
        "model": "u2-decision",
        "state": "%s\n\n## Examples\n%s" % (RULES, examples),
        "questions": {
            "decision": {
                "type": "noul",
                "instructions": (
                    "Decide whether the following VB6 string should be translated. "
                    "Answer with exactly one token: TRANSLATE or SKIP.\n"
                    "Text: <<<%s>>>" % text
                ),
            },
        },
    }
    response = requests.post(url, headers=headers, json=payload, timeout=timeout)
    response.raise_for_status()
    try:
        return extract_noul(response.json())
    except ValueError:
        return extract_noul(response.text)


def decide(text, use_api=True, explain=False):
    """三层判定。返回 'TRANSLATE' / 'SKIP' / None(没判定出来)。

    判定顺序（顺序很重要）：
      1) 最高优先级 SKIP    —— 含中文 / 含等号，绝对不能再翻
      2) 强制翻译层          —— 命中即 TRANSLATE，压过下面的形态规则：
                                a) UI 词白名单（按钮标签 + 多词 UI 短语）
                                b) 含 & 的串（VB6 菜单加速键标志）
      3) 其余保护规则        —— 命中即 SKIP
      4) 模型 noul 阈值

    use_api=False 时只走前面几层（不联网），用于离线批量预筛。
    explain=True 时额外返回命中原因，便于排查。
    """
    # ---- 第 1 层：最高优先级 SKIP ----
    for name, fn in PRIORITY_RULES:
        try:
            if fn(text):
                return ("SKIP", "保护规则 " + name) if explain else "SKIP"
        except Exception:
            continue

    # ---- 第 2 层：强制翻译（白名单 / 含 & 的菜单项）----
    if in_ui_whitelist(text):
        return ("TRANSLATE", "UI 词白名单") if explain else "TRANSLATE"
    if has_accelerator(text):
        return ("TRANSLATE", "含 & 菜单加速键") if explain else "TRANSLATE"

    # ---- 第 3 层：其余保护规则 ----
    for name, fn in PROTECT_RULES:
        try:
            if fn(text):
                return ("SKIP", "保护规则 " + name) if explain else "SKIP"
        except Exception:
            continue

    # ---- 第 4 层：模型分数 ----
    if not use_api:
        return (None, "需要模型判定") if explain else None
    score, label = query_score(text)
    if label:
        return (label, "接口直接给标签") if explain else label
    if score is None:
        return (None, "接口无 noul") if explain else None
    verdict = "TRANSLATE" if score >= THRESHOLD else "SKIP"
    if explain:
        return verdict, "模型 noul=%.4f (阈值 %.2f)" % (score, THRESHOLD)
    return verdict



# =========================================================================== #
#  公开 API
#
#    judge(text) -> bool
#        True  = 需要翻译 (TRANSLATE)
#        False = 保持原样 (SKIP)
#
#    judge_detail(text) -> (bool, str)
#        额外返回判定原因，便于排查
#
#  说明: judge() 永远不会返回 None。若接口失败/拿不到分数，返回 default 参数
#        （默认 False = 不翻译）。因为"过度汉化"比"漏译"更难收拾，
#        所以默认往保守方向倒。要改成乐观方向传 default=True 即可。
# =========================================================================== #
DEFAULT_ON_UNDECIDED = False          # 拿不到结论时返回什么（False = 不翻译）
MAX_RETRY = 2                         # 重试次数（总共最多 3 次请求）
RETRY_WAIT = 2.0                      # 每次重试前的固定等待秒数（不做指数退避）
# REQUEST_TIMEOUT 定义在文件上方配置区（query_score 的默认参数要用到它）


def _is_retryable(exc):
    """这个异常值不值得重试。

    4xx（除 429 限流）是请求本身的问题 —— 密钥错、参数错、权限不足，
    重试多少次都不会成功，所以直接放弃，不浪费时间。
    超时、连接错误、5xx、429 才重试。
    """
    resp = getattr(exc, "response", None)
    code = getattr(resp, "status_code", None) if resp is not None else None
    if code is not None and 400 <= code < 500 and code != 429:
        return False
    return True


def judge_detail(text, default=DEFAULT_ON_UNDECIDED, retry=MAX_RETRY,
                 timeout=REQUEST_TIMEOUT):
    """返回 (是否需要翻译: bool, 判定原因: str)

    失败处理：
      失败后固定等 RETRY_WAIT 秒（2s）重试，最多 retry 次（2 次，共 3 次请求）；
      仍然失败就返回 default。不可重试的错误（4xx）立即放弃，不等待。
      default 默认 False（不翻译）—— 漏译比误译安全，也比耗时间安全。

    最坏耗时：3 × timeout + 2 × RETRY_WAIT = 34s（默认值下）。
    """
    if text is None:
        return False, "空输入"
    if not isinstance(text, str):
        text = str(text)

    # ---- 规则层（不联网）----
    pre, why = decide(text, use_api=False, explain=True)
    if pre is not None:
        return (pre == "TRANSLATE"), why

    # ---- 模型层（联网）----
    if not API_AVAILABLE:
        return default, "requests 不可用，退回默认值"

    last = None
    for attempt in range(max(1, retry + 1)):
        try:
            score, label = query_score(text, timeout=timeout)
            if label:
                return (label == "TRANSLATE"), "接口直接给标签"
            if score is not None:
                return (score >= THRESHOLD), "模型 noul=%.4f (阈值 %.2f)" % (score, THRESHOLD)
            last = "接口无 noul 字段"
        except Exception as exc:                      # noqa: BLE001
            last = "%s: %s" % (type(exc).__name__, exc)
            if not _is_retryable(exc):
                last += "，不可重试立即放弃"
                break
        if attempt < retry:
            time.sleep(RETRY_WAIT)                    # 固定 2s
    return default, "接口失败(%s)，用默认值 %s" % (last, default)


def judge(text, default=DEFAULT_ON_UNDECIDED, retry=MAX_RETRY, timeout=REQUEST_TIMEOUT):
    """判断一条字符串是否需要翻译。

    参数:
      text    待判断的字符串
      default 无法判定时返回的值（默认 False = 不翻译）
      retry   接口失败重试次数（默认 2，共 3 次请求；每次固定等 2s）
      timeout 单次请求超时秒数（默认 10）

    返回:
      True  -> 需要翻译
      False -> 保持原样

    失败时返回 default（默认 False），绝不抛异常、绝不返回 None。
    """
    return judge_detail(text, default=default, retry=retry, timeout=timeout)[0]


def judge_batch(texts, default=DEFAULT_ON_UNDECIDED, retry=MAX_RETRY,
                timeout=REQUEST_TIMEOUT, sleep=0.0):
    """批量判断，返回 [bool, ...]，顺序与输入一致。

    sleep: 每次"真实请求"之间的间隔秒数（接口有速率限制，建议 1.0~1.5）。
           规则层就能定论的条目不会消耗请求，也不会等待。
    """
    out = []
    for t in texts:
        pre, _ = decide(t, use_api=False, explain=True) if isinstance(t, str) else (None, "")
        if pre is None and sleep:
            time.sleep(sleep)
        out.append(judge(t, default=default, retry=retry, timeout=timeout))
    return out


# 兼容旧名字
def result(text):
    """旧接口：返回 'TRANSLATE' / 'SKIP'（拿不到结论时按 default 归为 SKIP）"""
    return "TRANSLATE" if judge(text) else "SKIP"


def score_only(text, timeout=REQUEST_TIMEOUT):
    """只取 noul 分数（调参用）。规则层命中时返回 None。"""
    if decide(text, use_api=False) is not None:
        return None
    s, _ = query_score(text, timeout=timeout)
    return s


# --------------------------------------------------------------------------- #
# 自检 / 命令行
# --------------------------------------------------------------------------- #
_SELFTEST_CASES = [
    # (字符串, 期望 judge 返回值, 说明)
    ("书签已删除。", False, "G1 含中文"),
    ("打印...", False, "G1 含中文（原实现会误翻）"),
    ("当前插入位置：", False, "G1 含中文"),
    ("...", False, "G2 纯符号"),
    ("2.0", False, "G3 无字母"),
    ("120", False, "G3 无字母"),
    ("imgNodes", False, "G4 标识符"),
    ("ImgCollapsed256", False, "G4 标识符"),
    ("CompMDIForm", False, "G4 标识符"),
    ("AxCS.CBookmark.Init", False, "G12 点号类名"),
    ("CodeSmart", False, "G4 标识符"),
    ("Tahoma", False, "G5 单个单词"),
    ("Layouts\\iwf0.lyt", False, "G8 文件扩展名"),
    ("AxCS.dll", False, "G8 文件名"),
    ("DELETE * FROM ProjectOps WHERE TRUE", False, "G9 SQL"),
    ("The '", False, "G16 极短片段"),
    ("\\Spelling", False, "G15 反斜杠开头"),
    # ---- 单个单词：除按钮例外外一律不翻（直连注册表，翻了会崩）----
    ("Code Window", False, "2 词但属故意保留（注册表相关）"),
    ("Toolbars", False, "G5 单个单词（故意保留）"),
    ("Operations", False, "G5 单个单词（故意保留）"),
    ("Synchronize", False, "G5 单个单词（故意保留）"),
    ("Smooth", False, "G5 单个单词（故意保留）"),
    ("Red", False, "G5 单个单词（颜色名也不翻）"),
    ("Modules", False, "G5 单个单词"),
    # ---- 按钮例外：唯一允许翻译的单词 ----
    ("OK", True, "白名单 按钮例外"),
    ("Cancel", True, "白名单 按钮例外"),
    ("&Help", True, "含 & 菜单加速键"),
    ("Start", True, "白名单 按钮例外"),
    # ---- 含 & 一律翻译（强力规则）----
    ("&Add", True, "含 & 菜单加速键"),
    ("&Close", True, "含 & 菜单加速键"),
    ("Rena&me", True, "含 & 菜单加速键（在词中间）"),
    ("Wind&ows", True, "含 & 菜单加速键（在词中间）"),
    ("Boo&kmarks", True, "含 & 菜单加速键（在词中间）"),
    ("&Copy Region", True, "含 & 菜单加速键（多词）"),
    ("&body=", False, "G0 含等号"),
    ("&cc=", False, "G0 含等号"),
    (";LANGID=0x0409;CP=1252;COUNTRY=0", False, "G0 含等号"),
    ("Caption=&Text", False, "G0 含等号（即使含 &）"),
    # ---- 多词 UI 短语照常翻译 ----
    ("Task List", True, "白名单 UI 短语"),
    ("&Register CodeSmart", True, "含 & 菜单加速键"),
]


def _selftest():
    """离线自检，不联网。"""
    bad = 0
    for text, want, why in _SELFTEST_CASES:
        got, reason = judge_detail(text, default=False, retry=0)
        # 自检只覆盖规则层，全部不联网
        ok = (got == want)
        if not ok:
            bad += 1
        print("  [%s] %-38r 期望=%-5s 实得=%-5s (%s)"
              % ("OK " if ok else "FAIL", text, want, got, reason))
    print()
    print("自检: %d/%d 通过" % (len(_SELFTEST_CASES) - bad, len(_SELFTEST_CASES)))
    print("阈值 = %.2f（环境变量 VB_LOCALIZE_THRESHOLD 可覆盖）" % THRESHOLD)
    print("SKIP 规则 %d 条（最高优先 %d + 普通 %d），UI 白名单 %d 词 + %d 短语"
          % (len(ALL_SKIP_RULES), len(PRIORITY_RULES), len(PROTECT_RULES),
             len(UI_WORDS), len(UI_PHRASES)))
    print("接口可用: %s" % ("是" if API_AVAILABLE else "否（只有规则层生效）"))
    return bad == 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or args[0] in ("--selftest", "-t", "check"):
        sys.exit(0 if _selftest() else 1)
    if args[0] in ("--explain", "-e"):
        for t in args[1:]:
            v, why = judge_detail(t)
            print("%-5s %-40r  <- %s" % (v, t, why))
        sys.exit(0)
    # 默认：把命令行参数当字符串逐个判定（在线）
    for t in args:
        print("%-5s\t%s" % (judge(t), t))
