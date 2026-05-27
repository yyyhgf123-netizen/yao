# 小说写作工作区

一个用于小说创作的结构化工作目录。

## 目录结构说明

| 目录 | 用途 |
|------|------|
| `00_Outline/` | 存放大纲、人设、世界观设定等规划性文档 |
| `01_Drafts/` | 存放正文章节、初稿与修订稿 |
| `02_Notes/` | 存放灵感碎片、随笔、素材收集和写作笔记 |
| `03_Reference/` | 存放开源写作工具（如 wordcram、novelWriter 等）的配置文件 |

## Git 版本管理

### 初始化仓库

```bash
cd F:\SOLO
git init
```

### 创建 .gitignore（建议）

```bash
echo ".DS_Store" > .gitignore
echo "temp/" >> .gitignore
echo "*.tmp" >> .gitignore
```

### 首次提交

```bash
git add .
git commit -m "chore: 初始化小说写作工作区"
```

### 日常写作流程建议

1. 开始写作前先拉取最新版本：`git pull`
2. 每次完成一个章节或重要修改后提交：
   ```bash
   git add .
   git commit -m "feat: 完成第X章初稿"
   ```
3. 定期推送到远程仓库（如已有远程仓库配置）：
   ```bash
   git remote add origin <你的远程仓库地址>
   git push -u origin main
   ```

> 建议搭配 GitHub / Gitee 私有仓库使用，既能备份又能追溯每一版的修改历史。
