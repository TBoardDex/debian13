#!/bin/bash -e

# Directory contains the target rootfs
TARGET_ROOTFS_DIR="binary"
sudo rm -rf "$TARGET_ROOTFS_DIR"

case "${ARCH:-$1}" in
	arm|arm32|armhf)
		ARCH=armhf
		;;
	*)
		ARCH=arm64
		;;
esac

echo -e "\033[36m Building for $ARCH \033[0m"

if [ ! $VERSION ]; then
	VERSION="release"
fi

echo -e "\033[36m Building for $VERSION \033[0m"

if [ ! -e rockchip-debian-trixie-*.tar.gz ]; then
	echo "\033[36m Run mk-base-debian.sh first \033[0m"
	exit -1
fi

echo -e "\033[36m Extract image \033[0m"
sudo tar -xpf rockchip-debian-trixie-*.tar.gz

# Rejoin files that were split to stay under the GitHub 100MB object limit:
# packages/**/<name>.part-XX are concatenated back into <name> so the
# offline package install below works right after a repo sync.
rejoin_split() {
	local first dir name
	find packages -name '*.part-*' -type f | while read -r first; do
		dir=$(dirname "$first")
		name=$(basename "$first")
		name="${name%.part-*}"
		[ -f "$dir/$name" ] && continue
		echo -e "\033[36m  Rejoining $dir/$name from split parts ...\033[0m"
		cat "$dir/$name".part-* > "$dir/$name"
	done
}
rejoin_split

# packages folder
sudo mkdir -p $TARGET_ROOTFS_DIR/packages
sudo cp -rpf packages/$ARCH/* $TARGET_ROOTFS_DIR/packages

# overlay folder
sudo cp -rpf overlay/* $TARGET_ROOTFS_DIR/

# overlay-firmware folder
for firmware_dir in overlay-firmware/*; do
	sudo cp -rpf "$firmware_dir/." "$TARGET_ROOTFS_DIR/${firmware_dir##*/}/"
done

# overlay-debug folder
# adb, video, camera  test file
if [ "$VERSION" == "debug" ]; then
	sudo cp -rpf overlay-debug/* $TARGET_ROOTFS_DIR/
fi

echo -e "\033[36m Change root.....................\033[0m"

ID=$(stat --format %u $TARGET_ROOTFS_DIR)

# Mount pseudo-filesystems required by dpkg postinst scripts (e.g. py3compile needs /dev/pts)
cleanup_mounts() {
    sudo umount $TARGET_ROOTFS_DIR/dev/pts 2>/dev/null || true
    sudo umount $TARGET_ROOTFS_DIR/dev     2>/dev/null || true
    sudo umount $TARGET_ROOTFS_DIR/sys     2>/dev/null || true
    sudo umount $TARGET_ROOTFS_DIR/proc    2>/dev/null || true
}
trap cleanup_mounts EXIT

sudo mount --bind /proc   $TARGET_ROOTFS_DIR/proc
sudo mount --bind /sys    $TARGET_ROOTFS_DIR/sys
sudo mount --bind /dev    $TARGET_ROOTFS_DIR/dev
sudo mount -t devpts devpts $TARGET_ROOTFS_DIR/dev/pts -o gid=5,mode=620

# Pass host ID into chroot via temp file (quoted heredoc prevents host expansion)
# Write host terminal size into chroot so prompt/output line up correctly
sudo sh -c "echo $ID $(tput cols 2>/dev/null || echo 80) $(tput lines 2>/dev/null || echo 24) > $TARGET_ROOTFS_DIR/tmp/.build_id"

cat << 'CHEOF' | sudo chroot "$TARGET_ROOTFS_DIR" /bin/bash --norc --noprofile

set -e

# ============================================================
#  Read host-side ID passed via temp file
# ============================================================
read -r ID TERM_COLS TERM_ROWS < /tmp/.build_id
rm -f /tmp/.build_id
# Apply host terminal size so output lines up correctly
stty cols "${TERM_COLS:-80}" rows "${TERM_ROWS:-24}" 2>/dev/null || true

# ============================================================
#  Helper functions: structured output + error handling
# ============================================================

STEP=0
TOTAL_STEPS=21

# Print a numbered step banner
step() {
    STEP=$((STEP + 1))
    echo ""
    echo -e "\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "\033[1;34m  [${STEP}/${TOTAL_STEPS}] $1\033[0m"
    echo -e "\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
}

# Install packages: log full dpkg output to file, print summary to terminal.
# On failure, print the error lines and abort.
#   Usage: pkg_install "description" pkg1 pkg2 ...
#          pkg_install "description" /path/to/*.deb
pkg_install() {
    local desc="$1"; shift
    local logfile="/tmp/apt-install-${STEP}.log"

    echo -e "\033[36m  -> ${desc} ...\033[0m"

    if apt-get install -fy --allow-downgrades "$@" > "$logfile" 2>&1; then
        local count
        count=$(grep -c "^Setting up " "$logfile" 2>/dev/null || echo 0)
        echo -e "\033[32m    [OK] Done (${count} packages installed/upgraded)\033[0m"
    else
        echo -e "\033[1;31m    [FAIL] Error details:\033[0m"
        grep -E "^E:|error|failed|unable|not found" "$logfile" 2>/dev/null | tail -10 | \
            sed 's/^/    /'
        echo -e "\033[1;31m    Full log: ${logfile}\033[0m"
        return 1
    fi
}

# Purge packages: tolerate missing packages gracefully.
#   Usage: pkg_purge "description" pkg1 pkg2 ...
pkg_purge() {
    local desc="$1"; shift
    local logfile="/tmp/apt-purge-${STEP}.log"

    echo -e "\033[36m  -> ${desc} ...\033[0m"

    if apt-get purge -y --allow-change-held-packages "$@" > "$logfile" 2>&1; then
        local count
        count=$(grep -c "^Removing " "$logfile" 2>/dev/null || echo 0)
        echo -e "\033[32m    [OK] Done (${count} packages removed)\033[0m"
    else
        echo -e "\033[33m    [SKIP] Some packages not found or already removed\033[0m"
    fi
}

# ============================================================
#  Error trap: print location on any unhandled failure
# ============================================================
on_error() {
    local lineno=$1
    echo ""
    echo -e "\033[1;31m========================================\033[0m"
    echo -e "\033[1;31m  [FAIL] Build failed in chroot (line: ${lineno})\033[0m"
    echo -e "\033[1;31m========================================\033[0m"
    exit 1
}
trap 'on_error $LINENO' ERR

# ============================================================
#  Step 1: Fix ownership + DNS
# ============================================================
step "Fix ownership & configure DNS"

if [ "$ID" -ne 0 ]; then
       echo -e "[36m  -> Fixing file ownership (uid $ID -> 0) ...[0m"
       find / -user $ID -exec chown -h 0:0 {} \; 2>/dev/null || true
       echo -e "[32m    [OK] Ownership fixed[0m"
else
       echo -e "[32m  -> Ownership already root, skipping[0m"
fi

if ls /home/ >/dev/null 2>&1; then
       echo -e "[36m  -> Fixing /home/* ownership ...[0m"
       for u in $(ls /home/); do
               chown -h -R $u:$u /home/$u 2>/dev/null || true
       done
fi

echo -e "[36m  -> Adding DNS nameservers ...[0m"
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
echo "nameserver 127.0.0.53" >> /etc/resolv.conf
echo "nameserver 114.114.114.114" >> /etc/resolv.conf
echo -e "[32m    [OK] DNS configured[0m"

# ============================================================
#  Step 2: Configure APT sources & update
# ============================================================
step "Configure APT sources & update index"

echo "deb http://mirrors.tuna.tsinghua.edu.cn/debian/ trixie-backports main contrib" >> /etc/apt/sources.list
echo "deb-src http://mirrors.tuna.tsinghua.edu.cn/debian/ trixie-backports main contrib" >> /etc/apt/sources.list

apt-get update 2>&1
apt-get upgrade -y 2>&1

# ============================================================
#  Step 3: Passwordless serial console login
# ============================================================
step "Configure passwordless serial login"
echo -e "\033[36m  -> Patching serial-getty@.service ...\033[0m"

sed -i "s~\(^ExecStart=.*\)~# \1\nExecStart=-/bin/sh -c '/bin/bash -l </dev/%I >/dev/%I 2>\&1'~" /usr/lib/systemd/system/serial-getty@.service
echo -e "\033[32m    [OK] Serial console will auto-login as root\033[0m"

# ============================================================
#  Step 4: Power management
# ============================================================
step "Install power management tools"

pkg_install "Power management" pm-utils triggerhappy bsdmainutils
sed -i "s/#HandlePowerKey=.*/HandlePowerKey=ignore/" /etc/systemd/logind.conf

# ============================================================
#  Step 5: System services
# ============================================================
step "Configure system services"

echo -e "[36m  -> Masking slow boot services ...[0m"
systemctl mask systemd-networkd-wait-online.service
systemctl mask NetworkManager-wait-online.service
rm -f /lib/systemd/system/wpa_supplicant@.service
echo -e "[32m    [OK] Boot-wait services masked[0m"

# ============================================================
#  Step 6: Check for desktop environment
# ============================================================
step "Check desktop environment"

if ! [ -e /usr/bin/X ]; then
	echo -e "\033[33m  [WARN] No desktop (/usr/bin/X not found), skipping desktop packages\033[0m"
	echo -e "\033[32m  [OK] Base system build done, skipping remaining steps\033[0m"
	exit 0
fi

echo -e "\033[32m  [OK] Desktop detected, continuing with multimedia & graphics\033[0m"

# ============================================================
#  Step 7: RGA / Video codec / GStreamer
# ============================================================
step "Install video codec (RGA / MPP / GStreamer)"

pkg_install "RGA" /packages/rga2/*.deb
pkg_install "GStreamer core" gstreamer1.0-plugins-bad gstreamer1.0-plugins-base gstreamer1.0-plugins-ugly gstreamer1.0-tools gstreamer1.0-alsa gstreamer1.0-plugins-base-apps
pkg_install "MPP hardware codec" /packages/mpp/*
pkg_install "GStreamer RKMPP plugin" /packages/gst-rkmpp/*.deb
pkg_install "GStreamer extra" /packages/gstreamer/*.deb
pkg_install "GStreamer Base plugin" /packages/gst-plugins-base1.0/*.deb
pkg_install "GStreamer Bad plugin" /packages/gst-plugins-bad1.0/*.deb
pkg_install "GStreamer Good plugin" /packages/gst-plugins-good1.0/*.deb

# ============================================================
#  Step 8: Camera
# ============================================================
step "Install camera support"

pkg_install "Camera tools" cheese v4l-utils
pkg_install "libv4l" /packages/libv4l/*.deb
pkg_install "Cheese camera" /packages/cheese/*.deb

# Purge the stale libcamera0.4 pulled in by task-gnome-desktop in the base tarball.
apt-get purge -y libcamera0.4 2>/dev/null || true

# ============================================================
#  Step 9: Xserver / Chromium / DRM
# ============================================================
step "Install Xserver / Chromium / libdrm"

apt-mark hold xserver-common xserver-xorg-core xserver-xorg-legacy 2>/dev/null || true

pkg_install "Chromium browser" /packages/chromium/*.deb
pkg_install "libdrm" /packages/libdrm/*.deb
pkg_install "libdrm-cursor" /packages/libdrm-cursor/*.deb
# ============================================================
#  Step 10: Network / WiFi / BT
# ============================================================
step "Install network & WiFi/BT"

if ls /packages/rkwifibt/*.deb >/dev/null 2>&1; then
	pkg_install "WiFi/BT" /packages/rkwifibt/*.deb
else
	echo -e "\033[33m  [WARN] /packages/rkwifibt/ not found, skipping\033[0m"
fi

# ============================================================
#  Step 11: glmark2 (debug only)
# ============================================================
if ls /packages/glmark2/*.deb >/dev/null 2>&1; then
	step "Install glmark2 benchmark"
	pkg_install "glmark2" /packages/glmark2/*.deb
fi

# ============================================================
#  Step 12: rknpu2 tar
# ============================================================
if [ -e "/usr/lib/aarch64-linux-gnu" ]; then
	step "Install rknpu2"
	if ls /packages/rknpu2/rknpu2.tar >/dev/null 2>&1; then
		mv /packages/rknpu2/rknpu2.tar /
		echo -e "\033[32m    [OK] rknpu2.tar moved to /\033[0m"
	else
		echo -e "\033[33m  [WARN] /packages/rknpu2/rknpu2.tar not found, skipping\033[0m"
	fi
fi

# ============================================================
#  Step 13: Chinese fonts & ibus input method
# ============================================================
step "Install Chinese fonts & input method"

echo -e "\033[36m  -> Configuring zh_CN locale ...\033[0m"
sed -i 's/^# *\(zh_CN.UTF-8\)/\1/' /etc/locale.gen
locale-gen
update-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh

pkg_install "Chinese fonts" ttf-wqy-zenhei fonts-aenigma xfonts-intl-chinese
pkg_install "ibus input method" ibus ibus-libpinyin

# ============================================================
#  Step 14: Pipewire audio
# ============================================================
step "Install pipewire audio"
pkg_install "Pipewire" pipewire pipewire-pulse pipewire-alsa libspa-0.2-bluetooth

# ============================================================
#  Step 15: Weston / Wayland
# ============================================================
step "Install weston & wayland"
pkg_install "Weston compositor" libseat-dev weston

if ls /packages/weston/*.deb >/dev/null 2>&1; then
	pkg_install "Weston (custom)" /packages/weston/*.deb
else
	echo -e "\033[33m  [WARN] /packages/weston/ not found, skipping\033[0m"
fi

if ls /packages/wayland/*.deb >/dev/null 2>&1; then
	pkg_install "Wayland" /packages/wayland/*.deb
else
	echo -e "\033[33m  [WARN] /packages/wayland/ not found, skipping\033[0m"
fi

# ============================================================
#  Step 16: Mutter (GL_OES_EGL_image_external NV12 compositing)
# ============================================================
step "Install mutter compositor"
if ls /packages/mutter/*.deb >/dev/null 2>&1; then
	pkg_install "Mutter" /packages/mutter/*.deb gnome-session
else
	echo -e "\033[33m  [WARN] /packages/mutter/ not found, skipping\033[0m"
fi

# ============================================================
#  Step 17: Totem media player
# ============================================================
step "Install totem media player"
pkg_install "python3-xdg" python3-xdg
if ls /packages/totem/*.deb >/dev/null 2>&1; then
	pkg_install "Totem" /packages/totem/*.deb
else
	echo -e "\033[33m  [WARN] /packages/totem/ not found, skipping\033[0m"
fi

# ============================================================
#  Step 18: Hardinfo system profiler
# ============================================================
#step "Install hardinfo & dmidecode"
#pkg_install "dmidecode" dmidecode
#if ls /packages/hardinfo/*.deb >/dev/null 2>&1; then
#	pkg_install "Hardinfo" /packages/hardinfo/*.deb
#else
#	echo -e "\033[33m  [WARN] /packages/hardinfo/ not found, skipping\033[0m"
#fi

# ============================================================
#  Step 19: Copy vendor debs & cleanup
# ============================================================
step "Copy vendor debs & final cleanup"

cp -f /packages/libmali/*.deb / 2>/dev/null || true
cp -f /packages/rkisp/*.deb / 2>/dev/null || true
cp -f /packages/rkaiq/*.deb / 2>/dev/null || true
cp -rf /usr/lib/firmware/rockchip/ / 2>/dev/null || true

echo -e "\033[36m  -> Removing qv4l2/qvidcap ...\033[0m"
apt-get remove -fy qv4l2 qvidcap 2>/dev/null || true

echo -e "\033[32m    [OK] Vendor debs copied\033[0m"

# ============================================================
#  Step 20: Organize firmware directory
# ============================================================
step "Organize firmware & clean package dirs"
rm -rf /usr/lib/firmware
mkdir -p /usr/lib/firmware/
if [ -d /rockchip ]; then
	mv /rockchip /usr/lib/firmware/
fi

apt list --installed 2>/dev/null | grep -v oldstable | cut -d/ -f1 | xargs apt-mark hold >/dev/null 2>&1 || true

# ============================================================
#  Step 21: Shrink - remove unnecessary packages
# ============================================================
step "Shrink: remove unnecessary packages"

# DRI libraries - keep only the ones needed for Rockchip
if [ -e "/usr/lib/arm-linux-gnueabihf/dri" ]; then
	sed -i "1aexport LD_PRELOAD=/usr/lib/arm-linux-gnueabihf/libdrm-cursor.so.1" /usr/bin/X
	cd /usr/lib/arm-linux-gnueabihf/dri/
	cp kms_swrast_dri.so swrast_dri.so rockchip_dri.so /
	rm /usr/lib/arm-linux-gnueabihf/dri/*.so
	mv /*.so /usr/lib/arm-linux-gnueabihf/dri/
elif [ -e "/usr/lib/aarch64-linux-gnu/dri" ]; then
	sed -i "1aexport LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libdrm-cursor.so.1" /usr/bin/X
	cd /usr/lib/aarch64-linux-gnu/dri/
	cp kms_swrast_dri.so swrast_dri.so rockchip_dri.so /
	rm /usr/lib/aarch64-linux-gnu/dri/*.so
	mv /*.so /usr/lib/aarch64-linux-gnu/dri/
	rm -f /etc/profile.d/qt.sh
fi
cd /

# Remove large unused components
pkg_purge "AMD GPU libs" libamd-comgr2 libamdhip64-5 libdrm-amdgpu1 xserver-xorg-video-amdgpu xserver-xorg-video-ati xserver-xorg-video-radeon xserver-xorg-video-nouveau
pkg_purge "LLVM runtime" libllvm19 libllvm17t64
pkg_purge "WebKit/WPE" libwpewebkit-2.0-1 libwebkit2gtk-4.1-0 libwebkitgtk-6.0-4 gir1.2-webkit2-4.1 gstreamer1.0-wpe libwpe-1.0-1 libwpebackend-fdo-1.0-1
pkg_purge "Scientific libs" libvtk9.3 libgdal36 gdal-data gdal-plugins libz3-4 libdnnl3.6 libcodec2-1.2
pkg_purge "GCC toolchain" gcc g++ cpp gcc-14 g++-14 cpp-14 gcc-14-aarch64-linux-gnu g++-14-aarch64-linux-gnu cpp-14-aarch64-linux-gnu gcc-aarch64-linux-gnu g++-aarch64-linux-gnu cpp-aarch64-linux-gnu binutils binutils-aarch64-linux-gnu binutils-common cmake cmake-data
pkg_purge "Debug symbol pkgs" '*-dbgsym'
pkg_purge "Other unused pkgs" debian-keyring speech-dispatcher proj-data libasan8 xserver-xorg-video-all

echo -e "\033[36m  -> Autoremoving orphaned dependencies ...\033[0m"
apt-get autoremove -y --allow-change-held-packages 2>/dev/null || true

# ============================================================
#  Step 22: Shrink - clean docs / headers / cache
# ============================================================
step "Shrink: clean docs / headers / cache"

echo -e "\033[36m  -> Purging unused locales ...\033[0m"
locale-gen --purge en_US.UTF-8 zh_CN.UTF-8 2>/dev/null || true
find /usr/share/locale -mindepth 1 -maxdepth 1 \
	! -name 'en' ! -name 'zh*' ! -name 'locale.alias' \
	-exec rm -rf {} + 2>/dev/null || true

echo -e "\033[36m  -> Removing unused fonts ...\033[0m"
rm -rf /usr/share/fonts/X11 /usr/share/fonts/type1

echo -e "\033[36m  -> Cleaning APT cache ...\033[0m"
apt-get clean 2>/dev/null || true
rm -rf /var/cache/apt/* /var/lib/apt/lists/* /packages

# ============================================================
#  Done
# ============================================================
echo ""
echo -e "\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[1;32m  [OK] All chroot steps completed\033[0m"
echo -e "\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

CHEOF

echo -e "\033[36m Cleanup.....................\033[0m"
