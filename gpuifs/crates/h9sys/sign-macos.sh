#!/bin/sh
# sign-macos.sh BINARY: ad-hoc sign a gpuifs built with h9 with the
# hypervisor entitlement, which HVF needs before it makes a VM. hcpu, the
# emulator, also needs allow-jit under the hardened runtime, which h9's
# entitlements file grants.
#
#	cargo build -p gpuifs && crates/h9sys/sign-macos.sh target/debug/gpuifs
#
# The entitlements come from the hyper9 checkout the build used.
set -eu
bin=${1:?usage: sign-macos.sh BINARY}
here=$(cd "$(dirname "$0")" && pwd)
ent=${HYPER9_DIR:-$here/../../third_party/hyper9}/h9.entitlements
[ -f "$ent" ] || { echo "sign-macos.sh: no $ent (set HYPER9_DIR)" >&2; exit 1; }
exec codesign --force --sign - --entitlements "$ent" "$bin"
