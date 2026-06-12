local http = require "luci.http"
local sys = require "luci.sys"
local fs = require "nixio.fs"

module("luci.controller.usbphoneshare", package.seeall)

function index()
    local cfg = "/etc/config/usbphoneshare"
    if not fs.access(cfg) then
        fs.writefile(cfg, [[
config global
    option phone_type 'android'
    option ifname 'usb0'
    option enable_wan '1'
    option enable_ipv6 '0'
    option auto_reconnect '0'
    option check_interval '1'
    option check_ip '114.114.114.114'
]])
    end

    entry({"admin", "network", "usbphoneshare"}, cbi("usbphoneshare/main"), _("USB手机共享上网"), 80).dependent=false
    entry({"admin", "network", "usbphoneshare", "status"}, call("act_status")).leaf = true
end

-- 字节数格式化工具函数
local function format_bytes(bytes)
    if not bytes or bytes == "" or tonumber(bytes) == nil then
        return "0 B"
    end
    bytes = tonumber(bytes)
    local units = {"B", "KB", "MB", "GB", "TB"}
    local i = 1
    while bytes >= 1024 and i < #units do
        bytes = bytes / 1024
        i = i + 1
    end
    return string.format("%.2f %s", bytes, units[i])
end

function act_status()
    local e = {}
    local ifname = sys.exec("uci -q get usbphoneshare.@global[0].ifname"):gsub("^%s+", ""):gsub("%s+$", "")
    if not ifname or ifname == "" then ifname = "usb0" end
    
    e.ifname = ifname
    e.iface_up = sys.exec("ip link show " .. ifname .. " 2>/dev/null | grep -q 'state UP' && echo 1 || echo 0"):gsub("%s+", "")
    e.usbmuxd_running = sys.exec("/etc/init.d/usbmuxd running >/dev/null 2>&1 && echo 1 || echo 0"):gsub("%s+", "")
    e.wan_usb_exist = sys.exec("uci -q get network.usbwan >/dev/null && echo 1 || echo 0"):gsub("%s+", "")
    e.ipv6_wan6 = sys.exec("uci -q get network.usbwan6 >/dev/null && echo 1 || echo 0"):gsub("%s+", "")
    e.reconnect_enable = sys.exec("uci -q get usbphoneshare.@global[0].auto_reconnect"):gsub("%s+", "")
    e.phone_type = sys.exec("uci -q get usbphoneshare.@global[0].phone_type"):gsub("%s+", "")
    e.cron_running = sys.exec("/etc/init.d/cron running >/dev/null 2>&1 && echo 1 || echo 0"):gsub("%s+", "")
    
    -- IP地址
    e.ipv4_addr = sys.exec("ip -4 addr show " .. ifname .. " 2>/dev/null | grep -oP 'inet \\K[\\d.]+' | head -1"):gsub("%s+", "")
    e.ipv6_addr = sys.exec("ip -6 addr show " .. ifname .. " 2>/dev/null | grep -oP 'inet6 \\K[\\w:]+' | head -1"):gsub("%s+", "")
    
    -- 流量统计
    local rx = sys.exec("cat /sys/class/net/" .. ifname .. "/statistics/rx_bytes 2>/dev/null"):gsub("%s+", "")
    local tx = sys.exec("cat /sys/class/net/" .. ifname .. "/statistics/tx_bytes 2>/dev/null"):gsub("%s+", "")
    e.rx_total = format_bytes(rx)
    e.tx_total = format_bytes(tx)
    
    -- USB设备厂商型号
    local manuf = sys.exec("cat /sys/class/net/" .. ifname .. "/device/manufacturer 2>/dev/null"):gsub("%s+$", "")
    local product = sys.exec("cat /sys/class/net/" .. ifname .. "/device/product 2>/dev/null"):gsub("%s+$", "")
    if manuf ~= "" or product ~= "" then
        e.usb_device = manuf .. " " .. product
    else
        e.usb_device = ""
    end
    
    http.write_json(e)
end
