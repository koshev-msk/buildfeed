#!/bin/sh

# build system feeds package via OpenWrt SDK
# Konstantine Shevlakov at <shevlakkov@132lan.ru> 2022

# release OpenWrt
RELEASE=21.02.3
# Output directory
OUTPUT_DIR="./"
# Verbose log
LOG=0
# Include SDK feeds
SDK_FEEDS=0

# Script settings
if [ -f packages.lst ]; then
	PACKAGES="$(grep -v '^#' packages.lst)"
fi
# Muliplie arch build
# db stored in file platfomrs.cfg
TARGETS="$(grep -v '^#' platforms.cfg | awk '{print $1}')"
# repositories list
FEEDS="$(grep -v '^#' feeds.cfg | awk '{print $1}')"

# install packages on deb-based host system
install_dep(){
	ACT="install"
	if [ ! -f dep_installled ]; then
		sudo apt update
		_dep
		touch dep_installed
	else
		echo "Dependies is installed. Run script with key -b"
	fi
}

# remove packages on host system
clean_dep(){
	ACT="remove"
	_dep
}

# apt command
_dep(){
	sudo -E apt $ACT -y build-essential ccache ecj fastjar file g++ gawk \
	gettext git java-propose-classpath libelf-dev libncurses5-dev \
	libncursesw5-dev libssl-dev python python2.7-dev python3 unzip curl \
	python-distutils-extra python3-setuptools python3-dev rsync \
	swig time xsltproc zlib1g-dev wget curl
}

# Run build scanario
run_build(){
	if [ ! -f dep_installed ]; then
		echo "Dependies is NOT installed. First run script with key -d"
		exit 0
	fi
	if [ ! -d sdk-$RELEASE-$PLATFORM-$SOC ];  then
		SDKFILE=$(curl -s https://downloads.openwrt.org/releases/$RELEASE/targets/$PLATFORM/$SOC/ --list-only | sed -e 's/<[^>]*>/ /g' | awk '/openwrt-sdk/{print $1}')
		echo -n "Download $SDKFILE."
		wget https://downloads.openwrt.org/releases/$RELEASE/targets/$PLATFORM/$SOC/$SDKFILE >/dev/null 2>&1 && echo " Done!" || echo " Fail."
		if [ $LOG -eq 0 ]; then
			echo -n "Unpack SDK."
			tar xf *.tar.xz* && echo " Done!" || echo " Fail."
		else
			tar xvf *.tar.xz* 
		fi
		rm *.tar.xz*
		mv $(ls -d openwrt-sdk-*) sdk-$RELEASE-$PLATFORM-$SOC
		export PATH=${PATH}:${PWD}/sdk-$RELEASE-$PLATFORM-$SOC/staging_dir/host/bin
	fi
	# backup-restore feeds.conf.default
	if [ -f sdk-$RELEASE-$PLATFORM-$SOC/feeds.conf.default.bak ]; then
		cp -f sdk-$RELEASE-$PLATFORM-$SOC/feeds.conf.default.bak sdk-$RELEASE-$PLATFORM-$SOC/feeds.conf.default
	else
 		cp -f sdk-$RELEASE-$PLATFORM-$SOC/feeds.conf.default sdk-$RELEASE-$PLATFORM-$SOC/feeds.conf.default.bak
	fi
	for r in $FEEDS; do
		FEED_NAME=$r
		FEED_URL=$(cat feeds.cfg | grep -v '^#' | awk '{print $2}')
		echo "src-git $FEED_NAME $FEED_URL" >> sdk-$RELEASE-$PLATFORM-$SOC/feeds.conf.default
	done
	# update and install feeds
	echo -n "Update all feeds SDK $PLATFORM $SOC."
	sdk-$RELEASE-$PLATFORM-$SOC/scripts/feeds update -a >/dev/null 2>&1 && echo " Done!" || echo " Fail."
	echo -n "Install all feeds SDK $PLATFORM $SOC."
	sdk-$RELEASE-$PLATFORM-$SOC/scripts/feeds install -a >/dev/null 2>&1 && echo " Done!" || echo " Fail."
	# build packages
	cd sdk-$RELEASE-$PLATFORM-$SOC
	echo -n "Prepare compile packages $PLATFORM $SOC."
	make defconfig >/dev/null && echo " Done!" || echo " Fail."
	if [ $SDK_FEEDS - eq 1 ]; then
		FEEDS="$(grep -v '^#' sdk-$RELEASE-$PLATFORM-$SOC/feeds.conf.default | awk '{print $1}')"
	fi
	for f in $FEEDS; do
		mkdir -p ../logs/$PLATFORM/$f/
		if [ ! "$PACKAGES" ]; then
			PACKAGES=$(ls -1 package/feeds/${f}/)
		fi
		for p in $PACKAGES; do
			if [ -n package/feeds/${f}/${p} ]; then
				echo -n "Compile package: ${p}."
				if [ $LOG -eq 1 ]; then
					make -j$((`nproc`+1)) V=sc package/feeds/${f}/${p}/compile | tee ../logs/$PLATFORM/$f/build-${p}.log
				else
					make -j$((`nproc`+1)) V=0 package/feeds/${f}/${p}/compile | tee ../logs/$PLATFORM/$f/build-${p}.log
				fi
			fi
		done
	done
	cd ../
	# make repository
	echo "Prepare repository \"$OUTPUT_DIR/packages/$ARCH_PKG/\""
	ARCH_PKG=$(ls sdk-$RELEASE-$PLATFORM-$SOC/bin/packages/)
	mkdir -p $OUTPUT_DIR/packages/$ARCH_PKG/
	# generate keys
	if  [ ! -d keys ]; then
		mkdir -p keys
		cd keys
		../sdk-$RELEASE-$PLATFORM-$SOC/staging_dir/host/bin/usign -G -s repo.key -p repo.pub
		cd ..
	fi
	for f in $FEEDS; do
		mv sdk-$RELEASE-$PLATFORM-$SOC/bin/packages/$ARCH_PKG/$f/ $OUTPUT_DIR/packages/$ARCH_PKG/
		sdk-$RELEASE-$PLATFORM-$SOC/scripts/ipkg-make-index.sh $OUTPUT_DIR/packages/$ARCH_PKG/$f/ >  $OUTPUT_DIR/packages/$ARCH_PKG/$f/Packages
		cat  packages/$ARCH_PKG/${f}/Packages | gzip > packages/$ARCH_PKG/${f}/Packages.gz
		# Sign repository
		sdk-$RELEASE-$PLATFORM-$SOC/staging_dir/host/bin/usign -S -m $OUTPUT_DIR/packages/$ARCH_PKG/${f}/Packages -s keys/repo.key  $OUTPUT_DIR/packages/$ARCH_PKG/${f}/Packages.sig
		echo "Repository $PLATFORM $SOC $ARCH_PKG $f created!"
	done
	# copy public key
	cp keys/repo.pub $OUTPUT_DIR/packages/
}


# Remove sdk dir packages and logs
clean_sdk(){
	rm -rf sdk-* openwrt-sdk-* $OUTPUT_DIR/packages/ logs/
}

# remove all 
clean_all(){
	clean_sdk
	clean_dep
	rm -rf logs/ keys/ dep_installed $OUTPUT_DIR/packages/
}

# Menu actions select
case $1 in
	-d) install_dep ;;
	-b)
		if [ ! -f platforms.cfg ]; then
			echo "`basename $0`: file platforms.cfg not found. Abort!"
			exit 0
		fi
		for t in $TARGETS; do
			PLATFORM=$t
			SOC=$(cat platforms.cfg | grep $t | awk '{print $2}')
			run_build
		done
	;;
	-g)
		if [ ! -f platforms.cfg ]; then
			echo "`basename $0`: file platforms.cfg not found. Abort!"
			exit 0
		fi
		for t in $TARGETS; do
			PLATFORM=$t
			SOC=$(cat platforms.cfg | grep $t | awk '{print $2}')
			run_build
			rm -rf sdk-*
		done
	;;
	-c) clean_sdk ;;
	-r) clean_all ;;
	*) echo "Usage:\n\t`basename $0` [OPTIONS]\n\t \
		OPTIONS:\n\t \
		-d -- install dependies\n\t \
		-b -- build packages. \n\t \
		-g -- build packages via clean every sdk dir\n\t
		-c -- clean sdk\n\t \
		-r -- remove sdk, packages, keys, dependies"
	;;
esac
