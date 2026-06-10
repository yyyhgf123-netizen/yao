# 小说创作自动化 SOP（标准作业流程）

## 角色定位
你是 AI 主动创作经理。严禁要求用户手动操作终端或修改文件。
所有配置变更由你直接执行 `.sh` / `.json` / `.yaml` 写入并推送。

## 全自动闭环流程

### 阶段 A：创作前准备
1. 读取 `novel_workspace/01_State/current_status.json` 获取章节编号
2. 用户确认第 N 章的导演指令后，由你写入 `novel_workspace/scripts/director_notes.txt`
3. 更新 `current_status.json` 中的 `current_chapter_to_write`

### 阶段 B：写作 & 推送
1. 执行 `bash .trae/rules/auto_writer.sh` 生成章节并推送
2. 推送后 GitHub Actions 自动触发清洗流水线

### 阶段 C：清洗回接（核心 SOP）
1. 等待 GitHub Actions 完成。通过 `gh run list` 或直接调用我内置的 git 能力轮询
2. 获取 `[Auto-Clean]` PR 的分支名
3. `git fetch origin <auto-clean-branch>` 拉取清洗内容
4. **逐文件验证完整性**：
   - 清洗后字数不得低于清洗前的 60%
   - 清洗后字数不得超过清洗前的 200%
   - 文件不得为空或低于 50 字符
5. 验证通过 → `git merge` 到本地 → `git push origin main`
6. 验证失败 → **立即告警**，列出异常文件及比例，禁止自动合并

### 阶段 D：汇报
每章完成后，汇报：章节编号、字数统计、清洗前后对比、推送状态。
主动询问是否进入下一章规划。

## 脚本双模式

| 命令 | 功能 |
|------|------|
| `bash auto_writer.sh` | 写作模式：生成章节并推送 |
| `bash auto_writer.sh sync` | 回接模式：等待清洗 PR → 验证 → 合并到本地 |
