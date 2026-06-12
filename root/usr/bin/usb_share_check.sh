#!/bin/sh
# USB手机共享掉线自动检测重连脚本

. /lib/functions.sh

# PID校验锁，防止异常退出残留
LOCKFILE="/var/run/usb_share_check.lock"
if [ -f "$LOCKFILE" ]; then
    old_pid=$(cat "$LOCKFILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        logger -t usbphoneshare "已有检测进程(PID:$old_pid)运行中，跳过本次检测"
        exit 0
    else
        logger -t usbphoneshare "检测到无效锁文件，已清理"
        rm -f "$LOCKFILE"
    fi
fi
trap 'rm -f "$LOCKFILE"' EXIT
echo $$ > "$LOCKFILE"

# 读取配置
config_load usbphoneshare
config_get enable global auto_reconnect 0
config_get ifname global ifname usb0
config_get check_ip global check_ip "114.114.114.114"
config_get phone_type global phone_type android

# 基础合法性校验
[ "$enable" != "1" ] && exit 0
[ -z "$ifname" ] && exit 0
ip link show "$ifname" >/dev/null 2>&1 || {
    logger -t usbphoneshare "接口 $ifname 不存在，跳过检测"
    exit 0
}

# 连通性检测：ping 3次，每次1秒超时
ping -c 3 -W 1 -I "$ifname" "$check_ip" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    exit 0
fi

logger -t usbphoneshare "检测到接口 $ifname 网络异常，开始执行重连"

# iPhone模式优先重启通信服务
if [ "$phone_type" = "iphone" ]; then
    /etc/init.d/usbmuxd restart
    logger -t usbphoneshare "已重启usbmuxd服务"
    sleep 2
fi

# 重启网络接口
ifdown "$ifname"
sleep 3
ifup "$ifname"
sleep 5

# 二次校验连通性
ping -c 3 -W 1 -I "$ifname" "$check_ip" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    logger -t usbphoneshare "接口 $ifname 重连成功"
else
    logger -t usbphoneshare "接口 $ifname 重连失败，请检查设备连接与信号"
fi

exit 0
