local m, s, o
local sys = require "luci.sys"
local fs = require "nixio.fs"
local uci = require "luci.model.uci".cursor()

-- 按名称动态查找防火墙区域索引
local function get_firewall_zone_index(name)
    local i = 0
    while uci:get("firewall", "@zone[" .. i .. "]") do
        if uci:get("firewall", "@zone[" .. i .. "]", "name") == name then
            return i
        end
        i = i + 1
    end
    return nil
end

local wan_zone = get_firewall_zone_index("wan")

m = Map("usbphoneshare", translate("USB手机网络共享配置"),
    translate("一键配置安卓/iPhone USB热点，自动生成WAN接口，支持多网卡选择与掉线自动重连"))

-- 操作提示区块
s = m:section(TypedSection, "global", translate("操作提示"))
s.anonymous = true
s.template = "usbphoneshare/tips"

-- 基础设置区块
s = m:section(TypedSection, "global", translate("基础设置"))
s.anonymous = true

o = s:option(ListValue, "phone_type", translate("手机类型"))
o:value("android", translate("安卓手机(RNDIS/NCM)"))
o:value("iphone", translate("iPhone手机(USB热点)"))
o.default = "android"

-- 动态扫描所有USB网卡
local usb_ifaces = {}
local iface_list = sys.exec("ip -o link show | awk -F': ' '{print $2}' | grep '^usb' 2>/dev/null")
for iface in iface_list:gmatch("[^\r\n]+") do
    table.insert(usb_ifaces, iface)
end

o = s:option(ListValue, "ifname", translate("选择USB网卡"))
if #usb_ifaces == 0 then
    o:value("", translate("未检测到USB网卡，请连接设备后刷新页面"))
else
    for _, iface in ipairs(usb_ifaces) do
        o:value(iface, iface)
    end
end
o.default = "usb0"
o.rmempty = false

o = s:option(Flag, "enable_wan", translate("自动创建USB WAN接口"))
o.rmempty = false
o.default = 1

o = s:option(Flag, "enable_ipv6", translate("同步开启IPv6(WAN6+RA中继)"))
o.rmempty = false
o.default = 0

-- 掉线自动重连设置
s2 = m:section(TypedSection, "global", translate("掉线自动重连"))
s2.anonymous = true

o = s2:option(Flag, "auto_reconnect", translate("启用自动重连"))
o.rmempty = false
o.default = 0
o.description = translate("定时检测网络连通性，掉线自动重启接口恢复连接")

o = s2:option(Value, "check_interval", translate("检测间隔(分钟)"))
o.datatype = "range(1,60)"
o.default = "1"
o:depends("auto_reconnect", "1")

o = s2:option(Value, "check_ip", translate("检测目标IP"))
o.datatype = "ipaddr"
o.default = "114.114.114.114"
o:depends("auto_reconnect", "1")

-- 操作按钮区
s3 = m:section(TypedSection, "global", translate("操作"))
s3.anonymous = true

o = s3:option(Button, "apply_btn", translate("一键应用配置"))
o.inputstyle = "apply"
o.write = function(self, section)
    local phone_type = uci:get("usbphoneshare", section, "phone_type") or "android"
    local ifname = uci:get("usbphoneshare", section, "ifname") or "usb0"
    local do_wan = uci:get_bool("usbphoneshare", section, "enable_wan")
    local do_ipv6 = uci:get_bool("usbphoneshare", section, "enable_ipv6")
    local auto_reconnect = uci:get_bool("usbphoneshare", section, "auto_reconnect")
    local check_interval = uci:get("usbphoneshare", section, "check_interval") or "1"

    -- 接口名白名单校验，防范命令注入
    if not ifname:match("^[%w%-]+$") then
        luci.http.redirect(luci.dispatcher.build_url("admin/network/usbphoneshare"))
        return
    end

    -- 备份usbmuxd原有状态
    local usbmuxd_backup = uci:get("usbphoneshare", section, "usbmuxd_original")
    if not usbmuxd_backup then
        local original_enabled = os.execute("/etc/init.d/usbmuxd enabled >/dev/null 2>&1") == 0
        uci:set("usbphoneshare", section, "usbmuxd_original", original_enabled and "1" or "0")
    end

    if phone_type == "iphone" then
        os.execute("/etc/init.d/usbmuxd enable")
        os.execute("/etc/init.d/usbmuxd start")
        -- 后台异步执行，加PID防重复启动
        if not fs.access("/var/run/usb_iphone_restart.pid") then
            os.execute(string.format(
                "(echo $$ > /var/run/usb_iphone_restart.pid; sleep 5 && ifdown %s 2>/dev/null && sleep 2 && ifup %s 2>/dev/null; rm -f /var/run/usb_iphone_restart.pid) &",
                ifname, ifname
            ))
        end
    else
        -- 仅还原用户原有状态，不强制禁用
        if uci:get("usbphoneshare", section, "usbmuxd_original") == "0" then
            os.execute("/etc/init.d/usbmuxd stop")
            os.execute("/etc/init.d/usbmuxd disable")
        end
        uci:delete("usbphoneshare", section, "usbmuxd_original")
    end

    -- 配置USB WAN接口 + 防火墙
    if do_wan and ifname ~= "" then
        uci:set("network", "usbwan", "interface")
        uci:set("network", "usbwan", "device", ifname)
        uci:set("network", "usbwan", "proto", "dhcp")
        uci:set("network", "usbwan", "metric", "100")
        
        if wan_zone ~= nil then
            while uci:delete_list("firewall", "@zone[" .. wan_zone .. "]", "network", "usbwan") do end
            uci:add_list("firewall", "@zone[" .. wan_zone .. "]", "network", "usbwan")
        end
    else
        if wan_zone ~= nil then
            while uci:delete_list("firewall", "@zone[" .. wan_zone .. "]", "network", "usbwan") do end
        end
        uci:delete("network", "usbwan")
    end

    -- 配置IPv6
    if do_ipv6 and do_wan and ifname ~= "" then
        -- 首次启用时备份用户原始LAN IPv6配置
        if not uci:get("usbphoneshare", section, "backup_ra") then
            uci:set("usbphoneshare", section, "backup_ra", uci:get("dhcp", "lan", "ra_management") or "server")
            uci:set("usbphoneshare", section, "backup_dhcpv6", uci:get("dhcp", "lan", "dhcpv6") or "server")
            uci:set("usbphoneshare", section, "backup_ndp", uci:get("dhcp", "lan", "ndp") or "0")
        end

        uci:set("network", "usbwan6", "interface")
        uci:set("network", "usbwan6", "device", "@usbwan")
        uci:set("network", "usbwan6", "proto", "dhcpv6")
        uci:set("network", "usbwan6", "reqprefix", "1")
        
        if wan_zone ~= nil then
            while uci:delete_list("firewall", "@zone[" .. wan_zone .. "]", "network", "usbwan6") do end
            uci:add_list("firewall", "@zone[" .. wan_zone .. "]", "network", "usbwan6")
        end
        
        uci:set("dhcp", "lan", "ra_management", "relay")
        uci:set("dhcp", "lan", "dhcpv6", "relay")
        uci:set("dhcp", "lan", "ndp", "1")
    else
        if wan_zone ~= nil then
            while uci:delete_list("firewall", "@zone[" .. wan_zone .. "]", "network", "usbwan6") do end
        end
        uci:delete("network", "usbwan6")
        
        -- 仅当中继模式未被修改时才还原
        local backup_ra = uci:get("usbphoneshare", section, "backup_ra")
        if backup_ra then
            local current_ra = uci:get("dhcp", "lan", "ra_management")
            if current_ra == "relay" then
                uci:set("dhcp", "lan", "ra_management", backup_ra)
                uci:set("dhcp", "lan", "dhcpv6", uci:get("usbphoneshare", section, "backup_dhcpv6"))
                uci:set("dhcp", "lan", "ndp", uci:get("usbphoneshare", section, "backup_ndp"))
            end
            uci:delete("usbphoneshare", section, "backup_ra")
            uci:delete("usbphoneshare", section, "backup_dhcpv6")
            uci:delete("usbphoneshare", section, "backup_ndp")
        end
    end

    -- 配置自动重连定时任务
    fs.remove("/etc/cron.d/usbphoneshare")
    if auto_reconnect and do_wan and ifname ~= "" then
        local cron_str = string.format("*/%d * * * * root /usr/bin/usb_share_check.sh\n", tonumber(check_interval) or 1)
        fs.writefile("/etc/cron.d/usbphoneshare", cron_str)
        fs.chmod("/etc/cron.d/usbphoneshare", 644)
        os.execute("/etc/init.d/cron enable && /etc/init.d/cron restart")
    else
        os.execute("/etc/init.d/cron restart")
    end

    -- 提交配置并重载
    uci:commit("network")
    uci:commit("dhcp")
    uci:commit("firewall")
    uci:commit("usbphoneshare")
    
    os.execute("reload_config")
    luci.http.redirect(luci.dispatcher.build_url("admin/network/usbphoneshare"))
end

-- 一键重启接口按钮
o = s3:option(Button, "restart_btn", translate("重启USB接口"))
o.inputstyle = "reload"
o.write = function(self, section)
    local ifname = uci:get("usbphoneshare", section, "ifname") or "usb0"
    if ifname:match("^[%w%-]+$") and sys.exec("ip link show " .. ifname .. " 2>/dev/null | grep -q 'state UP' && echo 1 || echo 0"):gsub("%s+", "") == "1" then
        os.execute("ifdown " .. ifname .. " 2>/dev/null && sleep 2 && ifup " .. ifname .. " 2>/dev/null")
    end
    luci.http.redirect(luci.dispatcher.build_url("admin/network/usbphoneshare"))
end

o = s3:option(Button, "del_btn", translate("删除全部USB共享配置"))
o.inputstyle = "remove"
o.write = function(self, section)
    -- 清理接口与防火墙
    uci:delete("network", "usbwan")
    uci:delete("network", "usbwan6")
    if wan_zone ~= nil then
        while uci:delete_list("firewall", "@zone[" .. wan_zone .. "]", "network", "usbwan") do end
        while uci:delete_list("firewall", "@zone[" .. wan_zone .. "]", "network", "usbwan6") do end
    end
    
    -- 还原LAN IPv6原始配置
    local backup_ra = uci:get("usbphoneshare", section, "backup_ra")
    if backup_ra then
        local current_ra = uci:get("dhcp", "lan", "ra_management")
        if current_ra == "relay" then
            uci:set("dhcp", "lan", "ra_management", backup_ra)
            uci:set("dhcp", "lan", "dhcpv6", uci:get("usbphoneshare", section, "backup_dhcpv6"))
            uci:set("dhcp", "lan", "ndp", uci:get("usbphoneshare", section, "backup_ndp"))
        end
        uci:delete("usbphoneshare", section, "backup_ra")
        uci:delete("usbphoneshare", section, "backup_dhcpv6")
        uci:delete("usbphoneshare", section, "backup_ndp")
    end
    
    -- 还原usbmuxd原始状态
    local usbmuxd_original = uci:get("usbphoneshare", section, "usbmuxd_original")
    if usbmuxd_original == "0" then
        os.execute("/etc/init.d/usbmuxd stop")
        os.execute("/etc/init.d/usbmuxd disable")
    end
    uci:delete("usbphoneshare", section, "usbmuxd_original")
    
    -- 清理定时任务
    fs.remove("/etc/cron.d/usbphoneshare")
    os.execute("/etc/init.d/cron restart")
    
    uci:commit("network")
    uci:commit("dhcp")
    uci:commit("firewall")
    uci:commit("usbphoneshare")
    
    os.execute("reload_config")
    luci.http.redirect(luci.dispatcher.build_url("admin/network/usbphoneshare"))
end

-- 运行状态面板
s4 = m:section(SimpleSection, translate("运行状态"))
s4.template = "usbphoneshare/status"

return m
