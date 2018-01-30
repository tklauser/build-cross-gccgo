#!/bin/bash
#
# build-cross-gccgo - build a GCC cross-compiler toolchain with Go support
#
# Copyright (c) 2018 Tobias Klauser <tklauser@distanz.ch>
#
# Based on Erik Westrup's GCC cross-compiler builder:
# https://github.com/erikw/ewxb_gcc_cross-compiler_builder

set -e

# Cross variables.
HOST="amd64-linux-gnu"
BUILD="$HOST"
TARGET="nios2-linux-gnu"
LINUX_ARCH="nios2"
LINUX_VERSION="4.15"

# Work directories
WORK="/scratch/cross-gccgo"
SRC="$WORK/src"
OBJ="$WORK/obj"
TOOLS="$WORK/tools"
SYSROOT="$WORK/sysroot"

JOBS=4

scriptname=${0##*/}

usage() {
        echo "usage: ${scriptname}"
}

log() {
        local fmt=""
        if [ "$#"  -eq 1 ]; then
                fmt="%s"
        elif [ "$#"  -gt 1 ]; then
                fmt="$1"
                shift 1
        fi
        printf "%s ${fmt}\n" "|>" "$@"
}

# Log stdout and stderr.
date=$(date "+%Y-%m-%d-%H%M%S")
logfile="${scriptname}_${date}.log"
exec > >(tee -a "$logfile")
exec 2> >(tee -a "$logfile" >&2)
log "$(date "+%Y-%m-%d-%H:%M:%S") Appending stdout & stdin to: ${logfile}"

setup_and_enter_dir() {
        local dir="$1"
        if [ -d "$dir" ]; then
                printf "%s exists, delete it? [Y/n]: " "$dir"
                read delete
                if ([ -z "$delete" ] || [[ "$delete" = [yY] ]]); then
                        rm -rf "$dir"
                        mkdir "$dir"
                fi
        else
                mkdir "$dir"
        fi
        cd "$dir"
}

clean() {
        mkdir -p $WORK
        mkdir -p $SRC
        rm -rf $OBJ
        rm -rf $TOOLS
        rm -rf $SYSROOT
        mkdir $OBJ
        mkdir $TOOLS
        mkdir $SYSROOT
        mkdir -p $SYSROOT/usr/include
}

fetch_sources() {
        log "Setting up work directories and fetching sources"

        cd $SRC

        if ! [ -d binutils ] ; then
                git clone git://sourceware.org/git/binutils-gdb.git binutils
	else
		cd binutils
		git pull
		cd $SRC
	fi

        if ! [ -d gcc ] ; then
                git clone https://github.com/gcc-mirror/gcc.git
	else
		cd gcc
		# drop previously linked gofrontend, it will be linked again
		# below
		git checkout -f
		git pull
		cd $SRC
	fi

	cd gcc
	contrib/download_prerequisites
	cd $SRC

        if ! [ -d gofrontend ] ; then
                #git clone https://go.googlesource.com/gofrontend
                git clone https://github.com/tklauser/gofrontend.git
		cd gofrontend
		git checkout nios2
		cd $SRC
	fi

	cd $SRC/gcc
	GOFRONTEND=$SRC/gofrontend
	# from https://github.com/golang/gofrontend/blob/master/HACKING
	rm -rf gcc/go/gofrontend
	ln -s $GOFRONTEND/go gcc/go/gofrontend
	rm -rf libgo
	mkdir libgo
	for f in $GOFRONTEND/libgo/* ;
		do ln -s $f libgo/`basename $f`
	done
	cd $SRC

        if ! [ -d glibc ] ; then
		git clone git://sourceware.org/git/glibc.git
	else
		cd glibc
		git pull
		cd $SRC
	fi

        if ! [ -d linux ] ; then
		git clone git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
	else
		cd linux
		git pull
		cd $SRC
	fi
}

build_binutils() {
	log "Building binutils"

	setup_and_enter_dir "$OBJ/binutils"

	$SRC/binutils/configure \
		--prefix=$TOOLS \
		--target=$TARGET \
		--with-sysroot=$SYSROOT

	make -j $JOBS
	make install
}

build_gcc1() {
	log "Building barebone cross GCC so glibc headers can be compiled"

	setup_and_enter_dir "$OBJ/gcc1"

	$SRC/gcc/configure \
		--prefix=$TOOLS \
		--build=$BUILD \
		--host=$HOST \
		--target=$TARGET \
		--enable-languages=c \
		--without-headers \
		--with-newlib \
		--with-pkgversion="${USER}'s $TARGET GCC stage1 cross-compiler" \
		--disable-libgcc \
		--disable-shared \
		--disable-threads \
		--disable-libssp \
		--disable-libgomp \
		--disable-libmudflap \
		--disable-libquadmath \
		--disable-libquadmath-support

	PATH="$TOOLS/bin:$PATH" make -j $JOBS all-gcc
	PATH="$TOOLS/bin:$PATH" make install-gcc
}

build_linux_headers() {
	log "Installing Linux header files"

	cd $SRC/linux
	git clean -f -x -d

	make clean
	make headers_install \
		ARCH=$LINUX_ARCH \
		INSTALL_HDR_PATH=$SYSROOT/usr
}

build_glibc_bootstrap() {
	log "Installing header files and bootstraping glibc"

	setup_and_enter_dir "$OBJ/glibc-headers"

	LD_LIBRARY_PATH_old="$LD_LIBRARY_PATH"
	unset LD_LIBRARY_PATH

	BUILD_CC=gcc \
	CC=$TOOLS/bin/$TARGET-gcc \
	CXX=$TOOLS/bin/$TARGET-g++ \
	AR=$TOOLS/bin/$TARGET-ar \
	RANLIB=$TOOLS/bin/$TARGET-ranlib \
	$SRC/glibc/configure \
		--prefix=/usr \
		--build=$BUILD \
		--host=$TARGET \
		--with-headers=$sysroot/usr/include \
		--with-binutils=$TOOLS/$TARGET/bin \
		--enable-add-ons \
		--enable-kernel="${LINUXV##*-}" \
		--disable-profile \
		--without-gd \
		--without-cvs \
		--with-tls \
		libc_cv_ctors_header=yes \
		libc_cv_gcc_builtin_expect=yes \
		libc_cv_forced_unwind=yes \
		libc_cv_c_cleanup=yes

	make install-headers install_root=$SYSROOT

	# TODO(tk): is this still needed?
	mkdir -p $SYSROOT/usr/lib
	make csu/subdir_lib
	cp csu/crt1.o csu/crti.o csu/crtn.o $SYSROOT/usr/lib

	$TOOLS/bin/$TARGET-gcc -nostdlib -nostartfiles -shared -x c /dev/null -o $SYSROOT/usr/lib/libc.so

	touch $SYSROOT/usr/include/gnu/stubs.h

	export LD_LIBRARY_PATH="$LD_LIBRARY_PATH_old"
}

build_gcc2() {
	log "Building bootstrapped gcc that can compile a full glibc"

	setup_and_enter_dir "$OBJ/gcc2"

	$SRC/gcc/configure \
		--prefix=$TOOLS \
		--target=$TARGET \
		--build=$BUILD \
		--host=$HOST \
		--with-sysroot=$SYSROOT \
		--with-pkgversion="${USER}'s $TARGET GCC stage2 cross-compiler" \
		--enable-languages=c \
		--disable-libssp \
		--disable-libgomp \
		--disable-libmudflap \
		--with-ppl=no \
		--with-isl=no \
		--with-cloog=no \
		--with-libelf=no \
		--disable-nls \
		--disable-multilib \
		--disable-libquadmath \
		--disable-libquadmath-support \
		--disable-libatomic \

	PATH="$TOOLS/bin:$PATH" make -j $JOBS
	PATH="$TOOLS/bin:$PATH" make install
}

build_glibc() {
	log "Building a full glibc for $TARGET"

	setup_and_enter_dir "$OBJ/glibc"

	LD_LIBRARY_PATH_old="$LD_LIBRARY_PATH"
	unset LD_LIBRARY_PATH

	BUILD_CC=gcc \
	CC=$TOOLS/bin/$TARGET-gcc \
	CXX=$TOOLS/bin/$TARGET-g++ \
	AR=$TOOLS/bin/$TARGET-ar \
	RANLIB=$TOOLS/bin/$TARGET-ranlib \
	$SRC/glibc/configure \
		--prefix=/usr \
		--build=$BUILD \
		--host=$TARGET \
		--disable-profile \
		--without-gd \
		--without-cvs \
		--enable-add-ons \
		--enable-kernel=$LINUX_VERSION \
		libc_cv_forced_unwind=yes

	PATH="$TOOLS/bin:$PATH" make -j $JOBS
	PATH="$TOOLS/bin:$PATH" make install install_root=$SYSROOT

	export LD_LIBRARY_PATH="$LD_LIBRARY_PATH_old"
}

build_gcc3() {
	log "Building the full gcc"

	setup_and_enter_dir "$OBJ/gcc3"

	$SRC/gcc/configure \
		--prefix=$TOOLS \
		--target=$TARGET \
		--build=$BUILD \
		--host=$HOST \
		--with-sysroot=$SYSROOT \
		--enable-languages=c,c++,go \
		--disable-libssp \
		--disable-libgomp \
		--disable-libmudflap \
		--disable-libquadmath \
		--disable-libquadmath-support \
		--with-pkgversion="${USER}'s $TARGET GCC stage3 cross-compiler" \
		--with-ppl=no \
		--with-isl=no \
		--with-cloog=no \
		--with-libelf=no

	PATH="$TOOLS/bin:$PATH" make -j $JOBS
	PATH="$TOOLS/bin:$PATH" make install

	cd $TOOLS/bin
	for file in $(find . -type f) ; do
		tool_name=$(echo $file | sed -e "s/${TARGET}-\(.*\)$/\1/")
		ln -sf "$file" "$tool_name"
	done
}

test_compile() {
	log "Testing to compile a C program"

	test_path="/tmp/${TARGET}_test_$$"
	setup_and_enter_dir "$test_path"

	cat <<- EOF > hello.c
	#include <stdlib.h>
	#include <stdio.h>
	int main(int argc, const char *argv[])
	{
		printf("%s\n", "Hello, Nios II world!");
		return EXIT_SUCCESS;
	}
	EOF

	PATH="$TOOLS/bin:$PATH" $TARGET-gcc -Wall -Werror -static -o helloc ./hello.c
	log "RUN MANUALLY: Produced test-binary at: $test_path/helloc"

	log "Testing to compile a Go program."

	cat <<- EOF > hello.go
	package main
	import (
		"fmt"
		"runtime"
	)
	func main() {
		fmt.Printf("Hello, Gopher! I'm running on GOOS=%s and GOARCH=%s\n", runtime.GOOS, runtime.GOARCH)
	}
	EOF

	# TODO enable when mgo is built
	#PATH="$TOOLS/bin:$PATH" go build -compiler gccgo ./hellogo.go
	#log "RUN MANUALLY: Produced test-binary at: $test_path/hellogo"
	PATH="$TOOLS/bin:$PATH" $TARGET-gccgo -Wall -Werror -static -o hellogo-static ./hello.go
	log "RUN MANUALLY: Produced statically linked test-binary at: $test_path/hellogo-static"

	PATH="$TOOLS/bin:$PATH" $TARGET-gccgo -Wall -Werror -o hellogo-dynamic ./hello.go
	log "RUN MANUALLY: Produced dynamically linked test-binary at: $test_path/hellogo-dynamic"

	log "Access compiler tools: $ export PATH=\"$TOOLS/bin:\$PATH\""
	log "Run dynamically linked Go programs: $ export LD_LIBRARY_PATH=\"$TOOLS/$TARGET/lib:\$LD_LIBRARY_PATH\""
}

clean
fetch_sources
build_binutils
build_gcc1
build_linux_headers
build_glibc_bootstrap
build_gcc2
build_glibc
build_gcc3
test_compile
