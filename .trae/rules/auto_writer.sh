#!/bin/bash
# =============================================================================
# auto_writer.sh — 全自动小说写作闭环脚本
# =============================================================================
# 触发方式：在终端执行 ./auto_writer.sh
# 前置依赖：git, GitHub CLI (gh)
#
# 流程：
#   Step 1 → git add . + git commit + git push
#   Step 2 → 循环嗅探 GitHub Actions 流水线状态，等待完成
#   Step 3 → 查找流水线创建的 PR，自动 squash 合并
#   Step 4 → git pull origin main，更新本地仓库
#   Step 5 → 打印最新定稿内容供预览
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BRANCH="main"
MAX_POLL_ATTEMPTS=60
POLL_INTERVAL=30

cd "$REPO_DIR"

# ---------------------------------------------------------------------------
# 检查前置依赖
# ---------------------------------------------------------------------------
check_prerequisites() {
    if ! command -v gh &> /dev/null; then
        echo "[ERROR] GitHub CLI (gh) 未安装。"
        echo "       请执行: winget install --id GitHub.cli"
        echo "       或访问: https://cli.github.com/"
        exit 1
    fi

    if ! gh auth status &> /dev/null; then
        echo "[ERROR] GitHub CLI 未登录。请执行: gh auth login"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Step 1 — 自动推送
# ---------------------------------------------------------------------------
auto_push() {
    echo "============================================================"
    echo "  Step 1/5 — 自动提交 & 推送"
    echo "============================================================"

    if ! git diff --quiet || ! git diff --cached --quiet; then
        git add .
        TIMESTAMP=$(date "+%Y-%m-%d %H:%M")
        git commit -m "auto: ${TIMESTAMP}"
        echo "[INFO] 已提交本地变更。"
    else
        echo "[INFO] 无新增变更，跳过提交。"
    fi

    echo "[INFO] 推送到 origin/${BRANCH} ..."
    git push origin "$BRANCH"
    echo "[INFO] 推送完成。"
}

# ---------------------------------------------------------------------------
# Step 2 — 监控流水线，等待完成
# ---------------------------------------------------------------------------
monitor_pipeline() {
    echo ""
    echo "============================================================"
    echo "  Step 2/5 — 嗅探 GitHub Actions 流水线状态"
    echo "============================================================"

    local attempt=0
    local run_id=""

    # 先等几秒让 Actions 触发
    sleep 5

    # 获取最新 run ID
    while [ -z "$run_id" ] && [ $attempt -lt 5 ]; do
        run_id=$(gh run list --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)
        if [ -z "$run_id" ]; then
            echo "[INFO] 等待流水线触发... ($((attempt + 1))/5)"
            sleep 5
            attempt=$((attempt + 1))
        fi
    done

    if [ -z "$run_id" ]; then
        echo "[ERROR] 未能获取流水线 ID，请手动检查 GitHub Actions。"
        exit 1
    fi

    echo "[INFO] 检测到流水线 Run ID: $run_id"
    echo "       监控地址: https://github.com/yyyhgf123-netizen/yao/actions/runs/$run_id"

    # 轮询等待流水线完成
    attempt=0
    while true; do
        local status
        local conclusion
        status=$(gh run view "$run_id" --json status --jq '.status' 2>/dev/null || echo "unknown")
        conclusion=$(gh run view "$run_id" --json conclusion --jq '.conclusion' 2>/dev/null || echo "unknown")

        echo "       [$attempt] 状态: $status | 结论: $conclusion"

        if [ "$status" = "completed" ]; then
            if [ "$conclusion" = "success" ]; then
                echo ""
                echo "[SUCCESS] 流水线执行成功！"
                return 0
            else
                echo ""
                echo "[FAIL] 流水线执行失败 (conclusion: $conclusion)。"
                echo "       请前往 Actions 查看详情:"
                echo "       https://github.com/yyyhgf123-netizen/yao/actions/runs/$run_id"
                exit 1
            fi
        fi

        attempt=$((attempt + 1))
        if [ $attempt -ge $MAX_POLL_ATTEMPTS ]; then
            echo "[ERROR] 等待超时，流水线仍未完成。"
            exit 1
        fi

        echo "       等待 ${POLL_INTERVAL}s ..."
        sleep $POLL_INTERVAL
    done
}

# ---------------------------------------------------------------------------
# Step 3 — 自动合并 PR
# ---------------------------------------------------------------------------
auto_merge_pr() {
    echo ""
    echo "============================================================"
    echo "  Step 3/5 — 查找 & 自动合并 Pull Request"
    echo "============================================================"

    local pr_list
    pr_list=$(gh pr list --state open --label "auto-clean" --json number,title,headRefName --limit 5 2>/dev/null || true)

    if [ -z "$pr_list" ] || [ "$pr_list" = "[]" ]; then
        # 尝试按分支名查找
        pr_list=$(gh pr list --state open --search "auto-clean" --json number,title,headRefName --limit 5 2>/dev/null || true)
    fi

    if [ -z "$pr_list" ] || [ "$pr_list" = "[]" ]; then
        # 尝试按标题查找
        pr_list=$(gh pr list --state open --search "[Auto-Clean]" --json number,title,headRefName --limit 5 2>/dev/null || true)
    fi

    if [ -z "$pr_list" ] || [ "$pr_list" = "[]" ]; then
        echo "[INFO] 未找到待合并的 PR（可能清洗未产生变更，或 PR 尚未创建）。"
        echo "       跳过合并步骤。"
        return 0
    fi

    # 取第一个匹配的 PR
    local pr_number
    pr_number=$(echo "$pr_list" | gh pr list --state open --search "[Auto-Clean]" --json number --jq '.[0].number' 2>/dev/null)

    if [ -z "$pr_number" ]; then
        echo "[INFO] 无法解析 PR 编号，跳过合并。"
        return 0
    fi

    echo "[INFO] 找到 PR #${pr_number}，正在自动 squash 合并..."
    gh pr merge "$pr_number" --squash --delete-branch --admin 2>&1 || {
        echo "[WARN] 自动合并失败，可能是权限或冲突问题。"
        echo "       请手动合并: gh pr merge $pr_number --squash"
        return 1
    }

    echo "[INFO] PR #${pr_number} 已合并。"
}

# ---------------------------------------------------------------------------
# Step 4 — 拉取最新定稿
# ---------------------------------------------------------------------------
pull_latest() {
    echo ""
    echo "============================================================"
    echo "  Step 4/5 — 拉取最新定稿"
    echo "============================================================"

    git pull origin "$BRANCH"
    echo "[INFO] 本地仓库已更新至最新。"
}

# ---------------------------------------------------------------------------
# Step 5 — 展示清洗后的定稿内容
# ---------------------------------------------------------------------------
show_cleaned_drafts() {
    echo ""
    echo "============================================================"
    echo "  Step 5/5 — 最新定稿内容预览"
    echo "============================================================"

    local drafts_dir="01_Drafts"
    if [ ! -d "$drafts_dir" ]; then
        echo "[INFO] 01_Drafts 目录不存在。"
        return 0
    fi

    local files
    files=$(find "$drafts_dir" -name "*.md" -type f | sort)

    if [ -z "$files" ]; then
        echo "[INFO] 01_Drafts 目录下无草稿文件。"
        return 0
    fi

    for file in $files; do
        echo ""
        echo "────────────────────────────────────────────────────────────"
        echo "  📄 $file"
        echo "────────────────────────────────────────────────────────────"
        cat "$file"
        echo ""
    done
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║       📚 全自动小说写作闭环系统 v1.0                     ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    check_prerequisites
    auto_push
    monitor_pipeline
    auto_merge_pr
    pull_latest
    show_cleaned_drafts

    echo "════════════════════════════════════════════════════════════"
    echo "  ✅ 全自动闭环执行完毕。"
    echo "════════════════════════════════════════════════════════════"
}

main "$@"
