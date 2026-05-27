import os
import json
import requests
from pathlib import Path
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
KNOWLEDGE_DIR = BASE_DIR / "00_Knowledge"
STATE_FILE = BASE_DIR / "01_State" / "current_status.json"
DRAFTS_DIR = BASE_DIR / "02_Drafts"

load_dotenv(BASE_DIR / "scripts" / ".env")

API_KEY = os.getenv("DEEPSEEK_API_KEY")
API_URL = "https://api.deepseek.com/v1/chat/completions"


def read_knowledge_files():
    knowledge = {}
    for md_file in KNOWLEDGE_DIR.glob("*.md"):
        knowledge[md_file.stem] = md_file.read_text(encoding="utf-8")
    return knowledge


def read_state():
    with open(STATE_FILE, "r", encoding="utf-8") as f:
        return json.load(f)


def build_prompt(knowledge, state):
    world_setting = knowledge.get("world_setting", "")
    characters = knowledge.get("characters", "")
    main_outline = knowledge.get("main_outline", "")
    chapter = state.get("current_chapter", 1)
    protagonist = state.get("protagonist", {})
    recent_events = state.get("recent_events", [])
    unresolved_threads = state.get("unresolved_threads", [])

    system_prompt = (
        "你是一位专业的小说作者。\n"
        "请严格遵循以下创作准则：\n"
        "1. 禁用一切AI陈词滥调，包括但不限于'仿佛在诉说''命运的齿轮''心中涌起一股暖流'等。\n"
        "2. 用具体的感官细节（视觉、听觉、触觉、嗅觉）和动作来暗示情绪，绝对不要直接描述情绪。\n"
        "3. 对话必须短促、口语化，不同角色要有明显不同的说话习惯和语气词，禁止用对话交代背景信息。\n"
        "4. 行文节奏紧凑，段落不超过4行，避免大段心理描写。\n"
        "5. 允许句式不完美、有瑕疵，追求真实的手感，像人类讲述，不要过于工整。"
    )

    user_prompt = (
        f"## 世界观设定\n{world_setting}\n\n"
        f"## 角色设定\n{characters}\n\n"
        f"## 故事大纲\n{main_outline}\n\n"
        f"## 当前状态\n"
        f"当前章节：第{chapter}章\n"
        f"主角：{protagonist.get('name', '未知')}\n"
        f"物理状态：{protagonist.get('physical_state', '未知')}\n"
        f"位置：{protagonist.get('location', '未知')}\n"
        f"近期事件：{json.dumps(recent_events, ensure_ascii=False)}\n"
        f"未解决线索：{json.dumps(unresolved_threads, ensure_ascii=False)}\n\n"
        f"请根据以上设定和当前状态，撰写第{chapter}章的正文内容。"
    )

    return system_prompt, user_prompt


def call_deepseek_api(system_prompt, user_prompt):
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json",
    }
    payload = {
        "model": "deepseek-chat",
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "stream": False,
    }
    response = requests.post(API_URL, headers=headers, json=payload)
    response.raise_for_status()
    return response.json()["choices"][0]["message"]["content"]


def save_chapter(content, chapter_number):
    DRAFTS_DIR.mkdir(parents=True, exist_ok=True)
    filename = f"chapter_{chapter_number:04d}.md"
    filepath = DRAFTS_DIR / filename
    filepath.write_text(content, encoding="utf-8")


def main():
    knowledge = read_knowledge_files()
    state = read_state()
    system_prompt, user_prompt = build_prompt(knowledge, state)
    chapter_content = call_deepseek_api(system_prompt, user_prompt)
    save_chapter(chapter_content, state["current_chapter"])
    print(f"第{state['current_chapter']}章已生成并保存。")


if __name__ == "__main__":
    main()
