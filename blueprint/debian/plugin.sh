BLUEPRINT_NAME="DEBIAN"

DEFAULT_ARCH="armhf"
DEFAULT_RELEASE="jessie"

# tweaks to upstream template, must be absolute path
# note: this is only used because older versions of LXC do not support
# cross-debootstrapping in the debian template
LXC_TEMPLATE_OVERRIDE="$(pwd)/lxc/templates/debian.sh"

# script to run inside the chroot
CHROOT_SCRIPT="chroot-configure.sh"

pecho () {
    echo "[ $BLUEPRINT_NAME ] $1"
}

print_help () {
    cat <<EOF
Blueprint for building Debian images.

Debian-specific options:

    -r, --release   Debian release to use as the image base.
                    Defaults to jessie.

    -a, --arch      Architecture of generated image.
                    Defaults to armhf.
EOF
}

bootstrap () {
    local name="$1"
    local rootfs="$2"
    local release="$3"
    local arch="$4"

    pecho "bootstrapping rootfs..."
    lxc-create -t "$LXC_TEMPLATE_OVERRIDE" -n "$name" --dir "$rootfs" -- \
        -a "$arch" -r "$release"
}

configure () {
    local name="$1"
    local rootfs="$2"

    # make sure we've got a working nameserver
    # (on a fresh rootfs this may not be set correctly)
    echo "nameserver 8.8.8.8" > "${rootfs}/etc/resolv.conf"

    # make sure hostname is in /etc/hosts to avoid hostname resolution errors
    cat > "${rootfs}/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $(cat "${rootfs}/etc/hostname")
::1     localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

    # make sure we have a dynamic mirror for installing packages
    cat > "${rootfs}/etc/apt/sources.list" <<EOF
deb http://httpredir.debian.org/debian jessie main
EOF

    # disable any default.target
    # (LXC template symlinks to multi-user.target by default)
    SYSTEMD_DEFAULT_TARGET="${rootfs}/etc/systemd/system/default.target"
    if [ -e "$SYSTEMD_DEFAULT_TARGET" ] ; then
        rm "$SYSTEMD_DEFAULT_TARGET"
    fi

    export DEBIAN_FRONTEND=noninteractive
    export DEBCONF_NONINTERACTIVE_SEEN=true
    export LC_ALL=C
    export LANGUAGE=C
    export LANG=C

    pecho "building maru debpkg..."
    make
    cp maru*.deb "${rootfs}/tmp"

    pecho "configuring rootfs..."
    cp "$CHROOT_SCRIPT" "${rootfs}/tmp"
    chroot "$rootfs" bash -c "cd /tmp && ./${CHROOT_SCRIPT}"
}

blueprint_build () {
    local name="$1"; shift
    local rootfs="$1"; shift

    #
    # parse blueprint-specific options
    #

    local release="$DEFAULT_RELEASE"
    local arch="$DEFAULT_ARCH"

    local ARGS="$(getopt -o r:a:h --long release:,arch:,help -n "$BLUEPRINT_NAME" -- "$@")"
    if [ $? != 0 ] ; then
        pecho >&2 "Error parsing options!"
        exit 2
    fi

    eval set -- "$ARGS"

    while true; do
        case "$1" in
            -r|--release) release="$2"; shift 2 ;;
            -a|--arch) arch="$2"; shift 2 ;;
            -h|--help) print_help; exit 0 ;;
            --) shift; break ;;
        esac
    done

    #
    # build!
    #

    bootstrap "$name" "$rootfs" "$release" "$arch"
    configure "$name" "$rootfs"
}

blueprint_cleanup () {
    local name="$1"
    local rootfs="$2"

    # clean up any debpkg artifacts
    make clean >/dev/null

    # destroy persistent lxc object
    if [ -d "/var/lib/lxc/${name}" ] ; then
        lxc-destroy -n "$name"
    fi
}

pecho "loading..."