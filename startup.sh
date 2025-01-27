#!/bin/bash

set -e

[ -n "$DEBUG" ] && set -x

# Create the kvm node (required --privileged)
if [ ! -e /dev/kvm ]; then
  set +e
  mknod /dev/kvm c 10 $(grep '\<kvm\>' /proc/misc | cut -f 1 -d' ')
  set -e
fi

# If we were given arguments, override the default configuration
if [ $# -gt 0 ]; then
  exec /usr/bin/kvm $@
  exit $?
fi

# mountpoint check
if [ ! -d /data ]; then
  if [ "${ISO:0:1}" != "/" ] || [ -z "$IMAGE" ]; then
    echo "/data not mounted: using -v to mount it"
    exit 1
  fi
fi

if [ -n "$CPU" ]; then
  echo "[cpu]"
  FLAGS_CPU="${CPU}"
  echo "parameter: ${FLAGS_CPU}"
else
  FLAGS_CPU="qemu64"
fi

if [ -n "$ISO" ]; then
  echo "[iso]"
  if [ "${ISO:0:1}" != "/" ] && [ "${ISO:0:4}" != "rbd:" ]; then
    basename=$(basename $ISO)
    if [ ! -f "/data/${basename}" ] || [ "$ISO_DOWNLOAD" != "0" ]; then
      wget -O- "$ISO" > /data/${basename}
    fi
    ISO=/data/${basename}
  fi
  FLAGS_ISO="-drive file=${ISO},media=cdrom,index=2"
  if [ "${ISO:0:4}" != "rbd:" ] && [ ! -f "$ISO" ]; then
    echo "ISO file not found: $ISO"
    exit 1
  fi
  echo "parameter: ${FLAGS_ISO}"
fi

if [ -n "$ISO2" ]; then
  echo "[iso2]"
  if [ "${ISO2:0:1}" != "/" ] && [ "${ISO2:0:4}" != "rbd:" ]; then
    basename=$(basename $ISO2)
    if [ ! -f "/data/${basename}" ] || [ "$ISO_DOWNLOAD" != "0" ]; then
      wget -O- "$ISO2" > /data/${basename}
    fi
    ISO2=/data/${basename}
  fi
  FLAGS_ISO2="-drive file=${ISO2},media=cdrom,index=3"
  if [ "${ISO2:0:4}" != "rbd:" ] && [ ! -f "$ISO2" ]; then
    echo "ISO2 file not found: $ISO2"
    exit 1
  fi
  echo "parameter: ${FLAGS_ISO2}"
fi

echo "[disk image]"
if [ "$IMAGE_CREATE" == "1" ]; then
  if [ -e "${IMAGE}" ]; then
    echo "${IMAGE} already exist"
    exit 1
  fi
  qemu-img create -f ${IMAGE_FORMAT} ${IMAGE} ${IMAGE_SIZE}
elif [ "${IMAGE:0:4}" != "rbd:" ] && [ ! -e "$IMAGE" ]; then
  echo "IMAGE not found: ${IMAGE}"; exit 1;
fi

if [ "$DISK_DEVICE" == "scsi" ]; then
  FLAGS_DISK_IMAGE="-device virtio-scsi-pci,id=scsi -device scsi-hd,drive=hd -drive file=${IMAGE},if=none,id=hd,cache=${IMAGE_CACHE},format=${IMAGE_FORMAT},discard=${IMAGE_DISCARD}"
else
  FLAGS_DISK_IMAGE="-drive file=${IMAGE},if=${DISK_DEVICE},cache=${IMAGE_CACHE},format=${IMAGE_FORMAT},index=1"
fi

if [ -n "$DISKS" ]; then
  INDEX=1
  for DISK in $DISKS; do
    (( INDEX++ ))
      FLAGS_DISK_IMAGE="$FLAGS_DISK_IMAGE -device vfio-pci,host=$DISK"
  done
fi

echo "parameter: ${FLAGS_DISK_IMAGE}"

if [ -n "$FLOPPY" ]; then
  echo "[floppy image]"
  FLAGS_FLOPPY_IMAGE="-fda ${FLOPPY}"
  echo "parameter: ${FLAGS_FLOPPY_IMAGE}"
fi

echo "[network]"
if [ "$NETWORK" == "bridge" ]; then
  NETWORK_BRIDGE="${NETWORK_BRIDGE:-docker0}"
  if [ -z "$NETWORK_MAC" ]; then
    NETWORK_MAC=$(od -An -N6 -tx1 /dev/urandom | sed -e 's/^  *//' -e 's/  */:/g' -e 's/:$//' -e 's/^\(.\)[13579bdf]/\10/')
  fi
  mkdir -p /etc/qemu
  echo allow $NETWORK_BRIDGE > /etc/qemu/bridge.conf
  FLAGS_NETWORK="-netdev bridge,br=${NETWORK_BRIDGE},id=net0 -device virtio-net-pci,netdev=net0,mac=${NETWORK_MAC},host_mtu=9000"
elif [ "$NETWORK" == "tap" ]; then
  IFACE=eth0
  TAP_IFACE=tap0
  IP=`ip addr show dev $IFACE | grep "inet " | awk '{print $2}' | cut -f1 -d/`
  NAMESERVER=`grep nameserver /etc/resolv.conf | cut -f2 -d ' '`
  NAMESERVERS=`echo ${NAMESERVER[*]} | sed "s/ /,/g"`
  NETWORK_IP="${NETWORK_IP:-$(echo 172.$((RANDOM%(31-16+1)+16)).$((RANDOM%256)).$((RANDOM%(254-2+1)+2)))}"
  NETWORK_SUB=`echo $NETWORK_IP | cut -f1,2,3 -d\.`
  NETWORK_GW="${NETWORK_GW:-$(echo ${NETWORK_SUB}.1)}"
  tunctl -t $TAP_IFACE
  dnsmasq --user=root \
    --dhcp-range=$NETWORK_IP,$NETWORK_IP \
    --dhcp-option=option:router,$NETWORK_GW \
    --dhcp-option=option:dns-server,$NAMESERVERS
  ifconfig $TAP_IFACE $NETWORK_GW up
  iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
  iptables -I FORWARD 1 -i $TAP_IFACE -j ACCEPT
  iptables -I FORWARD 1 -o $TAP_IFACE -m state --state RELATED,ESTABLISHED -j ACCEPT
  if [ "$VNC" == "tcp" ]; then
    iptables -t nat -A PREROUTING -p tcp -d $IP ! --dport `expr 5900 + $VNC_ID` -j DNAT --to-destination $NETWORK_IP
    iptables -t nat -A PREROUTING -p udp -d $IP -j DNAT --to-destination $NETWORK_IP
    iptables -t nat -A PREROUTING -p icmp -d $IP -j DNAT --to-destination $NETWORK_IP
  else
    iptables -t nat -A PREROUTING -d $IP -j DNAT --to-destination $NETWORK_IP
  fi
  FLAGS_NETWORK="-netdev tap,id=net0,ifname=tap0,vhost=on,script=no,downscript=no -device virtio-net-pci,netdev=net0"
elif [ "$NETWORK" == "macvtap" ]; then
  NETWORK_IF="${NETWORK_IF:-eth0}"
  NETWORK_FDS=${NETWORK_FDS:-4}
  NETWORK_MTU=${NETWORK_MTU:-9000}
  NETWORK_QUEUE=${NETWORK_QUEUE:-1024}
  NETWORK_BRIDGE="${NETWORK_BRIDGE:-macvtap0}"
  NETWORK_MAC=$(cat /sys/class/net/$NETWORK_BRIDGE/address)
  NETWORK_INDEX=$(cat /sys/class/net/$NETWORK_BRIDGE/ifindex)
  if (( NETWORK_FDS > 10 )); then
    NETWORK_FDS=10
  fi
  NETWORK_VECTORS=$(( 2 * NETWORK_FDS + 2 ))
  NETWORK_FD=10
  FD=$NETWORK_FD
  FDS=""
  while (( FD < NETWORK_FD + NETWORK_FDS )); do
	  eval "exec $FD<>/dev/tap$NETWORK_INDEX"
    FDS="${FDS:+$FDS:}${FD}"
    (( FD++ ))
  done
  FLAGS_NETWORK="-netdev tap,vhost=on,fds=$FDS,id=net0 -device virtio-net-pci,netdev=net0,mac=$NETWORK_MAC,mq=on,vectors=$NETWORK_VECTORS,host_mtu=$NETWORK_MTU,rx_queue_size=$NETWORK_QUEUE,tx_queue_size=$NETWORK_QUEUE"
  if [[ ! -z "$NETWORK_IF2" ]]; then
    NETWORK_BRIDGE2="${NETWORK_BRIDGE2:-macvtap1}"
    NETWORK_MAC2=$(cat /sys/class/net/$NETWORK_BRIDGE2/address)
    NETWORK_INDEX=$(cat /sys/class/net/$NETWORK_BRIDGE2/ifindex)
    NETWORK_FD=20
    FD=$NETWORK_FD
    FDS=""
    while (( FD < NETWORK_FD + NETWORK_FDS )); do
      eval "exec $FD<>/dev/tap$NETWORK_INDEX"
      FDS="${FDS:+$FDS:}${FD}"
      (( FD++ ))
    done
    FLAGS_NETWORK="$FLAGS_NETWORK -netdev tap,vhost=on,fds=$FDS,id=net1 -device virtio-net-pci,netdev=net1,mac=$NETWORK_MAC2,mq=on,vectors=$NETWORK_VECTORS,host_mtu=$NETWORK_MTU,rx_queue_size=$NETWORK_QUEUE,tx_queue_size=$NETWORK_QUEUE"
  fi
elif [ "$NETWORK" == "none" ]; then
	NETWORK_BRIDGE="${NETWORK_BRIDGE:-docker0}"
	mkdir -p /etc/qemu
	echo allow $NETWORK_BRIDGE > /etc/qemu/bridge.conf
	FLAGS_NETWORK="-netdev bridge,br=${NETWORK_BRIDGE},id=net0 -device vmxnet3,netdev=net0"
else
  NETWORK="user"
  REDIR=""
  if [ ! -z "$TCP_PORTS" ]; then
    OIFS=$IFS
    IFS=","
    for port in $TCP_PORTS; do
      REDIR+="-redir tcp:${port}::${port} "
    done
    IFS=$OIFS
  fi
  
  if [ ! -z "$UDP_PORTS" ]; then
    OIFS=$IFS
    IFS=","
    for port in $UDP_PORTS; do
      REDIR+="-redir udp:${port}::${port} "
    done
    IFS=$OIFS
  fi
  FLAGS_NETWORK="-net nic,model=virtio -net user ${REDIR}"
fi
echo "Using ${NETWORK}"
echo "parameter: ${FLAGS_NETWORK}"

echo "[Remote Access]"
if [ "$VNC" == "tcp" ]; then
  FLAGS_REMOTE_ACCESS="-vnc ${VNC_IP}:${VNC_ID}"
elif [ "$VNC" == "reverse" ]; then
  FLAGS_REMOTE_ACCESS="-vnc ${VNC_IP}:${VNC_PORT},reverse"
elif [ "$VNC" == "sock" ]; then
  FLAGS_REMOTE_ACCESS="-vnc unix:${VNC_SOCK}"
else
  FLAGS_REMOTE_ACCESS="-nographic"
fi
echo "parameter: ${FLAGS_REMOTE_ACCESS}"

if [ -n "$BOOT" ]; then
  echo "[boot]"
  FLAGS_BOOT="-boot ${BOOT}"
  echo "parameter: ${FLAGS_BOOT}"
fi

if [ -n "$KEYBOARD" ]; then
  echo "[keyboard]"
  FLAGS_KEYBOARD="-k ${KEYBOARD}"
  echo "parameter: ${FLAGS_KEYBOARD}"
fi

set -x
/usr/bin/qemu-system-x86_64 -enable-kvm  ${FLAGS_REMOTE_ACCESS} \
 -uuid ${UUID} \
  -k en-us -m ${RAM} -smp ${SMP} -cpu ${FLAGS_CPU} -no-shutdown \
  -name ${HOSTNAME} \
  ${FLAGS_DISK_IMAGE} \
  ${FLAGS_FLOPPY_IMAGE} \
  ${FLAGS_ISO} \
  ${FLAGS_ISO2} \
  ${FLAGS_NETWORK} \
  ${FLAGS_KEYBOARD} \
  ${FLAGS_BOOT}
