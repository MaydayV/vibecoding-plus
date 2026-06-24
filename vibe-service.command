#!/bin/bash
set -uo pipefail

PROJECT_DIR="/Users/colin/Dev/vibecoding-plus"
SESSION_NAME="vibe"
LOG_FILE="/tmp/vibecoding-plus.log"
SERVER_PORT="8765"
REMINDCTL_BIN=""

ensure_remindctl() {
  if command -v remindctl >/dev/null 2>&1; then
    REMINDCTL_BIN="$(command -v remindctl)"
    return 0
  fi

  echo "未检测到 remindctl，正在尝试自动安装..."

  if ! command -v brew >/dev/null 2>&1; then
    echo "未检测到 Homebrew，无法自动安装 remindctl。"
    echo "请先安装 Homebrew，或手动安装 remindctl。"
    return 1
  fi

  if ! brew list --formula steipete/tap/remindctl >/dev/null 2>&1; then
    if ! brew install steipete/tap/remindctl; then
      echo "自动安装 remindctl 失败，请手动执行：brew install steipete/tap/remindctl"
      return 1
    fi
  fi

  if command -v remindctl >/dev/null 2>&1; then
    REMINDCTL_BIN="$(command -v remindctl)"
    return 0
  fi

  if [ -x "/opt/homebrew/bin/remindctl" ]; then
    export PATH="/opt/homebrew/bin:$PATH"
    REMINDCTL_BIN="/opt/homebrew/bin/remindctl"
    return 0
  fi

  if [ -x "/usr/local/bin/remindctl" ]; then
    export PATH="/usr/local/bin:$PATH"
    REMINDCTL_BIN="/usr/local/bin/remindctl"
    return 0
  fi

  echo "已尝试安装，但仍未找到 remindctl。"
  return 1
}

start_service() {
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "服务已在 tmux 会话 '$SESSION_NAME' 中运行。"
    return
  fi

  if ! ensure_remindctl; then
    echo "启动中止：remindctl 未就绪。"
    return 1
  fi

  local pids
  pids="$(lsof -t -iTCP:${SERVER_PORT} -sTCP:LISTEN 2>/dev/null || true)"
  if [ -n "$pids" ]; then
    echo "检测到 ${SERVER_PORT} 端口已有进程，占用 PID: $pids"
    echo "先停止占用进程..."
    kill $pids || true
    sleep 1
  fi

  if ! tmux new-session -d -s "$SESSION_NAME" "cd '$PROJECT_DIR' && VIBE_INVOKE_CWD='$PROJECT_DIR' REMINDCTL_PATH='$REMINDCTL_BIN' node client/server/src/server.mjs >> '$LOG_FILE' 2>&1"; then
    echo "服务启动失败，请查看日志：$LOG_FILE"
    return 1
  fi

  echo "服务已启动（tmux 会话已创建）。"
  echo "remindctl 路径: ${REMINDCTL_BIN:-未设置}"
}

stop_service() {
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    tmux kill-session -t "$SESSION_NAME"
    echo "已停止 tmux 会话 '$SESSION_NAME'。"
  else
    echo "tmux 会话 '$SESSION_NAME' 不存在。"
  fi

  local pids
  pids="$(lsof -t -iTCP:${SERVER_PORT} -sTCP:LISTEN 2>/dev/null || true)"
  if [ -n "$pids" ]; then
    echo "清理 ${SERVER_PORT} 端口残留进程: $pids"
    kill $pids || true
  fi
}

restart_service() {
  stop_service
  start_service
}

show_status() {
  echo "---- tmux 会话 ----"
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    tmux ls | grep "^${SESSION_NAME}:" || true
  else
    echo "未运行"
  fi

  echo
  echo "---- 端口监听 (${SERVER_PORT}) ----"
  lsof -nP -iTCP:${SERVER_PORT} -sTCP:LISTEN || echo "未监听"

  echo
  echo "---- 健康检查 ----"
  local code
  code="$(curl -sS -o /tmp/vibe_health_check.txt -w "%{http_code}" http://127.0.0.1:${SERVER_PORT}/healthz || true)"
  echo "GET /healthz -> ${code}"
}

show_logs() {
  if [ -f "$LOG_FILE" ]; then
    tail -n 60 "$LOG_FILE"
  else
    echo "日志文件不存在：$LOG_FILE"
  fi
}

attach_tmux() {
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "进入 tmux，会话退出快捷键：Ctrl+b 然后 d"
    tmux attach -t "$SESSION_NAME"
  else
    echo "会话 '$SESSION_NAME' 不存在，请先启动服务。"
  fi
}

while true; do
  clear
  echo "================ vibecoding-plus 服务管理 ================"
  echo "项目目录: $PROJECT_DIR"
  echo "tmux 会话: $SESSION_NAME"
  echo "日志文件: $LOG_FILE"
  echo
  echo "1) 启动服务"
  echo "2) 重启服务"
  echo "3) 停止服务"
  echo "4) 查看状态"
  echo "5) 查看日志(最近60行)"
  echo "6) 进入 tmux 会话"
  echo "0) 退出"
  echo "=========================================================="
  read -r -p "请选择操作 [0-6]: " choice

  echo
  case "$choice" in
    1) start_service || true ;;
    2) restart_service || true ;;
    3) stop_service || true ;;
    4) show_status || true ;;
    5) show_logs || true ;;
    6) attach_tmux || true ;;
    0) echo "已退出。"; exit 0 ;;
    *) echo "无效选项，请重试。" ;;
  esac

  echo
  read -r -p "按回车继续..." _
done
