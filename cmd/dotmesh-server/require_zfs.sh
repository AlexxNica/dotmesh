#!/bin/bash
set -xe

function fetch_zfs {
    KERN=$(uname -r)
    RELEASE=zfs-${KERN}.tar.gz
    cd /bundled-lib
    if [ -d /bundled-lib/lib/modules ]; then
        # Try loading a cached module (which we cached in a docker
        # volume)
        depmod -b /bundled-lib || true
        if modprobe -d /bundled-lib zfs; then
            echo "Successfully loaded cached ZFS for $KERN :)"
            return
        else
            echo "Unable to load cached module, trying to fetch one (maybe you upgraded your kernel)..."
            mv /bundled-lib/lib /bundled-lib/lib.backup-`date +%s`
        fi
    fi
    if ! curl -f -o ${RELEASE} https://get.dotmesh.io/zfs/${RELEASE}; then
        echo "ZFS is not installed on your docker host, and unable to find a kernel module for your kernel: $KERN"
        echo "Please create a new GitHub issue, pasting this error message, and tell me which Linux distribution you are using, at:"
        echo
        echo "    https://github.com/dotmesh-io/dotmesh/issues"
        echo
        echo "Meanwhile, you should still be able to use dotmesh if you install ZFS manually on your host system by following the instructions at http://zfsonlinux.org/ and then re-run the dotmesh installer."
        echo
        echo "Alternatively, Ubuntu 16.04 and later comes with ZFS preinstalled, so using that should Just Work. Kernel modules for Docker for Mac and other Docker distributions are also provided."
        exit 1
    fi
    tar xf ${RELEASE}
    depmod -b /bundled-lib || true
    modprobe -d /bundled-lib zfs
    echo "Successfully loaded downloaded ZFS for $KERN :)"
}

# Put the data file inside /var/lib so that we end up on the big
# partition if we're in a LinuxKit env.
DIR=${USE_POOL_DIR:-/var/lib/dotmesh}
DIR=$(echo $DIR |sed s/\#HOSTNAME\#/$(hostname)/)
FILE=${DIR}/dotmesh_data
POOL=${USE_POOL_NAME:-pool}
POOL=$(echo $POOL |sed s/\#HOSTNAME\#/$(hostname)/)
MOUNTPOINT=${MOUNTPOINT:-$DIR/mnt}
INHERIT_ENVIRONMENT_NAMES=( "FILESYSTEM_METADATA_TIMEOUT" "DOTMESH_UPGRADES_URL" "DOTMESH_UPGRADES_INTERVAL_SECONDS")

echo "=== Using mountpoint $MOUNTPOINT"

# Docker volume where we can cache downloaded, "bundled" zfs
BUNDLED_LIB=/bundled-lib
# Bind-mounted system library where we can attempt to modprobe any
# system-provided zfs modules (e.g. Ubuntu 16.04) or those manually installed
# by user
SYSTEM_LIB=/system-lib

# Set up mounts that are needed
nsenter -t 1 -m -u -n -i sh -c \
    "set -xe
    $EXTRA_HOST_COMMANDS
    if [ $(mount |grep $MOUNTPOINT |wc -l) -eq 0 ]; then
        echo \"Creating and bind-mounting shared $MOUNTPOINT\"
        mkdir -p $MOUNTPOINT && \
        mount --bind $MOUNTPOINT $MOUNTPOINT && \
        mount --make-shared $MOUNTPOINT;
    fi
    mkdir -p /run/docker/plugins
    mkdir -p /var/dotmesh"

if [ ! -e /sys ]; then
    mount -t sysfs sys sys/
fi

if [ ! -d $DIR ]; then
    mkdir -p $DIR
fi

if [ -n "`lsmod|grep zfs`" ]; then
    echo "ZFS already loaded :)"
else
    depmod -b /system-lib || true
    if ! modprobe -d /system-lib zfs; then
        fetch_zfs
    else
        echo "Successfully loaded system ZFS :)"
    fi
fi

if [ ! -e /dev/zfs ]; then
    mknod -m 660 /dev/zfs c $(cat /sys/class/misc/zfs/dev |sed 's/:/ /g')
fi
if ! zpool status $POOL; then
    if [ ! -f $FILE ]; then
        truncate -s 10G $FILE
        echo zpool create -m $MOUNTPOINT $POOL $FILE
        zpool create -m $MOUNTPOINT $POOL $FILE
    else
        zpool import -f -d $DIR $POOL
    fi
fi

# Clear away stale socket if existing
rm -f /run/docker/plugins/dm.sock

# At this point, if we try and run any 'docker' commands and there are any
# dotmesh containers already on the host, we'll deadlock because docker will
# go looking for the dm plugin. So, we need to start up a fake dm plugin which
# just responds immediately with errors to everything. It will create a socket
# file which will hopefully get clobbered by the real thing.

# TODO XXX find out why the '###' commented-out bits below have to be disabled
# when running the Kubernetes tests... maybe the daemonset restarts us multiple
# times? maybe there's some leakage between dind hosts??

###dotmesh-server --temporary-error-plugin &

# Attempt to avoid the race between `temporary-error-plugin` and the real
# dotmesh-server. If `--temporary-error-plugin` loses the race, the
# plugin is broken forever.
###while [ ! -e /run/docker/plugins/dm.sock ]; do
###    echo "Waiting for /run/docker/plugins/dm.sock to exist due to temporary-error-plugin..."
###    sleep 0.1
###done

# Clear away old running server if running
docker rm -f dotmesh-server-inner || true

echo "Starting the 'real' dotmesh-server in a sub-container. Go check 'docker logs dotmesh-server-inner' if you're looking for dotmesh logs."

log_opts=""
rm_opt=""
if [ "$LOG_ADDR" != "" ]; then
    log_opts="--log-driver=syslog --log-opt syslog-address=tcp://$LOG_ADDR:5000"
#    rm_opt="--rm"
fi

# To have its port exposed on Docker for Mac, `docker run` needs -p 6969.  But
# dotmesh-server also wants to discover its routeable IPv4 addresses (on Linux
# anyway; multi-node clusters work only on Linux because we can't discover the
# Mac's IP from a container).  So to work with both we do that in the host
# network namespace (via docker) and pass it in.
YOUR_IPV4_ADDRS="$(docker run --rm -i --net=host $DOTMESH_DOCKER_IMAGE dotmesh-server --guess-ipv4-addresses)"

pki_volume_mount=""
if [ "$PKI_PATH" != "" ]; then
    pki_volume_mount="-v $PKI_PATH:/pki"
fi

net="-p 6969:6969"
link=""
if [ "$DOTMESH_ETCD_ENDPOINT" == "" ]; then
    # If etcd endpoint is overridden, then don't try to link to a local
    # dotmesh-etcd container (etcd probably is being provided externally, e.g.
    # by etcd operator on Kubernetes).
    link="--link dotmesh-etcd:dotmesh-etcd"
fi
if [ "$DOTMESH_ETCD_ENDPOINT" != "" ]; then
    # When running in a pod network, calculate the id of the current container
    # in scope, and pass that as --net=container:<id> so that dotmesh-server
    # itself runs in the same network namespace.
    self_containers=$(docker ps -q --filter="ancestor=$DOTMESH_DOCKER_IMAGE")
    array_containers=( $self_containers )
    num_containers=${#array_containers[@]}
    if [ $num_containers -eq 0 ]; then
        echo "Cannot find id of own container!"
        exit 1
    fi
    if [ $num_containers -gt 1 ]; then
        echo "Found more than one id of own container! $self_containers"
        exit 1
    fi
    net="--net=container:$self_containers"
fi

secret=""
if [[ "$INITIAL_ADMIN_PASSWORD_FILE" != "" && \
      -e $INITIAL_ADMIN_PASSWORD_FILE && \
      "$INITIAL_ADMIN_API_KEY_FILE" != "" && \
      -e $INITIAL_ADMIN_API_KEY_FILE ]]; then
    pw=$(cat $INITIAL_ADMIN_PASSWORD_FILE |tr -d '\n' |base64 -w 0)
    ak=$(cat $INITIAL_ADMIN_API_KEY_FILE |tr -d '\n' |base64 -w 0)
    secret="-e INITIAL_ADMIN_PASSWORD=$pw -e INITIAL_ADMIN_API_KEY=$ak"
    echo "set secret: $secret"
fi

INHERIT_ENVIRONMENT_ARGS=""

for name in "${INHERIT_ENVIRONMENT_NAMES[@]}"
do
    INHERIT_ENVIRONMENT_ARGS="$INHERIT_ENVIRONMENT_ARGS -e $name=$(eval "echo \$$name")"
done

docker run -i $rm_opt --privileged --name=dotmesh-server-inner \
    -v /var/lib/dotmesh:/var/lib/dotmesh \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /run/docker/plugins:/run/docker/plugins \
    -v $MOUNTPOINT:$MOUNTPOINT:rshared \
    -v /var/dotmesh:/var/dotmesh \
    -v /usr:/system-usr/usr \
    -l traefik.port=6969 \
    -l traefik.frontend.rule=Host:cloud.dotmesh.io \
    $net \
    $link \
    -e "PATH=$PATH" \
    -e "LD_LIBRARY_PATH=$LD_LIBRARY_PATH" \
    -e "MOUNT_PREFIX=$MOUNTPOINT" \
    -e "POOL=$POOL" \
    -e "YOUR_IPV4_ADDRS=$YOUR_IPV4_ADDRS" \
    -e "TRACE_ADDR=$TRACE_ADDR" \
    -e "DOTMESH_ETCD_ENDPOINT=$DOTMESH_ETCD_ENDPOINT" $INHERIT_ENVIRONMENT_ARGS \
    $secret \
    $log_opts \
    $pki_volume_mount \
    -v dotmesh-kernel-modules:/bundled-lib \
    $DOTMESH_DOCKER_IMAGE \
    "$@" >/dev/null
