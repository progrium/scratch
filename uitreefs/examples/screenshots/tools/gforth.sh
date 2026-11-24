#!/bin/bash
# gforth.sh [DIR]: build gforth 0.7.3 into the Alpine root that
# linuxroot.sh makes, for the Forth example. Alpine has no gforth package,
# so this takes Ubuntu's source (the release tarball and its patches; the
# GNU mirrors may be out of reach) and builds it with the root's own gcc,
# in a chroot, so it links against the root's musl. Needs root on the host.
# The tarball ships its kernel images (kernl*.fi), so no gforth is needed
# to build one; the timestamps are reset after patching so make doesn't
# try to rerun autoconf or rebuild those images.
set -e
UITREEFS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
DIR=${1:-$UITREEFS_DIR/third_party/hyper9/.local/linux/edge-tools}
E=https://dl-cdn.alpinelinux.org/alpine/edge
U=http://archive.ubuntu.com/ubuntu/pool/universe/g/gforth
[ -x "$DIR/usr/bin/gcc" ] || { echo "no Alpine root with gcc at $DIR: run linuxroot.sh" >&2; exit 1; }
B=$DIR/build
rm -rf "$B" && mkdir -p "$B" && cd "$B"
curl -fsSL -o orig.tar.xz "$U/gforth_0.7.3+dfsg.orig.tar.xz"
curl -fsSL -o debian.tar.xz "$U/gforth_0.7.3+dfsg-9build4.1.debian.tar.xz"
tar xJf orig.tar.xz && tar xJf debian.tar.xz && mv gforth-0.7.3.orig gforth
cd gforth
for p in $(cat ../debian/patches/series); do patch -p1 -s <../debian/patches/$p; done
touch aclocal.m4; sleep 1; touch configure; sleep 1
find . -name Makefile.in -o -name config.h.in -o -name 'stamp-h*' | xargs touch; sleep 1; touch kernl*.fi
cp /etc/resolv.conf "$DIR/etc/" 2>/dev/null || true
chroot "$DIR" /sbin/apk add --no-cache -X $E/main -X $E/community m4 make >/dev/null
chroot "$DIR" /bin/sh -c 'cd /build/gforth &&
	CFLAGS="-O2 -std=gnu99 -fcommon -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types -Wno-error=int-conversion" \
	./configure --prefix=/usr --without-check >/dev/null && make -j4 >/dev/null && make install >/dev/null &&
	gforth -e "2 3 + . cr bye"'
rm -rf "$B"
echo "$DIR/usr/bin/gforth"
