#
# Copyright 2026 Custom Build
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-usb-phone-share
PKG_VERSION:=1.6
PKG_RELEASE:=20260613

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Custom Build
PKG_DESCRIPTION:=一键配置安卓/iPhone USB热点，支持多网卡选择、IPv6中继、掉线自动重连

LUCI_TITLE:=USB手机网络共享工具
LUCI_PKGARCH:=all

# 基础必选依赖
LUCI_DEPENDS:= \
	+kmod-usb-core +kmod-usb2 +kmod-usb-net \
	+kmod-usb-net-rndis +kmod-usb-net-cdc-ether +kmod-usb-net-cdc-ncm \
	+kmod-usb-net-huawei-cdc-ncm \
	+kmod-usb-net-ipheth +usbmuxd +libimobiledevice +libplist \
	+odhcp6c +odhcpd-ipv6only +usbutils

# 条件依赖：24.10及以上版本补充IPv6协议支持
ifeq ($(CONFIG_VERSION_NUMBER),24.10)
LUCI_DEPENDS+=+luci-proto-ipv6
endif

# 条件依赖：平台支持USB3时自动添加驱动
ifdef CONFIG_USB3_SUPPORT
LUCI_DEPENDS+=+kmod-usb3
endif

define Package/luci-app-usb-phone-share
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=USB手机网络共享工具
  PKGARCH:=all
endef

define Package/luci-app-usb-phone-share/description
  $(PKG_DESCRIPTION)
  完全兼容 OpenWrt 21.02 ~ 24.10 全系列版本
endef

define Build/Compile
endef

define Package/luci-app-usb-phone-share/conffiles
/etc/config/usbphoneshare
endef

define Package/luci-app-usb-phone-share/install
	# 创建目录
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci

	# 可执行文件：自动设置755权限
	$(INSTALL_BIN) ./root/usr/bin/usb_share_check.sh $(1)/usr/bin/
	$(INSTALL_BIN) ./root/etc/init.d/usbphoneshare $(1)/etc/init.d/

	# 配置与页面文件：自动保持644权限
	$(CP) ./root/etc/config/* $(1)/etc/config/
	$(CP) ./root/usr/lib/lua/luci/* $(1)/usr/lib/lua/luci/
endef

define Package/luci-app-usb-phone-share/preinst
#!/bin/sh
# 升级前停止旧版本服务，避免冲突
if [ -n "$${IPKG_INSTROOT}" ]; then
	exit 0
fi
if /etc/init.d/usbphoneshare enabled >/dev/null 2>&1; then
	/etc/init.d/usbphoneshare stop >/dev/null 2>&1
fi
exit 0
endef

define Package/luci-app-usb-phone-share/postinst
#!/bin/sh
# 启用开机自启
enable_service usbphoneshare >/dev/null 2>&1
enable_service cron >/dev/null 2>&1
# 非固件升级场景下直接启动服务
if [ -z "$${IPKG_INSTROOT}" ]; then
	/etc/init.d/usbphoneshare start >/dev/null 2>&1
fi
exit 0
endef

define Package/luci-app-usb-phone-share/postrm
#!/bin/sh
# 停止并禁用服务
disable_service usbphoneshare >/dev/null 2>&1
/etc/init.d/usbphoneshare stop >/dev/null 2>&1
# 清理所有运行时残留文件
rm -f /etc/cron.d/usbphoneshare >/dev/null 2>&1
rm -f /var/run/usb_share_check.lock >/dev/null 2>&1
rm -f /var/run/usb_iphone_restart.pid >/dev/null 2>&1
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
