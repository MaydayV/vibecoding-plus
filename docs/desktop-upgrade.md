# VibeCoding Plus macOS Desktop App 升级文档

## 目标
将现有 Electron 桌面应用升级为完整的 macOS 原生客户端（.app / .dmg），集成服务器管理、设备连接监控和管理面板全部功能。

## 现状分析
- 已有 Electron 应用框架（main.mjs / renderer.js / index.html）
- 已有系统托盘、服务启停、配置管理
- 已有 WebSocket 连接服务器获取实时状态
- **缺失**：macOS 构建配置、设备状态监控、管理面板功能

## 需求清单

### P0 - 必须实现
1. **macOS 打包**：electron-builder 生成 .dmg，双击安装运行
2. **设备连接状态**：显示已连接设备列表（设备 ID、板型、IP、连接时间）
3. **服务运行指标**：STT 状态、发现服务状态、WebSocket 端口、活跃连接数
4. **管理面板内嵌**：待办管理、显示配置、苹果提醒同步、环境变量编辑

### P1 - 应该实现
5. **设备状态实时刷新**：WebSocket 推送设备上下线事件
6. **日志查看器**：服务日志 + 设备日志分类展示
7. **一键重连设备**：从桌面端触发设备重新发现

### P2 - 可以实现
8. **深色/浅色主题切换**
9. **全局快捷键**：一键启动/停止服务
10. **通知中心集成**：设备断连时系统通知

## 技术方案

### macOS 打包
- package.json 增加 `mac` target（dmg + zip）
- 配置 icon（icns）、bundle ID、签名
- 支持 arm64 + x64 universal

### 设备状态监控
- 主进程通过 WebSocket 连接 bridge，监听 `client_list` 事件
- 新增 IPC: `desktop:get-devices` 获取设备列表
- renderer 渲染设备卡片（ID、板型、IP、信号、电量）

### 管理面板集成
- 用 BrowserView 加载 `http://127.0.0.1:{port}/admin`
- 主进程代理 admin API 请求（避免 CSP 限制）
- 新增 IPC: `desktop:admin-api` 转发管理 API

## 文件变更清单
- `package.json` — 增加 mac 构建配置
- `desktop/main.mjs` — 增加设备状态 IPC、管理 API 代理
- `desktop/preload.cjs` — 暴露新 API
- `desktop/index.html` — 增加设备状态面板、管理标签页
- `desktop/renderer.js` — 设备状态渲染、管理页交互
- `desktop/styles.css` — 新增样式
