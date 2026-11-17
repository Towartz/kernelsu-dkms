# shellcheck shell=bash
# AUR Maintainer: Shadichy <shadichy@blisslabs.org>

_pkg=kernelsu-next
pkgname=kernelsu-dkms
pkgver=3.4.2+198+g7ccf6147
_ver=$pkgver
pkgrel=1
_branch=dev
pkgdesc="A Kernel based root solution for Android (KernelSU-Next). DKMS module for Container-based solutions such as Waydroid."
arch=('any')
url="https://github.com/KernelSU-Next/KernelSU-Next"
_upstream="https://github.com/tiann/$_pkg.git"
license=('GPL-2.0-only')
depends=('dkms')
optdepends=('modloader')
makedepends=('git' 'rust' 'cargo')
options=('!strip' '!emptydirs')

# Using custom download agent to shallow clone the repo
cat <<'EOF' >DLAGENTS
#!/bin/sh

PWD=$(pwd)

ORIGIN=${1#shallowclone+}
ORG_URL=${ORIGIN%%'?'*}
ORG_ARGS=${ORIGIN#*'?'}

DEST=${2}
REAL_DEST=${DEST%.part}

### Parse url parameters

arg_parser() {
  local args=$1
  shift

  IFS='&'
  set -- ${args}
  unset IFS

  BRANCH=
  COMMIT=
  TAG=
  RECURSE_SUBMODULES=
  DEPTH=1

  while [ $# -gt 0 ]; do
    case $1 in
      branch=*) BRANCH=${1#branch=} ;;
      commit=*) COMMIT=${1#commit=} ;;
      tag=*) TAG=${1#tag=} ;;
      recurse=true) RECURSE_SUBMODULES=1 ;;
      depth=*) DEPTH=${1#depth=} ;;
      *) : ;;
    esac
    shift
  done

  export BRANCH COMMIT TAG RECURSE_SUBMODULES DEPTH
}

arg_parser "${ORG_ARGS}"

update_src() {
  git fetch \
    --depth 1 \
    ${RECURSE_SUBMODULES:+'--recurse-submodules'} \
    origin "${COMMIT:-${BRANCH:-${TAG}}}"
}

### Verify if destination already exists and is a valid git repository with the correct remote URL

verify_dest() {
  local dest=$1 current_url
  [ -d "${dest}/.git" ] || return

  cd "${dest}"
  git remote set-url origin "${ORG_URL}"
  
  { # Abort any in-progress tasks
    git merge --abort ||
      git rebase --abort ||
      git cherry-pick --abort || :
  } 2>/dev/null

  # Update the existing shallow clone
  update_src
  git reset --hard FETCH_HEAD
  cd "${PWD}"

  ln -s "../${dest}" "../src/${dest}"
  echo ${dest}
  exit 0
}

verify_dest "${DEST}"
verify_dest "${REAL_DEST}"

### If not, perform a fresh shallow clone

rm -rf "${DEST}"
mkdir -p "${DEST}"

cd "${DEST}"
git init --quiet
git remote add origin "${ORG_URL}"

update_src
git reset --hard FETCH_HEAD

cd "${PWD}"

ln -s "../${REAL_DEST}" "../src/${REAL_DEST}"
echo ${REAL_DEST}
EOF
chmod +x DLAGENTS
export DLAGENTS="shallowclone::$(realpath "./DLAGENTS") %u %o"

source=(
	"${_pkg}::git+${url}.git#branch=${_branch}"
	'Makefile'
	'0001-Patch-KernelSU-Next-for-dkms-and-waydroid.patch'
	'dkms.conf'
	'00-kernelsu.conf'
	'load-kernelsu.in'
)

sha256sums=(
	'SKIP'
	'a836794d044068ee44f0e60b4f45f4f58e810a23e79cb800b4cba1dd9004e369'
	'0dc7f7db3f4c322f4c1c34a575195543723ae1386b0a66999594487047ecc5d4'
	'4fadba7db1e16d825d463e7a985a51cbe053185cc117f2081c92d5671b148541'
	'05feaafbbac794a68c7eeea8c0a4c5616fc9f6ef7e4b7540baf3f5d43fad5fb0'
	'f01d10fbcfba1b83134746ccfdc7ef4ceb61fa43593b94f039eac3469637429c'
)

pkgver() {
	cd "$srcdir/$_pkg"
	git fetch --unshallow --tags origin "$_branch" >/dev/null 2>&1 || true
	git describe --long --tags | sed 's#v##;s#-RC#.rc#;s#-#+#g'
}

prepare() {
	cd "$srcdir/$_pkg"
	git apply "$srcdir/0001-Patch-KernelSU-Next-for-dkms-and-waydroid.patch"
}

build() {
	cd "$srcdir/$_pkg/userspace/ksuinit"
	cargo build --release --target-dir .
}

package() {
	local dest="$pkgdir/usr/src/kernelsu-${pkgver}"
	mkdir -p "$dest"

	cd "$srcdir"
	cp -rpRLt "$dest" "${_pkg}/kernel/."

	cd "$_pkg"

	local _major _count _realver _tag
	_major=${pkgver%%.*}
	_count=$(git rev-list --count HEAD 2>/dev/null)
	_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "v${pkgver%%'+'*}")
	_realver=$((_major * 10000 + _count))

	local buildfile=kernel/Kbuild
	if [ ! -f "$buildfile" ]; then
		buildfile=kernel/Makefile
	fi

	cd "$srcdir"

	echo "ksu git ver: $_count (tag: $_tag)" >&2

	local _manager_args=""
	[ -n "${KSU_MANAGER_PACKAGE:-}" ] && _manager_args+=" KSU_MANAGER_PACKAGE=${KSU_MANAGER_PACKAGE}"
	[ -n "${KSU_NEXT_MANAGER_SIZE:-}" ] && _manager_args+=" KSU_NEXT_MANAGER_SIZE=${KSU_NEXT_MANAGER_SIZE}"
	[ -n "${KSU_NEXT_MANAGER_HASH:-}" ] && _manager_args+=" KSU_NEXT_MANAGER_HASH=${KSU_NEXT_MANAGER_HASH}"

	sed "s|@PKGVER@|${pkgver}|g;\
    s|@KSU_GIT_VERSION@|${_count}|g;\
    s|@KSU_GIT_TAG@|${_tag}|g;\
    s|@KSU_MANAGER_ARGS@|${_manager_args}|g;" "$(readlink -f dkms.conf)" >"$dest/dkms.conf"

	install -Dm644 "$(readlink -f Makefile)" "$dest/Makefile"

	# Install module config
	mkdir -p "$pkgdir/etc/modprobe.d"
	install -Dm644 "$(readlink -f 00-kernelsu.conf)" "$pkgdir/etc/modprobe.d/"

	# Install loader
	cd "$srcdir/$_pkg/userspace/ksuinit"
	install -Dm755 release/ksuinit "$pkgdir/usr/bin/kernelsu-loader"

	# Install load script (for modloader)
	mkdir -p "$pkgdir/usr/bin"
	install -Dm755 "$(readlink -f "$srcdir/load-kernelsu.in")" "$pkgdir/usr/bin/load-kernelsu"
}
