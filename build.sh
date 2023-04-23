#!/bin/sh

# build system feeds package via OpenWrt SDK
# Konstantine Shevlakov at <shevlakov@132lan.ru> 2022

# release OpenWrt
RELEASE=21.02.6
# Output directory
OUTPUT_DIR="./"
# Verbose log
# 0 - no log
# 1 - minimal log
# 2 - verbose log
LOG=1
# Include SDK feeds
# 0 - not included SDK feeds
# 1 - include SDK feeds
SDK_FEEDS=0
# Signing repository
# 0 - No sign repo
# 1 - sign repo
SIGN=1
# Build add packages
# use selective packages in packages.lst
# 0 - enable selective packages list
# 1 - build all feed packages
PKG_FEEDS=0


# Stuff

# Script settings
# user package list
if [ $PKG_FEEDS -eq 0 ]; then
	if [ -f packages.lst ]; then
		PACKAGES="$(grep -v '^#' packages.lst)"
	else
		echo "packages.lst not found. Abort!"
		exit 0
	fi
fi
# user repositories list
FEEDS="$(grep -v '^#' feeds.cfg | awk '{print $2}')"

# install packages on deb-based host system
install_dep(){
	ACT="install"
	if [ ! -f dep_installled ]; then
		sudo apt update
		_dep
		touch dep_installed
	else
		echo "Dependies is installed. Run script with key -b or -B"
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
	swig time xsltproc zlib1g-dev wget
}

# Run build scenario
run_build(){
	# check dependies
	if [ ! -f dep_installed ]; then
		echo "Dependies is NOT installed. First run script with key -d"
		exit 0
	fi
	# download and unpack SDK
	if [ ! -d sdk-$RELEASE-$PLATFORM-$SOC ];  then
		SDKFILE=$(curl -s https://downloads.openwrt.org/releases/$RELEASE/targets/$PLATFORM/$SOC/ --list-only | sed -e 's/<[^>]*>/ /g' | awk '/openwrt-sdk/{print $1}')
		echo -n "${PLATFORM}/${SOC}: download $SDKFILE."
		wget https://downloads.openwrt.org/releases/$RELEASE/targets/$PLATFORM/$SOC/$SDKFILE >/dev/null 2>&1 && echo " Done!" || echo " Fail."
		test -f $SDKFILE || return
		if [ $LOG -lt 2 ]; then
			echo -n "${PLATFORM}/${SOC}: unpack SDK archive."
			tar xf *.tar.xz* && echo " Done!" || echo " Fail."
		else
			tar xvf *.tar.xz*
		fi
		rm *.tar.xz*
		mv $(ls -d openwrt-sdk-*) sdk-$RELEASE-$PLATFORM-$SOC
	fi
	# export SDK path
	export PATH=${DEFPATH}:${PWD}/sdk-$RELEASE-$PLATFORM-$SOC/staging_dir/host/bin
	# backup-restore feeds.conf.default
	if [ -f sdk-$RELEASE-$PLATFORM-$SOC/feeds.conf.default.bak ]; then
		cp -f sdk-$RELEASE-$PLATFORM-$SOC/feeds.conf.default.bak sdk-$RELEASE-$PLATFORM-$SOC/feeds.conf.default
	else
 		cp -f sdk-$RELEASE-$PLATFORM-$SOC/feeds.conf.default sdk-$RELEASE-$PLATFORM-$SOC/feeds.conf.default.bak
	fi
	# add user feed
	while read line; do
		case $line in
			*#*) continue ;;
			*)
				echo "$line"  >> sdk-$RELEASE-$PLATFORM-$SOC/feeds.conf.default
			;;
		esac
	done < feeds.cfg
	# update and install feeds
	if [ $LOG -lt 2 ]; then
		echo -n "${PLATFORM}/${SOC}: update all SDK feeds."
		sdk-$RELEASE-$PLATFORM-$SOC/scripts/feeds update -a >/dev/null 2>&1 && echo " Done!" || echo " Fail."
		echo -n  "${PLATFORM}/${SOC}: install all SDK feeds."
		sdk-$RELEASE-$PLATFORM-$SOC/scripts/feeds install -a >/dev/null 2>&1 && echo " Done!" || echo " Fail."
	else
		echo "${PLATFORM}/${SOC}: update all SDK feeds."
		sdk-$RELEASE-$PLATFORM-$SOC/scripts/feeds update -a
		echo "${PLATFORM}/${SOC}: install all SDK feeds."
		sdk-$RELEASE-$PLATFORM-$SOC/scripts/feeds install -a
	fi
	# build packages
	cd sdk-$RELEASE-$PLATFORM-$SOC
	echo -n "${PLATFORM}/${SOC}: prepare compile packages."
	make defconfig >/dev/null && echo " Done!" || echo " Fail."
	if [ $SDK_FEEDS -eq 1 ]; then
		FEEDS="$(grep -v '^#' feeds.conf.default | awk '{print $2}')"
	fi
	for f in $FEEDS; do
		if [ $LOG -ge 1 ]; then
			mkdir -p ../logs/${PLATFORM}_${SOC}/$f/
		fi
		if [ $PKG_FEEDS -eq 1 ]; then
			PACKAGES=$(ls -1 package/feeds/${f}/)
		fi
		for p in $PACKAGES; do
			if [ -n package/feeds/${f}/${p} ]; then
				echo "${PLATFORM}/${SOC}: compile package: ${p}."
				if [ $LOG -eq 2 ]; then
					make -j$((`nproc`+1)) \
						V=sc package/feeds/${f}/${p}/compile | tee ../logs/${PLATFORM}_${SOC}/$f/build-${p}.log
				elif [ $LOG -eq 1 ]; then 
					make -j$((`nproc`+1)) V=0 package/feeds/${f}/${p}/compile | tee ../logs/${PLATFORM}_${SOC}/$f/build-${p}.log
				else
					make -j$((`nproc`+1)) package/feeds/${f}/${p}/compile
				fi
			fi
		done
	done
	cd ../
	# make repository dir
	ARCH_PKG=$(ls sdk-$RELEASE-$PLATFORM-$SOC/bin/packages/)
	echo "${PLATFORM}/${SOC}: prepare repository \"$OUTPUT_DIR/packages/$ARCH_PKG/\""
	mkdir -p $OUTPUT_DIR/packages/$ARCH_PKG/
	# generate keys
	if  [ ! -d keys ]; then
		mkdir -p keys
		cd keys
		../sdk-$RELEASE-$PLATFORM-$SOC/staging_dir/host/bin/usign -G -s repo.key -p repo.pub
		cd ..
	fi
	# copy packages feed
	for f in $FEEDS; do
		cp -rp sdk-$RELEASE-$PLATFORM-$SOC/bin/packages/$ARCH_PKG/$f/ $OUTPUT_DIR/packages/$ARCH_PKG/
		cd $OUTPUT_DIR/packages/$ARCH_PKG/${f}
		# find and remove duplicate packages
		if [ -f Packages ]; then
			PKG_REPO=$(awk '/Package/{print $2}' Packages)
			for pkg in $PKG_REPO; do
				CNT=$(ls ${pkg}_* | wc -l)
				if [ $CNT -ge 2 ]; then
					VER=$(grep -A2 -i "$pkg" Packages | awk '/Version/{print $2}')
					echo "${PLATFORM}/${SOC}: Package ${pkg} duplicate. Oldversion ${VER} remove."
					rm ${pkg}*${VER}*
				fi
			done
		fi
		${WORKDIR}/sdk-$RELEASE-$PLATFORM-$SOC/scripts/ipkg-make-index.sh ./ > Packages
		cat  Packages | gzip > Packages.gz
		cd $WORKDIR
		if [ $SIGN -eq 1 ]; then
		# Sign repository
			sdk-$RELEASE-$PLATFORM-$SOC/staging_dir/host/bin/usign -S -m $OUTPUT_DIR/packages/$ARCH_PKG/${f}/Packages -s keys/repo.key  $OUTPUT_DIR/packages/$ARCH_PKG/${f}/Packages.sig
		fi
		echo "${PLATFORM}/${SOC}: repository \"$OUTPUT_DIR/packages/$ARCH_PKG/$f\" created."
	done
	if [ $SIGN -eq 1 ]; then
		# copy public key
		cp keys/repo.pub $OUTPUT_DIR/packages/ 
		echo "${PLATFORM}/${SOC}: repository \"$OUTPUT_DIR/packages/$ARCH_PKG/$f\" signed."
	fi
}


# Remove sdk dir packages and logs
clean_sdk(){
	rm -rf sdk-* openwrt-sdk-* logs/
}

# remove all 
clean_all(){
	clean_sdk
	clean_dep
	rm -rf logs/ keys/ dep_installed $OUTPUT_DIR/packages/
}
# Default env PATH
DEFPATH=${PATH}
WORKDIR=${PWD}
# Menu actions select
case $1 in
	-d) install_dep ;;
	-B)
		if [ ! -f platforms.cfg ]; then
			echo "`basename $0`: file platforms.cfg not found. Abort!"
			exit 0
		fi
		JOB=1
		while read line; do
			case $line in
			 	*#*) continue ;;
				*)
					set -- $line
					echo "======= JOB: $JOB ======="
					PLATFORM=$1
					SOC=$2
					run_build
					JOB=$(($JOB+1))
			esac
		done  < platforms.cfg
	;;
	-b)
		if [ ! -f platforms.cfg ]; then
			echo "`basename $0`: file platforms.cfg not found. Abort!"
			exit 0
		fi
		JOB=1
		while read line; do
			 case $line in
			 	*#*) continue ;;
				*)
					set -- $line
					echo "======= JOB: $JOB ======="
					PLATFORM=$1
					SOC=$2
					run_build
					rm -rf sdk-*
					JOB=$(($JOB+1))
				;;
			esac
		done < platforms.cfg
	;;
	-c) clean_sdk ;;
	-r) clean_all ;;
	*) echo "Usage:\n`basename $0` [OPTIONS]\n\
\tOPTIONS:\n\t\
-d -- install dependies\n\t\
-B -- build packages. \n\t\
-b -- build packages via clean every sdk dir.\n\t\
-c -- clean sdk.\n\t\
-r -- remove sdk, packages, keys, dependies."
	;;
esac
# Restore env PATH
export PATH=${DEFPATH}
