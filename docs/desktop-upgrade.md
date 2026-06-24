# VibeCoding Plus macOS Desktop App 升级文档

## 目标
将现有 Electron 桌面应用升级为完整的 macOS 原生客户端（.app / .dmg），集成服务器管理、设备连接监控和管理面板全部功能。

## 需求清单

### P0 - 必须实现
1. **macOS 打包** — ✅ COMPLETE — electron-builder 生成 .dmg，arm64+x64 双架构
2. **设备连接状态** — ✅ COMPLETE — 设备 ID、板型、IP、连接时间
3. **服务运行指标** — ✅ COMPLETE — STT 状态、发现服务状态、端口、活跃连接数
4. **管理面板内嵌** — ✅ COMPLETE — 待办管理、显示配置、苹果提醒同步、环境变量编辑

### P1 - 应该实现
5. **设备状态实时刷新** — ✅ COMPLETE — WebSocket 推送设备上下线事件
6. **日志查看器** — ✅ COMPLETE — 服务日志 + 设备日志分类过滤
7. **一键重连设备** — ✅ COMPLETE — UDP 广播触发设备重新发现

### P2 - 可以实现
8. **深色/浅色主题切换** — ✅ COMPLETE — localStorage 持久化
9. **全局快捷键** — ✅ COMPLETE — Cmd+Shift+V 一键切换服务
10. **通知中心集成** — ✅ COMPLETE — 设备断开时系统通知

## 构建产物
- `dist-desktop/VibeCoding Plus-0.2.11-arm64.dmg` — macOS 安装包
- `npm run desktop:dist:mac` — 构建命令
