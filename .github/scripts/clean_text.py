"""
文本清洗引擎 — 基于规则的 Markdown 草稿规范化脚本
===================================================
职责：读取 YAML 规则配置 → 组装 System Prompt → 调用 DeepSeek API → 覆写清洗后文本
运行环境：GitHub Actions (ubuntu-latest) 或本地 Python 3.10+
依赖：pyyaml, requests
"""

import os
import sys
import json
import argparse

import yaml
import requests

# =============================================================================
# 路径常量 — 所有路径均相对于仓库根目录（由调用方的工作目录决定）
# =============================================================================
CONFIG_DIR = "02_Config"
BLACKLIST_FILE = os.path.join(CONFIG_DIR, "blacklist.yaml")
CHARACTERS_FILE = os.path.join(CONFIG_DIR, "characters.yaml")
FORMAT_FILE = os.path.join(CONFIG_DIR, "format.yaml")

# =============================================================================
# DeepSeek API 配置
# =============================================================================
DEEPSEEK_API_URL = "https://api.deepseek.com/chat/completions"
DEEPSEEK_MODEL = "deepseek-chat"
REQUEST_TEMPERATURE = 0.1          # 极低温度，确保输出严格遵循规则，杜绝创造性发挥
REQUEST_MAX_TOKENS = 16384         # 足够覆盖单章小说的清洗输出


def load_yaml(file_path: str) -> dict:
    """读取单个 YAML 文件并返回解析后的字典。文件不存在时直接终止。"""
    if not os.path.isfile(file_path):
        print(f"[FATAL] 配置文件不存在: {file_path}", file=sys.stderr)
        sys.exit(1)
    with open(file_path, "r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    if data is None:
        print(f"[WARN] 配置文件为空: {file_path}", file=sys.stderr)
        return {}
    return data


def load_all_configs():
    """加载三份 YAML 规则配置文件，返回统一的规则字典。"""
    blacklist = load_yaml(BLACKLIST_FILE)
    characters = load_yaml(CHARACTERS_FILE)
    formatting = load_yaml(FORMAT_FILE)
    return {"blacklist": blacklist, "characters": characters, "format": formatting}


def build_system_prompt(rules: dict) -> str:
    """将三份规则对象组装为一条结构化、指令明确的 System Prompt。

    设计理念：Prompt 分四个段落层层递进——
    1. 身份声明与核心指令（锚定 AI 行为模式）
    2. 角色行为边界（从 characters.yaml 提取，确保角色不越界）
    3. 词汇黑名单与陈词滥调过滤（从 blacklist.yaml 提取，逐项罗列）
    4. 排版与英式拼写公约（从 format.yaml 提取，硬性规范）
    """
    chars = rules.get("characters", {})
    bl = rules.get("blacklist", {})
    fmt = rules.get("format", {})

    # ---- 提取角色规则 ----
    character_sections = []
    for key, char in chars.items():
        name = char.get("full_name", key)
        ss = char.get("speech_style", {})
        bb = char.get("behavioural_boundaries", {})
        ir = char.get("interaction_rules", {})

        tone = ss.get("tone", "无特殊要求")
        forbidden = ss.get("forbidden_patterns", [])
        must_not = bb.get("must_not", [])
        soft_limits = bb.get("soft_limits", [])
        dynamic_info = ""
        for target, ruleset in ir.items():
            dynamic_info += f"  - 与 {target} 互动: {ruleset.get('dynamic', '无')}\n"

        section = (
            f"【{name}】\n"
            f"  语言风格(tone): {tone}\n"
            f"  禁止的对话模式: {', '.join(forbidden) if forbidden else '无'}\n"
            f"  行为禁区(must_not): {', '.join(must_not) if must_not else '无'}\n"
            f"  柔性约束(soft_limits): {', '.join(soft_limits) if soft_limits else '无'}\n"
        )
        if dynamic_info.strip():
            section += f"  互动规则:\n{dynamic_info}"
        character_sections.append(section)

    characters_block = "\n".join(character_sections)

    # ---- 提取黑名单 ----
    ai_words = bl.get("ai_flavoured_words", [])
    cliche_phrases = bl.get("cliche_phrases", [])
    blacklist_block = ""
    if ai_words:
        blacklist_block += "AI 色彩词汇（必须剔除/替换）:\n  " + "\n  ".join(ai_words) + "\n"
    if cliche_phrases:
        blacklist_block += "陈词滥调（必须剔除/替换）:\n  " + "\n  ".join(cliche_phrases) + "\n"

    # ---- 提取排版规则 ----
    spacing = fmt.get("spacing_rules", {})
    dialogue_rules = spacing.get("dialogue", {})
    scene_break = spacing.get("scene_break", {})
    whitespace_rules = spacing.get("whitespace", {})

    format_block = (
        f"段落规则: {spacing.get('paragraph', {}).get('line_spacing', '段落间空一行')}；"
        f"段落首行不缩进；连续单行段落不超过 "
        f"{spacing.get('paragraph', {}).get('max_consecutive_single_line_paragraphs', 3)} 个。\n"
        f"对白格式: {dialogue_rules.get('format', '使用「」包裹对话')}；"
        f"内心独白使用『』包裹；短信/消息使用【】包裹；"
        f"连续无归属对白不超过 {dialogue_rules.get('max_dialogue_lines_without_attribution', 4)} 行。\n"
        f"场景分隔: 使用 {scene_break.get('marker', '* * *')}，上下各空一行。\n"
        f"空白控制: 禁止超过 {whitespace_rules.get('no_consecutive_blank_lines', 2)} 个连续空行；"
        f"行尾空白必须移除。\n"
    )

    # ---- 提取英式拼写公约 ----
    spelling_standard = fmt.get("spelling_conventions", {}).get("standard", "British English")
    spelling_examples = fmt.get("spelling_conventions", {}).get("examples", {})
    spelling_items = "\n".join(
        f"  - {british} (不用 {american.split('not ')[-1].rstrip(')') if 'not ' in american else american})"
        for british, american in spelling_examples.items()
    )
    spelling_block = (
        f"拼写标准: 所有英文输出必须严格遵守 {spelling_standard}。\n"
        f"强制替换对照表:\n{spelling_items}\n"
    )

    # ---- 组装最终 Prompt ----
    system_prompt = (
        "你是一个无情的文本规范化引擎。你的唯一任务是严格按照以下规则清洗输入文本，"
        "输出清洗后的纯净 Markdown。你不得添加任何新的叙事内容，不得改写情节，"
        "不得对文本进行润色或文学性加工。你只做三件事：删除、替换、排版。\n\n"
        "=== 第〇部分：【最高指令】纯中文输出铁律 ===\n"
        "绝对禁止在小说正文中使用、保留或输出任何英文字母、英文单词或英文标点。"
        "文本必须是 100% 纯中文。如果原草稿中存在英文，"
        "请务必将其精准意译为符合中文网文语境的中文词汇，绝不能出现中英夹杂的情况。"
        "此规则优先级高于所有后续规则，任何与英文相关的排版或拼写规则均不得与此冲突。\n\n"
        "=== 第一部分：角色行为边界 ===\n"
        "以下规则定义了每个角色的语言风格、行为禁区与互动逻辑。"
        "清洗时必须确保文本中角色的言行不违反这些边界。"
        "若发现违规，将越界的句子替换为符合角色设定的等价表达，"
        "或将其标记为 [角色越界-待审查] 并保留原文。\n\n"
        f"{characters_block}\n"
        "=== 第二部分：文本净化 — 黑名单词汇与陈词滥调 ===\n"
        "以下词语和短语在小说文本中绝对不可出现。清洗时需执行以下操作：\n"
        "1. 对黑名单中的词汇/短语，用更自然、更符合角色语境的表达替换；\n"
        "2. 若无法找到自然替代，直接删除该词/短语并调整上下文使句子通顺；\n"
        "3. 不可使用近义但同样带有 AI 色彩或陈词滥调的词汇来替换。\n\n"
        f"{blacklist_block}\n"
        "=== 第三部分：排版与格式化规范 ===\n"
        "严格按照以下规则调整文本排版：\n"
        f"{format_block}\n"
        "=== 第四部分：英式拼写强制公约 ===\n"
        f"{spelling_block}\n"
        "=== 输出要求 ===\n"
        "1. 输出必须是完整的、可直接保存为 .md 文件的 Markdown 文本；\n"
        "2. 除上述规则要求的修改外，不得对原文做任何其他改动；\n"
        "3. 不要输出任何解释、说明或前后对比——只输出清洗后的最终文本。"
    )

    return system_prompt


def call_deepseek_api(system_prompt: str, draft_content: str) -> str:
    """调用 DeepSeek Chat API，发送清洗请求并返回清洗后的文本。"""
    api_key = os.environ.get("DEEPSEEK_API_KEY")
    if not api_key:
        print("[FATAL] 未设置环境变量 DEEPSEEK_API_KEY", file=sys.stderr)
        sys.exit(1)

    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    payload = {
        "model": DEEPSEEK_MODEL,
        "temperature": REQUEST_TEMPERATURE,
        "max_tokens": REQUEST_MAX_TOKENS,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": draft_content},
        ],
    }

    print(f"[INFO] 正在向 DeepSeek API ({DEEPSEEK_MODEL}) 发送清洗请求...")
    try:
        response = requests.post(
            DEEPSEEK_API_URL,
            headers=headers,
            json=payload,
            timeout=120,
        )
        response.raise_for_status()
    except requests.exceptions.Timeout:
        print("[FATAL] API 请求超时（120s）", file=sys.stderr)
        sys.exit(1)
    except requests.exceptions.RequestException as exc:
        print(f"[FATAL] API 请求失败: {exc}", file=sys.stderr)
        if hasattr(exc, "response") and exc.response is not None:
            print(f"[DEBUG] 响应体: {exc.response.text}", file=sys.stderr)
        sys.exit(1)

    result = response.json()

    # DeepSeek API 返回格式与 OpenAI 兼容：choices[0].message.content
    try:
        cleaned_text = result["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        print(f"[FATAL] 无法解析 API 返回结果: {exc}", file=sys.stderr)
        print(f"[DEBUG] 原始响应: {json.dumps(result, ensure_ascii=False, indent=2)}", file=sys.stderr)
        sys.exit(1)

    # 检查是否因 token 限制被截断
    finish_reason = result.get("choices", [{}])[0].get("finish_reason", "unknown")
    if finish_reason == "length":
        print("[WARN] 模型输出可能因 token 限制被截断，建议缩减草稿长度或提高 max_tokens", file=sys.stderr)

    usage = result.get("usage", {})
    print(
        f"[INFO] 清洗完成 — "
        f"prompt_tokens: {usage.get('prompt_tokens', 'N/A')}, "
        f"completion_tokens: {usage.get('completion_tokens', 'N/A')}, "
        f"finish_reason: {finish_reason}"
    )

    return cleaned_text.strip()


def read_draft(file_path: str) -> str:
    """读取指定路径的 Markdown 草稿文件。"""
    if not os.path.isfile(file_path):
        print(f"[FATAL] 草稿文件不存在: {file_path}", file=sys.stderr)
        sys.exit(1)
    with open(file_path, "r", encoding="utf-8") as fh:
        return fh.read()


def write_cleaned_text(file_path: str, text: str):
    """将清洗后的文本覆盖写入原文件。写入前在内容末尾追加一个空行以确保文件以换行符结尾。"""
    with open(file_path, "w", encoding="utf-8") as fh:
        fh.write(text)
        if not text.endswith("\n"):
            fh.write("\n")
    print(f"[INFO] 已覆写: {file_path}")


def main():
    parser = argparse.ArgumentParser(
        description="文本清洗引擎 — 基于 YAML 规则的 Markdown 草稿规范化"
    )
    parser.add_argument(
        "draft_file",
        help="待清洗的 Markdown 草稿文件路径（相对于仓库根目录或绝对路径）",
    )
    args = parser.parse_args()

    # ---------------------------------------------------------------------
    # Step 1: 加载规则
    # ---------------------------------------------------------------------
    print("[STEP 1/4] 加载 YAML 规则配置文件...")
    rules = load_all_configs()

    # ---------------------------------------------------------------------
    # Step 2: 组装 System Prompt
    # ---------------------------------------------------------------------
    print("[STEP 2/4] 组装 System Prompt...")
    system_prompt = build_system_prompt(rules)
    print(f"        System Prompt 已生成，共 {len(system_prompt)} 字符")

    # ---------------------------------------------------------------------
    # Step 3: 读取草稿
    # ---------------------------------------------------------------------
    print(f"[STEP 3/4] 读取草稿: {args.draft_file}")
    draft_content = read_draft(args.draft_file)
    print(f"        草稿共 {len(draft_content)} 字符，约 {len(draft_content) // 2} 个中文字符")

    # ---------------------------------------------------------------------
    # Step 4: 调用 API 并覆写
    # ---------------------------------------------------------------------
    print("[STEP 4/4] 调用 DeepSeek API 执行清洗...")
    cleaned = call_deepseek_api(system_prompt, draft_content)
    write_cleaned_text(args.draft_file, cleaned)

    print("\n[DONE] 文本清洗流水线执行完毕。")


if __name__ == "__main__":
    main()
