#!/bin/bash -e

if [ "$RELEASE" == "stretch" ]; then
	RELEASE='stretch'
elif [ "$RELEASE" == "buster" ]; then
	RELEASE='buster'
elif [ "$RELEASE" == "bullseye" ]; then
	RELEASE='bullseye'
elif [ "$RELEASE" == "bookworm" ]; then
	RELEASE='bookworm'
elif [ "$RELEASE" == "trixie" ]; then
	RELEASE='trixie'
else
    echo -e "\033[36m please input the os type: stretch, buster, bullseye, bookworm or trixie...... \033[0m"
fi

if [ "$ARCH" == "armhf" ]; then
	ARCH='armhf'
elif [ "$ARCH" == "arm64" ]; then
	ARCH='arm64'
else
    echo -e "\033[36m please input the os type,armhf or arm64...... \033[0m"
fi

if [ ! $TARGET ]; then
	TARGET='desktop'
fi

if [ -e rockchip-debian-$RELEASE-*.tar.gz ]; then
	rm rockchip-debian-$RELEASE-*.tar.gz
fi

cd ubuntu-build-service/$RELEASE-$TARGET-$ARCH

echo -e "\033[36m Staring Download...... \033[0m"

case "${DEBIAN_RESUME:-0}" in
	0)
		make clean
		./configure
		;;
	1)
		[[ -f config/common && -f chroot/var/lib/dpkg/status && -d .build ]] || {
			echo "Cannot resume: no configured live-build chroot in $PWD" >&2
			exit 1
		}
		echo "Resuming live-build with the retained chroot and configuration."
		;;
	*) echo "DEBIAN_RESUME must be 0 or 1" >&2; exit 1 ;;
esac

make

if [ -e rockchip-debian-$RELEASE-*.tar.gz ]; then
	sudo chmod 0666 rockchip-debian-$RELEASE-*.tar.gz
	mv rockchip-debian-$RELEASE-*.tar.gz ../../
else
	echo -e "\e[31m Failed to run livebuild, please check your network connection. \e[0m"
fi
