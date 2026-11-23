#!/bin/sh
# roots.sh ARCH REPO PACKAGES...: run by h9build in the Alpine bootstrap root,
# with the new root's directory as an up layer at /r. Installs Wolfi packages
# into it with Alpine's apk.
#
# A package can be a list of alternatives, a|b|c: the first that the
# repository has is installed, and none is a warning, not an error. That's
# how Railpack's Debian package names are tried against Wolfi's.
#
# --no-scripts because apk runs scripts in a chroot, which h9 doesn't have;
# h9build makes busybox's applet links itself afterwards.
set -eu
arch=$1 repo=$2
shift 2
r=/r
# Alpine's apk keeps its database in /lib/apk, which would make /lib a
# directory that wolfi-baselayout's lib -> usr/lib link can't replace. glibc's
# loader is found through that link on arm64 (/lib/ld-linux-aarch64.so.1), so
# make it first: the database then lands in /usr/lib/apk, where Wolfi's own
# apk keeps it.
mkdir -p "$r/etc/apk/keys" "$r/usr/lib"
[ -e "$r/lib" ] || ln -s usr/lib "$r/lib"
cp /mnt/term/cwd/wolfi-signing.rsa.pub "$r/etc/apk/keys/"
apk() { command apk --root "$r" --no-cache --arch "$arch" --repository "$repo" --keys-dir "$r/etc/apk/keys" "$@"; }
apk --initdb --no-scripts add wolfi-baselayout >/dev/null
set -- "$@" ""
pkgs=
for p in "$@"; do
	[ -n "$p" ] || continue
	case $p in
	*'|'*)
		pick=
		IFS='|'
		for a in $p; do
			if apk add --simulate "$a" >/dev/null 2>&1; then
				pick=$a
				break
			fi
		done
		unset IFS
		if [ -z "$pick" ]; then
			echo "roots.sh: no Wolfi package for ${p%%|*} (tried ${p})" >&2
			continue
		fi
		pkgs="$pkgs $pick"
		;;
	*) pkgs="$pkgs $p" ;;
	esac
done
# shellcheck disable=SC2086
apk add --no-scripts $pkgs | grep -v '^(' || true
# shellcheck disable=SC2086
apk info -e $pkgs >/dev/null || { echo "roots.sh: some packages didn't install" >&2; exit 1; }
# shadow files are 0640 root: the guest can't read them, and nothing needs them.
rm -f "$r/etc/shadow" "$r/etc/gshadow"
echo "$pkgs" >"$r/etc/h9build-packages"
