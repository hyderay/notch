<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="Notch 应用图标">
</p>

<p align="center">
  <a href="README.md">English</a> | 简体中文
</p>

# Notch

[![CI](https://github.com/hyderay/notch/actions/workflows/ci.yml/badge.svg)](https://github.com/hyderay/notch/actions/workflows/ci.yml)
[![最新版本](https://img.shields.io/github/v/release/hyderay/notch?display_name=tag)](https://github.com/hyderay/notch/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)](https://github.com/hyderay/notch)

在 MacBook 刘海中实时显示 Codex CLI 和 Claude Code 的工作状态。

<p align="center">
  <img src="Resources/NotchExpanded.png" width="760" alt="Notch 展示 Codex CLI 和 Claude Code 会话">
</p>

当 Codex CLI 或 Claude Code 工作时，刘海区域会显示状态环、运行时间和任务数量。鼠标悬停后展开会话列表，展示每个任务的当前操作、状态和耗时；没有任务运行时，界面会完全隐藏。

双指向刘海方向推动可隐藏界面，在顶部中央区域向反方向滑动可重新显示。手势可在菜单栏中关闭。

## 功能

- 自动跟踪 Codex CLI 和 Claude Code 本地会话
- 显示并发任务、当前操作、运行时间和权限请求
- 原生集成 MacBook 硬件刘海
- 可选 Agent Hooks，提供更精确的状态更新
- 提供本地 `notchctl` 命令行接口
- 所有数据保留在本机，无账户、分析统计或网络请求

## 系统要求

- macOS 14 或更高版本
- 带硬件摄像头刘海的 MacBook 显示屏
- 可选：[Codex CLI](https://github.com/openai/codex) 和/或 [Claude Code](https://claude.com/claude-code)

## 安装

### Homebrew

```bash
brew install --cask hyderay/tap/notch
xattr -dr com.apple.quarantine /Applications/Notch.app
```

当前发布版本使用临时签名，因此首次启动前需要执行第二条命令。

### 下载发布版本

1. 从 [最新 Release](https://github.com/hyderay/notch/releases/latest) 下载 `Notch-v*-macOS.zip`。
2. 解压并将 `Notch.app` 移动到 `/Applications`。
3. 在 Finder 中打开 Notch，或运行 `open -a Notch`。

如果 Gatekeeper 阻止首次启动，可右键应用并选择“打开”，或运行：

```bash
xattr -dr com.apple.quarantine /Applications/Notch.app
```

### 从源码构建

```bash
git clone https://github.com/hyderay/notch.git
cd notch
make install
open -a Notch
```

`make install` 会将 `Notch.app` 安装到 `/Applications`，并将 `notchctl` 链接到 `~/.local/bin`。

## 工作原理

默认情况下，Notch 增量读取 Agent 已经写入本地的会话记录：

| Agent | 监控位置 |
| --- | --- |
| Codex CLI | `~/.codex/sessions/**/rollout-*.jsonl` |
| Claude Code | `~/.claude/projects/**/*.jsonl` |

文件监控由 FSEvents 触发，空闲时不轮询。仅处理最近活动的会话，并在任务完成后自动清理显示状态。

安装可选 Hooks 可获得更精确的工具名称、任务边界和权限等待状态：

```bash
notchctl install-hooks
```

安装程序只追加配置并保留备份。撤销 Hooks：

```bash
notchctl uninstall-hooks
```

## notchctl

任何本地工具都可以向 Notch 推送状态：

```bash
notchctl working --agent codex --session build-42 --title my-app --detail "swift build"
notchctl waiting --agent codex --session build-42 --detail "等待确认"
notchctl done    --agent codex --session build-42
notchctl remove  --agent codex --session build-42
```

常用命令：

| 命令 | 用途 |
| --- | --- |
| `notchctl status` | 查看当前显示的会话 |
| `notchctl inspect` | 查看刘海几何与界面状态 |
| `notchctl doctor` | 检查 Socket、Agent 和 Hooks |
| `notchctl demo` | 演示所有界面状态 |
| `notchctl ping` | 检查应用是否正在运行 |

## 隐私

Notch 只读取本机已有的会话文件，状态仅保存在内存中，不会建立网络连接。IPC Socket 位于权限为 `0700` 的目录中，文件权限为 `0600`，仅允许本地访问。

## 开发

```bash
make build
make app
make install
make check-resources
```

项目使用 SwiftPM 构建，不需要完整 Xcode。架构、性能数据和实现细节请阅读英文版 [DESIGN.md](DESIGN.md) 与 [README.md](README.md)。
