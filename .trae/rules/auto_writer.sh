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
# JSON 解析辅助（用 Python 替代 jq）
# ---------------------------------------------------------------------------
json_get() {
    local file="$1" key="$2" default="${3:-}"
    python -c "
import json,sys
with open('$file', encoding='utf-8') as f:
    data = json.load(f)
keys = '$key'.split(' // ')
for k in keys:
    try:
        parts = k.split('.')
        val = data
        for p in parts: val = val[p]
        print(val)
        break
    except (KeyError, TypeError):
        continue
else:
    print('$default')
" 2>/dev/null || echo "$default"
}

json_get_arr() {
    local file="$1" key="$2"
    python -c "
import json
with open('$file', encoding='utf-8') as f:
    data = json.load(f)
for p in '$key'.split('.'):
    data = data[p]
if isinstance(data, list):
    for item in data: print(item)
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 读取当前写作状态
# ---------------------------------------------------------------------------
read_state() {
    CHAPTER_NUM=$(json_get "$STATE_FILE" "current_chapter_to_write // current_chapter" "1")
    PROTAG_NAME=$(json_get "$STATE_FILE" "protagonist.name" "未知")
    PROTAG_STATE=$(json_get "$STATE_FILE" "protagonist.physical_state" "")
    PROTAG_LOC=$(json_get "$STATE_FILE" "protagonist.location" "")
    RECENT_EVENTS=$(json_get_arr "$STATE_FILE" "recent_events")
    UNRESOLVED=$(json_get_arr "$STATE_FILE" "unresolved_threads")
}

# ---------------------------------------------------------------------------
# 组装 System Prompt（从 system_prompt.txt 读取）
# ---------------------------------------------------------------------------
build_system_prompt() {
    cat "$WS_DIR/scripts/system_prompt.txt"
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
    local tmp_dir="$REPO_ROOT/.trae"
    mkdir -p "$tmp_dir"

    printf '%s' "$system_prompt" > "$tmp_dir/tmp_sys.txt"
    printf '%s' "$user_prompt"  > "$tmp_dir/tmp_usr.txt"

    python -c "
import json
with open('$tmp_dir/tmp_sys.txt', encoding='utf-8') as f: sp = f.read()
with open('$tmp_dir/tmp_usr.txt', encoding='utf-8') as f: up = f.read()
payload = {
    'model': '$DEEPSEEK_MODEL',
    'temperature': 0.7,
    'max_tokens': 8192,
    'messages': [
        {'role': 'system', 'content': sp},
        {'role': 'user', 'content': up}
    ],
    'stream': False
}
with open('$tmp_dir/tmp_payload.json', 'w', encoding='utf-8') as f:
    json.dump(payload, f, ensure_ascii=False)
" 2>/dev/null

    if [ ! -f "$tmp_dir/tmp_payload.json" ]; then
        log_warn "无法构建 API 请求载荷，请确认 Python 已安装。"
        exit 1
    fi

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "$DEEPSEEK_API_URL" \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        -H "Content-Type: application/json" \
        -d @"$tmp_dir/tmp_payload.json" \
        --connect-timeout 30 \
        --max-time 300)

    local http_code
    http_code=$(echo "$response" | tail -n 1)
    local body
    body=$(echo "$response" | sed '$d')

    rm -f "$tmp_dir/tmp_payload.json" "$tmp_dir/tmp_sys.txt" "$tmp_dir/tmp_usr.txt"

    if [ "$http_code" != "200" ]; then
        log_warn "API 请求失败，HTTP 状态码: $http_code"
        echo "$body"
        exit 1
    fi

    echo "$body" | python -c "
import json, sys
data = json.load(sys.stdin)
print(data['choices'][0]['message']['content'])
" 2>/dev/null
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

# ---------------------------------------------------------------------------
# 等待清洗流水线完成并自动轮询 PR
# ---------------------------------------------------------------------------
poll_cleaning_pr() {
    local max_attempts="${1:-60}"
    local interval="${2:-30}"
    local attempt=0

    log_info "等待 GitHub Actions 清洗流水线触发..."
    sleep 10

    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))

        local pr_list
        pr_list=$(gh pr list --state open --search "[Auto-Clean]" --json number,headRefName --jq '.[].number' 2>/dev/null || true)

        if [ -n "$pr_list" ]; then
            local newest_pr
            newest_pr=$(echo "$pr_list" | sort -rn | head -n 1)
            log_info "检测到清洗 PR #${newest_pr}，流水线已完成。"
            echo "$newest_pr"
            return 0
        fi

        if [ $((attempt % 4)) -eq 0 ]; then
            log_info "仍在等待清洗流水线... (${attempt}/${max_attempts})"
        fi
        sleep "$interval"
    done

    log_warn "等待超时，未能检测到清洗 PR。"
    return 1
}

# ---------------------------------------------------------------------------
# 验证清洗后章节是否完整
# ---------------------------------------------------------------------------
verify_chapter_integrity() {
    local filepath="$1"
    local orig_chars="$2"

    if [ ! -f "$filepath" ]; then
        log_warn "验证失败：清洗后的文件不存在 ($filepath)"
        return 1
    fi

    local cleaned_chars
    cleaned_chars=$(wc -m < "$filepath" | tr -d ' ')

    if [ "$cleaned_chars" -lt 50 ]; then
        log_warn "验证失败：清洗后文件内容过短，疑似数据丢失 ($cleaned_chars 字符)"
        return 1
    fi

    local ratio
    ratio=$(awk "BEGIN {printf \"%.2f\", $cleaned_chars / $orig_chars}")

    # 清洗后字数不应低于原文的 60%，也不应超过 200%
    if awk "BEGIN {exit ($ratio < 0.6 || $ratio > 2.0) ? 0 : 1}"; then
        log_warn "验证失败：清洗前后字数比例异常 (${ratio})，疑似严重改动或截断。"
        log_warn "  清洗前: ${orig_chars} 字符"
        log_warn "  清洗后: ${cleaned_chars} 字符"
        return 1
    fi

    log_info "章节完整性验证通过 (比例: ${ratio}, 清洗前: ${orig_chars}, 清洗后: ${cleaned_chars})"
    return 0
}

# ---------------------------------------------------------------------------
# 获取并合并清洗后的章节到本地
# ---------------------------------------------------------------------------
sync_cleaned_chapters() {
    local pr_number="$1"
    shift
    local files=("$@")

    cd "$REPO_ROOT"

    local pr_branch
    pr_branch=$(gh pr view "$pr_number" --json headRefName --jq '.headRefName' 2>/dev/null)

    if [ -z "$pr_branch" ]; then
        log_warn "无法获取 PR #${pr_number} 的分支名。"
        return 1
    fi

    log_info "拉取清洗分支: $pr_branch"

    # 记录清洗前的字符数
    local char_counts=()
    local errors=0

    git fetch origin "$pr_branch" 2>/dev/null || {
        log_warn "无法拉取远端清洗分支 $pr_branch"
        return 1
    }

    # 逐文件验证再合并
    for file in "${files[@]}"; do
        if [ -f "$file" ]; then
            local orig_chars
            orig_chars=$(wc -m < "$file" | tr -d ' ')

            # 临时检出清洗版本验证
            local cleaned_content
            cleaned_content=$(git show "origin/$pr_branch:$file" 2>/dev/null || true)
            local cleaned_chars
            cleaned_chars=$(echo "$cleaned_content" | wc -m | tr -d ' ')

            if [ "$cleaned_chars" -lt 50 ]; then
                log_warn "[ERROR] $file: 清洗后内容过短 ($cleaned_chars 字符)，跳过此文件。"
                errors=$((errors + 1))
                continue
            fi

            local ratio
            ratio=$(awk "BEGIN {printf \"%.2f\", $cleaned_chars / $orig_chars}")

            if awk "BEGIN {exit ($ratio < 0.6 || $ratio > 2.0) ? 0 : 1}"; then
                log_warn "[ERROR] $file: 清洗前后比例异常 (${ratio})，跳过此文件。"
                log_warn "       清洗前 ${orig_chars} 字符 → 清洗后 ${cleaned_chars} 字符"
                errors=$((errors + 1))
                continue
            fi

            log_info "$file: 验证通过 (${orig_chars} → ${cleaned_chars}, 比例 ${ratio})"
        fi
        char_counts+=("$file:$orig_chars")
    done

    if [ "$errors" -gt 0 ]; then
        log_warn "============================================================"
        log_warn "  ⚠️  ${errors} 个文件未通过验证，拒绝自动合并。"
        log_warn "  请前往 GitHub PR #${pr_number} 手动审查。"
        log_warn "============================================================"
        return 1
    fi

    # 所有文件验证通过，执行合并
    local merge_branch="sync-cleaned-${pr_number}"
    git checkout -b "$merge_branch" 2>/dev/null
    git merge "origin/$pr_branch" --no-edit -m "merge: auto-clean sync from PR #${pr_number}" || {
        log_warn "合并冲突，请手动处理。"
        git merge --abort 2>/dev/null || true
        git checkout main 2>/dev/null || true
        git branch -D "$merge_branch" 2>/dev/null || true
        return 1
    }

    git checkout main 2>/dev/null || true
    git merge "$merge_branch" --no-edit || true
    git branch -D "$merge_branch" 2>/dev/null || true

    log_info "清洗内容已合并到本地。"
    return 0
}

# ---------------------------------------------------------------------------
# 主流程 — 选项：write（写作）或 sync（回接清洗内容）
# ---------------------------------------------------------------------------
main() {
    local mode="${1:-write}"

    cd "$REPO_ROOT"

    if [ "$mode" = "sync" ] || [ "$mode" = "full" ]; then
        log_title "============================================================"
        log_title "  🔄 清洗回接模式 — 等待 Actions → 验证 → 合并到本地"
        log_title "============================================================"

        local pr_number
        pr_number=$(poll_cleaning_pr 60 30)
        if [ -z "$pr_number" ]; then
            exit 1
        fi

        # 检测 PR 中改动的章节文件
        local pr_files
        pr_files=$(gh pr view "$pr_number" --json files --jq '.files[].path' 2>/dev/null | grep '^novel_workspace/02_Drafts/.*\.md$' || true)

        if [ -z "$pr_files" ]; then
            log_warn "未在 PR 中检测到章节文件变更。"
            exit 1
        fi

        local files_array=()
        while IFS= read -r f; do
            [ -n "$f" ] && files_array+=("$f")
        done <<< "$pr_files"

        if sync_cleaned_chapters "$pr_number" "${files_array[@]}"; then
            log_info "正在推送清洗结果到远端..."
            git push origin main
            log_title "============================================================"
            log_title "  ✅ 清洗内容已回接并推送。"
            log_title "============================================================"
        else
            log_warn "回接过程中出现错误，请手动检查。"
            exit 1
        fi

        return 0
    fi

    # ---- 默认：写作模式 ----
    log_title "============================================================"
    log_title "  📚 自动写作引擎 — 第 $(python -c "import json;f=open('$STATE_FILE',encoding='utf-8');d=json.load(f);print(d.get('current_chapter_to_write',d.get('current_chapter',1)))") 章"
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
