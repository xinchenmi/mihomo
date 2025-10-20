#!/usr/bin/env bash
# setup_singbox_process_watchdog.sh
# 功能：
#  1) 每天 01:00 / 13:00 定时重启 sing-box
#  2) 进程级看门狗：定期检查 Linux 进程表里是否有 sing-box；没有就 systemctl start

set -euo pipefail

SERVICE_NAME="sing-box"   # 你的 systemd 服务名
PROCESS_NAME="sing-box"   # 进程名，用于 pgrep -x 精确匹配
CHECK_INTERVAL="2min"     # 看门狗运行间隔（修改这里可变更频率）

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "请用 root 权限运行（sudo $0）" >&2
    exit 1
  fi
}

assert_systemd() {
  if ! pidof systemd >/dev/null 2>&1; then
    echo "未检测到 systemd，此脚本依赖 systemd timer。" >&2
    exit 1
  fi
}

install_watchdog_script() {
  cat >/usr/local/bin/sb-proc-watchdog.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-sing-box}"
PROCESS_NAME="${PROCESS_NAME:-sing-box}"

TS="$(date '+%F %T')"
logi(){ echo "[$TS] $*" | systemd-cat -t sb-proc-watchdog -p info; }
loge(){ echo "[$TS] $*" | systemd-cat -t sb-proc-watchdog -p err; }

# 方式一：纯进程表检测（pgrep -x 精确匹配可执行名）
if ! pgrep -x "${PROCESS_NAME}" >/dev/null 2>&1; then
  loge "process ${PROCESS_NAME} NOT running -> starting ${SERVICE_NAME}"
  systemctl start "${SERVICE_NAME}" || true
  sleep 2
  if pgrep -x "${PROCESS_NAME}" >/dev/null 2>&1; then
    logi "process ${PROCESS_NAME} started OK"
    exit 0
  else
    loge "FAILED to start ${SERVICE_NAME}; process still missing"
    exit 1
  fi
else
  logi "process ${PROCESS_NAME} is running"
fi

exit 0
EOF
  chmod +x /usr/local/bin/sb-proc-watchdog.sh
}

install_restart_script() {
  cat >/usr/local/bin/sb-restart.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SERVICE_NAME="${SERVICE_NAME:-sing-box}"
TS="$(date '+%F %T')"
echo "[$TS] Restarting ${SERVICE_NAME}..." | systemd-cat -t sb-restart -p info
systemctl restart "${SERVICE_NAME}"
if systemctl is-active --quiet "${SERVICE_NAME}"; then
  echo "[$TS] ${SERVICE_NAME} restarted OK" | systemd-cat -t sb-restart -p info
else
  echo "[$TS] ${SERVICE_NAME} restart FAILED" | systemd-cat -t sb-restart -p err
fi
EOF
  chmod +x /usr/local/bin/sb-restart.sh
}

install_units() {
  # 每日定时重启：01:00 和 13:00
  cat >/etc/systemd/system/sb-restart.service <<'EOF'
[Unit]
Description=Restart sing-box service (oneshot)

[Service]
Type=oneshot
Environment=SERVICE_NAME=sing-box
ExecStart=/usr/local/bin/sb-restart.sh
EOF

  cat >/etc/systemd/system/sb-restart.timer <<'EOF'
[Unit]
Description=Restart sing-box at 01:00 and 13:00 daily

[Timer]
OnCalendar=*-*-* 01:00:00
OnCalendar=*-*-* 13:00:00
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

  # 进程级看门狗：定期检查进程是否存在
  cat >/etc/systemd/system/sb-proc-watchdog.service <<'EOF'
[Unit]
Description=Sing-box process watchdog (start service if process is missing)

[Service]
Type=oneshot
Environment=SERVICE_NAME=sing-box
Environment=PROCESS_NAME=sing-box
ExecStart=/usr/local/bin/sb-proc-watchdog.sh
EOF

  cat >/etc/systemd/system/sb-proc-watchdog.timer <<EOF
[Unit]
Description=Run sing-box process watchdog every ${CHECK_INTERVAL}

[Timer]
OnBootSec=1min
OnUnitActiveSec=${CHECK_INTERVAL}
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
}

enable_and_start() {
  systemctl daemon-reload
  systemctl enable --now sb-restart.timer
  systemctl enable --now sb-proc-watchdog.timer
  echo "已启用以下 timers："
  systemctl list-timers --all | grep -E 'sb-(restart|proc-watchdog)\\.timer' || true
  echo
  echo "查看日志：journalctl -u sb-restart.service -u sb-proc-watchdog.service -f"
}

tips() {
  cat <<'EOF'

[说明/可选优化]
1) 如你的 sing-box 是以 systemd 管理，强烈建议把它的服务文件加上自恢复：
   在 sing-box 的 service 单元 [Service] 段添加：
     Restart=always
     RestartSec=3
   然后：systemctl daemon-reload && systemctl restart sing-box
   这样可即时崩溃自拉起；本脚本的“进程看门狗”是一个额外兜底。

2) 修改看门狗频率：
   编辑 /etc/systemd/system/sb-proc-watchdog.timer 的 OnUnitActiveSec（默认 2 分钟），然后：
     systemctl daemon-reload
     systemctl restart sb-proc-watchdog.timer

3) 立刻测试：
   - 手工杀进程：pkill -x sing-box
   - 然后等待 1~2 分钟，看门狗应自动 systemctl start sing-box
   - 查看日志：journalctl -u sb-proc-watchdog.service --since "5 min ago"

4) 卸载：
   systemctl disable --now sb-restart.timer sb-proc-watchdog.timer
   rm -f /etc/systemd/system/sb-restart.{service,timer} \
         /etc/systemd/system/sb-proc-watchdog.{service,timer} \
         /usr/local/bin/sb-restart.sh /usr/local/bin/sb-proc-watchdog.sh
   systemctl daemon-reload

EOF
}

main() {
  require_root
  assert_systemd
  install_watchdog_script
  install_restart_script
  install_units
  enable_and_start
  tips
}

main "$@"
