#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WS_DIR="$REPO_ROOT/novel_workspace"

STATE_FILE="$WS_DIR/01_State/current_status.json"
KNOWLEDGE_DIR="$WS_DIR/00_Knowledge"
DIRECTOR_NOTES="$WS_DIR/scripts/director_notes.txt"
DRAFTS_DIR="$WS_DIR/02_Drafts"
ENV_FILE="$WS_DIR/scripts/.env"

DEEPSEEK_API_URL="https://api.deepseek.com/chat/completions"
DEEPSEEK_MODEL="deepseek-chat"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${RED}[WARN]${NC} $*"; }
log_title() { echo -e "${CYAN}$*${NC}"; }

# ---------------------------------------------------------------------------
# 加载环境变量（API Key）
# ---------------------------------------------------------------------------
load_env() {
    if [ -f "$ENV_FILE" ]; then
        set -a
        source "$ENV_FILE"
        set +a
    fi
    if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
        log_warn "DEEPSEEK_API_KEY 未设置，请检查 $ENV_FILE"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 读取当前写作状态
# ---------------------------------------------------------------------------
read_state() {
    local chapter
    local protag_name
    local protag_state
    local protag_loc
    local recent_events
    local unresolved

    chapter=$(jq -r '.current_chapter_to_write // .current_chapter' "$STATE_FILE")
    protag_name=$(jq -r '.protagonist.name' "$STATE_FILE")
    protag_state=$(jq -r '.protagonist.physical_state' "$STATE_FILE")
    protag_loc=$(jq -r '.protagonist.location' "$STATE_FILE")
    recent_events=$(jq -r '.recent_events | join("\n")' "$STATE_FILE")
    unresolved=$(jq -r '.unresolved_threads | join("\n")' "$STATE_FILE")

    CHAPTER_NUM="$chapter"
    PROTAG_NAME="$protag_name"
    PROTAG_STATE="$protag_state"
    PROTAG_LOC="$protag_loc"
    RECENT_EVENTS="$recent_events"
    UNRESOLVED="$unresolved"
}

# ---------------------------------------------------------------------------
# 组装 System Prompt
# ---------------------------------------------------------------------------
build_system_prompt() {
    cat << 'PROMPT_EOF'
你是一位专业的小说作者。
请严格遵循以下创作准则：
1. 禁用一切AI陈词滥调，包括但不限于"仿佛在诉说""命运的齿轮""心中涌起一股暖流"等。
2. 用具体的感官细节（视觉、听觉、触觉、嗅觉）和动作来暗示情绪，绝对不要直接描述情绪。
3. 对话必须短促、口语化，不同角色要有明显不同的说话习惯和语气词，禁止用对话交代背景信息。
4. 行文节奏紧凑，段落不超过4行，避免大段心理描写。
5. 允许句式不完美、有瑕疵，追求真实的手感，像人类讲述，不要过于工整。
6. 严格符合人物设定，不允许OOC。
7. 本文是都市校园小甜文，尽量写的甜蜜一些。
8. 绝对禁止在小说正文中使用英文字母、英文单词或英文标点，必须是100%纯中文。
PROMPT_EOF
}

# ---------------------------------------------------------------------------
# 组装 User Prompt（草稿上下文）
# ---------------------------------------------------------------------------
build_user_prompt() {
    local chapter="$1"
    local protag_name="$2"
    local protag_state="$3"
    local protag_loc="$4"
    local recent_events="$5"
    local unresolved="$6"

    local world_setting chars_setting main_outline director_notes
    world_setting=$(cat "$KNOWLEDGE_DIR/world_setting.md" 2>/dev/null || echo "")
    chars_setting=$(cat "$KNOWLEDGE_DIR/characters.md" 2>/dev/null || echo "")
    main_outline=$(cat "$KNOWLEDGE_DIR/main_outline.md" 2>/dev/null || echo "")
    director_notes=$(cat "$DIRECTOR_NOTES" 2>/dev/null || echo "")

    cat << USER_EOF
## 世界观设定
$world_setting

## 角色设定
$chars_setting

## 故事大纲
$main_outline

## 导演笔记（本章专属指令，优先级最高）
$director_notes

## 当前写作状态
当前章节：第${chapter}章
主角：${protag_name}
物理状态：${protag_state}
位置：${protag_loc}

## 近期事件
${recent_events}

## 未解决线索
${unresolved}

请根据以上设定和指令，撰写第${chapter}章的正文内容。
USER_EOF
}

# ---------------------------------------------------------------------------
# 调用 DeepSeek API
# ---------------------------------------------------------------------------
call_deepseek_api() {
    local system_prompt="$1"
    local user_prompt="$2"

    local payload
    payload=$(jq -n \
        --arg model "$DEEPSEEK_MODEL" \
        --arg system "$system_prompt" \
        --arg user "$user_prompt" \
        '{
            model: $model,
            temperature: 0.7,
            max_tokens: 8192,
            messages: [
                {role: "system", content: $system},
                {role: "user", content: $user}
            ],
            stream: false
        }')

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "$DEEPSEEK_API_URL" \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --connect-timeout 30 \
        --max-time 300)

    local http_code
    http_code=$(echo "$response" | tail -n 1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" != "200" ]; then
        log_warn "API 请求失败，HTTP 状态码: $http_code"
        echo "$body" | jq '.' 2>/dev/null || echo "$body"
        exit 1
    fi

    echo "$body" | jq -r '.choices[0].message.content'
}

# ---------------------------------------------------------------------------
# 保存章节
# ---------------------------------------------------------------------------
save_chapter() {
    local content="$1"
    local chapter="$2"
    local filename
    filename=$(printf "chapter_%04d.md" "$chapter")
    local filepath="$DRAFTS_DIR/$filename"

    mkdir -p "$DRAFTS_DIR"
    echo "$content" > "$filepath"
    echo "$filepath"
}

# ---------------------------------------------------------------------------
# Git 自动化
# ---------------------------------------------------------------------------
git_auto_push() {
    local filepath="$1"
    local chapter="$2"

    cd "$REPO_ROOT"

    if ! git diff --quiet -- "$filepath" 2>/dev/null && \
       ! git diff --cached --quiet -- "$filepath" 2>/dev/null; then
        :
    else
        if [ -z "$(git status --porcelain -- "$filepath" 2>/dev/null)" ]; then
            log_info "文件无变更，跳过 Git 操作。"
            return 0
        fi
    fi

    git add "$filepath"
    git commit -m "feat: 自动生成第 ${chapter} 章"
    git push origin main
    log_info "第 ${chapter} 章已推送到远端。"
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    log_title "============================================================"
    log_title "  📚 自动写作引擎 — 第 $(jq -r '.current_chapter_to_write // .current_chapter' "$STATE_FILE") 章"
    log_title "============================================================"

    load_env
    log_info "已加载 API 密钥。"

    read_state
    log_info "当前章节: 第 ${CHAPTER_NUM} 章"
    log_info "主角: ${PROTAG_NAME}"

    local system_prompt
    system_prompt=$(build_system_prompt)

    log_info "正在组装 User Prompt..."
    local user_prompt
    user_prompt=$(build_user_prompt \
        "$CHAPTER_NUM" \
        "$PROTAG_NAME" \
        "$PROTAG_STATE" \
        "$PROTAG_LOC" \
        "$RECENT_EVENTS" \
        "$UNRESOLVED")

    log_info "正在调用 DeepSeek API 生成章节正文..."
    local content
    content=$(call_deepseek_api "$system_prompt" "$user_prompt")

    if [ -z "$content" ]; then
        log_warn "API 返回内容为空。"
        exit 1
    fi

    local saved_path
    saved_path=$(save_chapter "$content" "$CHAPTER_NUM")
    log_info "章节已保存: $saved_path (${#content} 字符)"

    log_info "正在提交并推送到 GitHub..."
    git_auto_push "$saved_path" "$CHAPTER_NUM"

    log_title "============================================================"
    log_title "  ✅ 第 ${CHAPTER_NUM} 章自动写作完毕。"
    log_title "============================================================"
}

main "$@"
