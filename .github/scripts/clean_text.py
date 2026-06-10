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
REQUEST_TEMPERATURE = 0.3          # 低温度，保证遵循规则但允许必要的内容保留判断
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
        "你是一个小说文本规范化引擎。你的唯一任务是严格按照以下规则清洗输入文本，"
        "输出清洗后的纯净 Markdown。\n\n"
        "【最高优先级 — 内容保留铁律】\n"
        "1. 绝对禁止删减、压缩或改写任何情节内容、场景描写、对话、心理活动和叙述细节。\n"
        "2. 清洗后的文本必须保留原文 100% 的情节信息量，只允许做字词级的替换和排版调整。\n"
        "3. 如果一段文字没有任何需要修正的问题，请原封不动地保留。\n"
        "4. 每删一个字之前先问自己：这个字是否属于以下规则明确要求删除的类别？如果不是，保留。\n\n"
        "=== 第〇部分：【最高指令】100% 纯中文输出铁律 ===\n"
        "绝对禁止在小说正文中使用、保留或输出任何英文字母、英文单词或英文标点（包括但不限于"
        "单个英文字母如 A/B/C，英文缩写如 OK/OK，英文标点如逗号句号引号）。"
        "如果原草稿中存在英文，请务必将其精准意译为符合中文语境的中文词汇。"
        "此规则优先级高于所有后续规则。\n\n"
        "=== 第一部分：角色行为边界 ===\n"
        "以下规则定义了每个角色的语言风格与行为禁区。"
        "清洗时若发现角色言行越界，用符合角色设定的等价中文表达替换，"
        "不得删除整段内容。\n\n"
        f"{characters_block}\n"
        "=== 第二部分：文本净化 — 黑名单与陈词滥调（仅字词级替换）===\n"
        "清洗时只需对以下词汇/短语执行字词级替换（换词不换意），"
        "不得因为替换而删除整句或整段。\n"
        "1. 对黑名单词汇，用更自然的中文表达替换该词，保留句子其余部分；\n"
        "2. 若无法找到自然替代，将该词标记为【※】保留原文，不做删除；\n"
        "3. 不可用同样带有 AI 色彩或陈词滥调的词汇来替换。\n\n"
        f"{blacklist_block}\n"
        "=== 第三部分：排版与格式化规范 ===\n"
        f"{format_block}\n"
        "=== 第四部分：英式拼写强制公约 ===\n"
        f"{spelling_block}\n"
        "=== 输出要求 ===\n"
        "1. 输出必须是完整的 Markdown 文本，长度应接近原文，不得大幅缩水；\n"
        "2. 除上述规则明确要求的字词级修改和排版调整外，保留原文全部内容；\n"
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
