#!/bin/bash

domprefix=${DOMPREFIX:=r64vm}
domsuffixes=${DOMSUFFIXES:="1 2 3 4 5 6"}
poolpath=${POOLPATH:=/home/vms}
        #/var/lib/libvirt/images
default_ip_prefix=${DEFAULT_IP_PREFIX:=192.168.7}

if [ "x$VMSET" = "x" ]; then
  vmset=$(echo $domsuffixes | perl -p -e "s/(\S+)/$domprefix\$1/g")
else
  vmset=$VMSET
fi

if [ "x$V_CPUS" = "x" ]; then
  vcpus=3
else
  vcpus=$V_CPUS
fi

if [ "x$INITIMAGE" = "x" ]; then
  initimage=$(echo $vmset | perl -p -e 's/^(\S+)\s?.*$/$1/')
else
  initimage=$INITIMAGE
fi

# todo
# * move /mnt/vm-share creation to new funciton, host_prep
# * write and use exit_if_not_running( $domname)
# *
# networking
# * maybe throw in a VMNETSET
# * guest_update_network <vmname> <interface #> <network name>
#   - updates existing network interface to point to <network name>
# * guest_del_network <vmname> <interface #>
# * guest_del_all_networks <vmname>
# * guest_add_network <vmname> <network name>
# * change the names of default created networks
#     3 nat with no dhcp named nodhcpN
#     3 closed named closedN
os=unsupported
grep -Eqs 'Red Hat Enterprise Linux Server release 6|CentOS release 6' /etc/redhat-release && os=el6 osfamily=el
grep -Eqs 'Red Hat Enterprise Linux Server release 7|CentOS Linux release 7' /etc/redhat-release && os=el7 osfamily=el
grep -qs -P 'Fedora release 20' /etc/fedora-release && os=f20 osfamily=fedora
if [ "$os" = "unsupported" ]; then
  echo 'vftool.bash has not been tested out of enterprise linux 6, 7 or Fedora 20'
  echo 'Patches welcome :-)'
  exit 1
fi

usage(){
    echo "Usage: See the README.md :-)"
}

fatal(){
    echo "VF FATAL: $1"
    exit 1
}
warn(){
    echo "VF WARN: $1"
}

#thanks to tripleo-ci/toci_functions.sh
wait_for(){
  LOOPS=$1
  SLEEPTIME=$2
  shift ; shift
  i=0
  while [ $i -lt $LOOPS ] ; do
    i=$((i + 1))
   eval "$@" && return 0 || true
   sleep $SLEEPTIME
  done
  return 1
}

function install_pkgs {
  depends=$1
  install_list=""
  for dep in $depends; do
    if ! `rpm -q --quiet --nodigest $dep`; then
      install_list="$install_list $dep"
    fi
  done

  # Install the needed packages
  if [ "x$install_list" != "x" ]; then
    if [ `whoami` = "root" ]; then
      yum install -y $install_list
    else
      sudo yum install -y $install_list
    fi
  fi

  # Verify the dependencies did install
  fail_list=""
  for dep in $depends; do
    if ! `rpm -q --quiet --nodigest $dep`; then
      fail_list="$fail_list $dep"
    fi
  done

  # If anything failed verification, we tell the user and exit
  if [ "x$fail_list" != "x" ]; then
    fatal "ABORTING: FAILED TO INSTALL $fail_list"
  fi
}

destroy_if_running() {
   domname=$1
   check='$(sudo virsh domstate '$domname' | grep -q "shut off")'
   if ! eval $check; then
     echo 'trying graceful shutdown for ' $domname
     ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" root@$domname "sync; shutdown -h now"
     if [ $? -eq 255 ]; then
       echo "unable to ssh to host"
     else
       wait_for 10 1 $check
       if [ $? -eq 0 ]; then
         return
       fi
     fi
     echo "so much for ssh, calling virsh shutdown $domname"
     sudo virsh shutdown $domname
     wait_for 40 1 $check
     if [ $? -ne 0 ]; then
       echo "so much for graceful virsh shutdown, calling virsh destroy $domname"
       sudo virsh destroy $domname
     fi
   fi
}

wait_for_port() {
  port=$1

  the_cmd="true"
  for vm in $VMSET; do
    # sadly nc -z not available on rhel7
    #the_cmd="$the_cmd && nc -w1 -z $vm $port"
    #... so use this command that works on both el6 and el7
    the_cmd="$the_cmd && \$(nmap -Pn -p$port $vm | grep -qs \"$port/.*open\" 2>/dev/null)"
  done
  eval $the_cmd >/dev/null 2>&1
  exit_status=$?
  while [[ $exit_status -ne 0 ]] ; do
    echo -n .
    sleep 6
    eval $the_cmd > /dev/null
    exit_status=$?
  done
}

wait_for_status() {
  # probably 'running' or 'shut off'
  status=$1

  the_cmd="true"
  for vm in $VMSET; do
    the_cmd="$the_cmd && \$(virsh list --all | grep -qPs \"\b$vm\b.*$status\" 2>/dev/null)"
  done
  eval $the_cmd >/dev/null 2>&1
  exit_status=$?
  while [[ $exit_status -ne 0 ]] ; do
    echo -n .
    sleep 6
    eval $the_cmd > /dev/null
    exit_status=$?
  done
}

start_if_not_running() {
   domname=$1
   if ! $(sudo virsh domstate $domname | grep -q 'running'); then
     sudo virsh start $domname
   fi
}

el6_host_depends(){
  install_pkgs "nfs-utils libguestfs-tools libvirt virt-manager git
  tigervnc-server tigervnc-server-module tigervnc xorg-x11-twm
  xorg-x11-server-utils ntp emacs-nox python-virtinst virt-viewer nc
  nmap"
}

el7_host_depends(){
  install_pkgs "nfs-utils libguestfs-tools libvirt virt-manager git
  tigervnc-server tigervnc-server-module tigervnc ntp emacs-nox
  virt-viewer nmap-ncat nmap virt-install wget"
}

host_depends(){
  if [ "$os" = "el6" ]; then
    el6_host_depends
  else
    el7_host_depends
  fi
}

el6_host_permissive(){
  sudo /sbin/iptables --flush
  sudo sysctl -w net.ipv4.ip_forward=1
  sudo sed -i 's/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/g' /etc/sysctl.conf
  sudo setenforce 0
}

el7_host_permissive(){
  sudo /sbin/iptables --flush
  sudo sysctl -w net.ipv4.ip_forward=1
  # TODO append to /usr/lib/sysctl.d/00-system.conf only if not present
  echo 'net.ipv4.ip_forward = 1' >> /usr/lib/sysctl.d/00-system.conf
  sudo setenforce 0
  firewall-cmd --add-service=nfs
}

host_permissive(){
  if [ "$os" = "el6" ]; then
    el6_host_permissive
  else
    el7_host_permissive
  fi
}

libvirt_prep(){
  sudo /sbin/service libvirtd start

  # create default pool
  sudo mkdir -p $poolpath
  sudo virsh pool-destroy default
  sudo virsh pool-define-as --name default --type dir --target $poolpath
  sudo virsh pool-autostart default
  sudo virsh pool-build default
  #sudo virsh pool-dumpxml default > /tmp/pool.xml
  #sudo sed -i "s#/var/lib/libvirt/images#$poolpath#" /tmp/pool.xml
  #sudo virsh pool-define /tmp/pool.xml
  # sudo virsh pool-refresh default
  sudo virsh pool-start default

  # this shouldn't be necessary, but i've seen issues on rhel6...
  # sudo virsh net-define /usr/share/libvirt/networks/default.xml
  # sudo virsh net-start default
  sudo /sbin/service libvirtd restart
}

default_network_ip() {
  #sudo virsh net-dumpxml default > /tmp/default-network.xml
  cp /usr/share/libvirt/networks/default.xml /tmp/default-network.xml
  sudo virsh net-destroy default
  sudo virsh net-undefine default
  sed -i "s#192.168.122#$default_ip_prefix#g" /tmp/default-network.xml
  sudo virsh net-define /tmp/default-network.xml
  sudo virsh net-autostart default
  sudo /sbin/service libvirtd start
  sudo virsh net-start default
}

create_foreman_networks() {
  # define some networks
for i in 1 2 3; do
  cat >/tmp/openstackvms1_$i.xml <<EOF
<network>
  <name>openstackvms1_$i</name>
  <bridge name="virbr1$i" stp="off" delay="0" />
</network>
EOF
  cat >/tmp/openstackvms2_$i.xml <<EOF
<network>
  <name>openstackvms2_$i</name>
  <bridge name="virbr2$i" stp="off" delay="0" />
</network>
EOF

  cat >/tmp/foreman$i.xml <<EOF
<network>
  <name>foreman$i</name>
  <forward mode='nat'/>
  <bridge name="virbr3$i" stp="on" delay="0" />
  <ip address='192.168.10$i.1' netmask='255.255.255.0'></ip>
</network>
EOF

  sudo virsh net-define /tmp/openstackvms1_$i.xml
  sudo virsh net-start openstackvms1_$i
  sudo virsh net-autostart openstackvms1_$i
  sudo virsh net-define /tmp/openstackvms2_$i.xml
  sudo virsh net-start openstackvms2_$i
  sudo virsh net-autostart openstackvms2_$i
  sudo virsh net-define /tmp/foreman$i.xml
  sudo virsh net-start foreman$i
  sudo virsh net-autostart foreman$i
done
}

vm_auth_keys(){
  # put current user and root ssh pub keys in /mnt/vm-share/authorized_keys
  if [ ! -f ~/.ssh/id_rsa.pub ]; then ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa ; fi
  sudo sh -c "if [ ! -f /root/.ssh/id_rsa.pub ]; then ssh-keygen -t rsa -N '' -f /root/.ssh/id_rsa ; fi"

  sudo mkdir -p /mnt/vm-share
  sudo chmod ugo+rwx /mnt/vm-share;
  if ! `grep -q vm-share /etc/exports`; then
    sudo sh -c "echo '/mnt/vm-share 192.168.0.0/16(rw,sync,no_root_squash)' >> /etc/exports"
    sudo /sbin/service nfs restart
  fi

  sudo cp -f /root/.ssh/id_rsa.pub /mnt/vm-share/authorized_keys
  sudo chown `whoami` /mnt/vm-share/authorized_keys
  cat ~/.ssh/id_rsa.pub >> /mnt/vm-share/authorized_keys
  sudo chmod ugo+r /mnt/vm-share/authorized_keys
}

kick_first_vm(){

[[ -z $INSTALLURL ]] && fatal "INSTALLURL Is not defined"

domname=$initimage
image=$poolpath/$domname.qcow2
test -f $image && fatal "image $image already exists"
sudo /usr/bin/qemu-img create -f qcow2 -o preallocation=metadata $image 9G

cat >/tmp/$domname.ks <<EOD
%packages
@base
@core
nfs-utils
emacs-nox
emacs-common
screen
nc
nmap
%end

reboot
firewall --disabled
install
url --url="$INSTALLURL"
rootpw --plaintext weakpw
auth  --useshadow  --passalgo=sha512
graphical
keyboard us
lang en_US
selinux --permissive
skipx
logging --level=info
timezone  America/Los_Angeles
bootloader --location=mbr --append="console=tty0 console=ttyS0,115200 rd_NO_PLYMOUTH"
clearpart --all
part /boot --fstype ext4 --size=400
part swap --size=100
part pv.01 --size=8000
volgroup lv_admin --pesize=32768 pv.01
logvol / --fstype ext4 --name=lv_root --vgname=lv_admin --size=7000 --grow
zerombr
network --bootproto=dhcp --noipv6 --device=eth0

%post

mkdir -p /mnt/vm-share
mount $default_ip_prefix.1:/mnt/vm-share /mnt/vm-share
ln -s /mnt/vm-share /vs
if [ ! -d /root/.ssh ]; then
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
fi
if [ -f /mnt/vm-share/authorized_keys ]; then
  cp /mnt/vm-share/authorized_keys /root/.ssh/authorized_keys
  chmod 0600 /root/.ssh/authorized_keys
fi
# TODO script register to RHN

%end

EOD

sudo virt-install --connect=qemu:///system \
    --network network:default \
    --network network:foreman1 \
    --network network:openstackvms1_1 \
    --network network:openstackvms1_2 \
    --network network:foreman2 \
    --network network:openstackvms2_1 \
    --network network:openstackvms2_2 \
    --initrd-inject=/tmp/$domname.ks \
    --extra-args="ks=file:/$domname.ks ksdevice=eth0 noipv6 ip=dhcp keymap=us lang=en_US console=tty0 console=ttyS0,115200" \
    --name=$domname \
    --location=$INSTALLURL \
    --disk $image,format=qcow2 \
    --ram 7000 \
    --vcpus $vcpus \
    --cpu host \
    --hvm \
    --os-variant rhel6 \
    --vnc \
    --noautoconsole

echo "view the install (if you want) with:"
echo "   virt-viewer --connect qemu+ssh://root@`hostname`/system $domname"
}

el7_kick_first_vm(){

[[ -z $INSTALLURL ]] && fatal "INSTALLURL Is not defined"

domname=$initimage
image=$poolpath/$domname.qcow2
test -f $image && fatal "image $image already exists"
sudo /usr/bin/qemu-img create -f qcow2 -o preallocation=metadata $image 9G

cat >/tmp/$domname.ks <<EOD
%packages
@core
kernel
nfs-utils
emacs-nox
emacs-common
screen
nmap
nmap-ncat
tmux
net-tools
ntp
ntpdate
autogen-libopts
wget
rsync
%end

reboot
firewall --disabled
install
url --url="$INSTALLURL"
rootpw --plaintext weakpw
auth  --useshadow  --passalgo=sha512
graphical
keyboard us
lang en_US
selinux --permissive
skipx
logging --level=info
timezone  America/Los_Angeles
bootloader --location=mbr --driveorder=vda,sda,hda --append="console=tty0 console=ttyS0,115200 rd_NO_PLYMOUTH"
clearpart --all
part /boot --fstype ext4 --size=400
part swap --size=100
part pv.01 --size=8000
volgroup lv_admin --pesize=32768 pv.01
logvol / --fstype ext4 --name=lv_root --vgname=lv_admin --size=7000 --grow
zerombr
network --bootproto=dhcp --device=eth0

%post

mkdir -p /mnt/vm-share
mount $default_ip_prefix.1:/mnt/vm-share /mnt/vm-share
ln -s /mnt/vm-share /vs
if [ ! -d /root/.ssh ]; then
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
fi
if [ -f /mnt/vm-share/authorized_keys ]; then
  cp /mnt/vm-share/authorized_keys /root/.ssh/authorized_keys
  chmod 0600 /root/.ssh/authorized_keys
fi
# TODO script register to RHN

%end

EOD

sudo virt-install --connect=qemu:///system \
    --network network:default \
    --network network:foreman1 \
    --network network:openstackvms1_1 \
    --network network:openstackvms1_2 \
    --network network:foreman2 \
    --network network:openstackvms2_1 \
    --network network:openstackvms2_2 \
    --initrd-inject=/tmp/$domname.ks \
    --extra-args="ks=file:/$domname.ks ks.device=eth0 console=tty0 console=ttyS0,115200 repo=$INSTALLURL" \
    --name=$domname \
    --location=$INSTALLURL \
    --disk $image,format=qcow2,bus=virtio \
    --ram 7000 \
    --vcpus 3 \
    --cpu host \
    --hvm \
    --os-type linux \
    --os-variant rhel7 \
    --graphics vnc \
    --noautoconsole

echo "view the install (if you want) with:"
echo "   virt-viewer --connect qemu+ssh://root@`hostname`/system $domname"
}


# create images to test foreman provisioning
# first image has 2 nic's: default + foreman1
# 2nd and 3rd images have 3 nic's: foreman1 + openstackvms1_1 + openstackvms1_2
#create_imagesforprov() {
#
#}

create_images() {
  ATTEMPTS=60
  FAILED=0
  while $(sudo virsh list | grep -qP "\b$initimage\b") ; do
    FAILED=$(expr $FAILED + 1)
    echo "waiting for $initimage to stop. $FAILED"
    if [ $FAILED -ge $ATTEMPTS ]; then
      fatal "create_images() $initimage must not be stopped to continue.  perhaps it is not done being installed yet."
    fi
    sleep 10
  done

  for domname in $vmset; do
    sudo virt-clone -o $initimage -n $domname -f $poolpath/$domname.qcow2 && \
    sudo virt-sysprep -d $domname
  done
}

clone_image() {
  src_domname=$1
  dest_domname=$2

  if $(sudo virsh list | grep -qP "\b$src_domname\b") ; then
    fatal "clone_image() $src_domname must not be stopped to clone it."
  fi
  if $(sudo virsh list | grep -qP "\b$dest_domname\b") ; then
    fatal "clone_image() $dest_domname must not be stopped to clone it."
  fi

  sudo virt-clone -o $src_domname -n $dest_domname -f $poolpath/$dest_domname.qcow2 && \
  sudo virt-sysprep -d $dest_domname

  domname=$dest_domname
  # hostname-specific updates
  mntpnt=/mnt/$domname

  sudo mkdir -p $mntpnt
  # when the host boots up, write a "we're here" file to /mnt/vm-share
  sudo guestmount -a $poolpath/$domname.qcow2 -i $mntpnt
  sudo sed -i "s/$src_domname/$domname/g" $mntpnt/etc/rc.d/rc.local
  sudo sed -i "s/$src_domname/$domname/g" $mntpnt/etc/sysconfig/network
  sudo umount $mntpnt

  echo 'Cloned!'
  echo 'It would be a good idea to run:'
  echo "sudo virsh start $dest_domname && sleep 120 && VMSET=$dest_domname vftool.bash populate_etc_hosts && VMSET=$dest_domname vftool.bash populate_default_dns"
}

prep_images() {
  for domname in $vmset; do
    if sudo virsh list | grep -qP "\b$domname\b"; then
      fatal "prep_images()  $domname must not be stopped to continue"
    fi
    mntpnt=/mnt/$domname

    sudo mkdir -p $mntpnt
    # when the host boots up, write a "we're here" file to /mnt/vm-share
    sudo guestmount -a $poolpath/$domname.qcow2 -i $mntpnt
    is_el6=$(grep -q 'release 6' $mntpnt/etc/redhat-release && echo true || echo false)
    echo '#!/bin/bash
mount /mnt/vm-share
i=0
while [ $i -lt 20 ] ; do
  i=$((i + 1))
  eval "mount | grep -q vm-share" && i=20 || sleep 3
done
' > /tmp/$domname.rc.local
    echo 'echo `ifconfig eth0 | grep "inet " | perl -p -e "s/.*inet .*?(\d\S+\d).*\\\$/\\\$1/"`' " $domname.example.com $domname> /mnt/vm-share/$domname.hello" >> /tmp/$domname.rc.local
    echo '/sbin/service ntpd stop; ntpdate clock.redhat.com; /sbin/service ntpd start;' >> /tmp/$domname.rc.local
    sudo cp /tmp/$domname.rc.local $mntpnt/etc/rc.d/rc.local
    sudo chmod ugo+x $mntpnt/etc/rc.d/rc.local
    # sudo sh -c "echo 'SELINUX=disabled' > $mntpnt/etc/selinux/config"
    sudo sh -c "echo 'NETWORKING=yes
HOSTNAME=$domname.example.com' > $mntpnt/etc/sysconfig/network"
    # this is really just a rhel7 thing (won't hurt rhel7 though)
    sudo sh -c "echo $domname.example.com > $mntpnt/etc/hostname"
    # always mount /mnt/vm-share
    if ! sudo cat $mntpnt/etc/fstab | grep -q vm-share; then
      sudo sh -c "echo '$default_ip_prefix.1:/mnt/vm-share /mnt/vm-share nfs lookupcache=none,v3,rw,hard,intr,rsize=32768,wsize=32768,sync 0 0' >> $mntpnt/etc/fstab"
    fi
    if [ "$is_el6" = "true" ]; then
      # noapic, no ipv6
      if ! sudo cat $mntpnt/boot/grub/grub.conf | grep -q 'kernel.*ipv6.disable'; then
        sudo sh -c "perl -p -i -e 's/^(\s*kernel\s+.*)\$/\$1 noapic ipv6.disable=1/' $mntpnt/boot/grub/grub.conf"
      fi
    #else
      #if ! sudo cat $mntpnt/boot/grub2/grub.cfg | grep -q 'crashkernel=auto.*ipv6.disable'; then
      #  sudo sh -c "perl -p -i -e 's/^(.*crashkernel=auto\s+.*)\$/\$1 noapic ipv6.disable=1/' $mntpnt/boot/grub2/grub.cfg"
      #fi
    fi
    # ssh keys
    sudo sh -c "mkdir -p $mntpnt/root/.ssh; chmod 700 $mntpnt/root/.ssh; cp /mnt/vm-share/authorized_keys $mntpnt/root/.ssh/authorized_keys; chmod 0600 $mntpnt/root/.ssh/authorized_keys"
    sleep 2
    sudo umount $mntpnt
  done
}

first_snaps() {
  # take initial snapshotso
  for domname in $vmset; do
    if sudo virsh list | grep -qP "\b$domname\b"; then
      fatal "first_snaps()  $domname must not be stopped to continue"
    fi
    sudo qemu-img snapshot -c initial_snap $poolpath/$domname.qcow2
  done
}

start_guests() {
  if [ $# -ne 0 ]; then
    vmset="$@"
  fi
  for domname in $vmset; do
    start_if_not_running $domname &
  done
  wait
  VMSET=$vmset wait_for_status running

}

resize_image() {
  # warning: this doesn't always work, sometimes see:
  #   Fatal error: exception Guestfs.Error("resize2fs: e2fsck 1.41.12 (17-May-2010)")
  if [ $# -ne 2 ]; then
    echo "usage: vftool.bash resize_image your_vm_name new_disk_size"
    echo " e.g.: vftool.bash resize_image myvmname 200G"
    echo "note that new image will still be sparse."
    exit 1
  fi

  domname=$1
  newdisksize=$2
  partition=${RESIZE_PARTITION:=/dev/sda2}
  lv=${RESIZE_LV:=/dev/lv_admin/lv_root}

  if sudo virsh list | grep -qP "\\s$domname\\s"; then
     echo "$domname is running.  Shut it down before trying something so drastic!"
     exit 1
  fi

  imgname=$poolpath/$domname.qcow2
  imgnameold=$poolpath/${domname}old.qcow2

  sudo mv $imgname $imgnameold

  echo "Just FYI, this is what we are working with:"
  sudo virt-filesystems --long -h --all -a $imgnameold

  sudo qemu-img create -f qcow2 -o preallocation=metadata $imgname $newdisksize
  sudo virt-resize --expand $partition --LV-expand $lv $imgnameold $imgname

  echo "Cowardly refusing to clean up the old image.  You'll probably want to:"
  echo "sudo rm $imgnameold"
}

populate_etc_hosts() {
  # maybe todo: change this to only use $vmset
  ATTEMPTS=30
  FAILED=0
  num_expected=$(echo $vmset | awk '{print NF}')
  cmd="ls"
  for domname in $vmset; do
    cmd="$cmd /mnt/vm-share/$domname.hello"
  done
  count=$($cmd | wc -w)
  #count=`ls /mnt/vm-share/$domprefix*.hello | wc -w`
  while [ $count -lt $num_expected  ]; do
    FAILED=$(expr $FAILED + 1)
    echo $FAILED
    if [ $FAILED -ge $ATTEMPTS ]; then
      echo "VM(s) did not write their IP info in /mnt/vm-share/$domprefix*.hello"
      echo "Manual investigation is required"
      exit 1
    fi
    sleep 10

    cmd="ls"
    for domname in $vmset; do
      cmd="$cmd /mnt/vm-share/$domname.hello"
    done
    count=$($cmd | wc -w)
    #  count=`ls /mnt/vm-share/$domprefix*.hello | wc -w`
  done

  cat >/mnt/vm-share/fill-etc-hosts.bash <<EOD
  vmset="$vmset"
  for domname in \$vmset; do
    hosts_line=\$(cat /mnt/vm-share/\$domname.hello)
    if \$(grep -qsP "\b\$domname\b" /etc/hosts) ;then
      perl -p -i -e "s|.*\b\$domname\b.*\$|\$hosts_line|" /etc/hosts
    else
      sh -c "cat /mnt/vm-share/\$domname.hello >> /etc/hosts"
    fi
  done
EOD

  sudo bash /mnt/vm-share/fill-etc-hosts.bash

  # do the same thing on the vm's (poor man's DNS!)
  for domname in $vmset; do
    sudo ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" $domname 'bash /mnt/vm-share/fill-etc-hosts.bash'
  done
}

populate_default_dns() {
  # /etc/hosts alone isn't enough to get around the dreaded
  # "getaddrinfo: Name or service not known"
  # so update libvirt dns
  # TODO don't depend on hosts being /etc/hosts

  sudo virsh net-dumpxml default > /tmp/default-network.xml
  for sshhost in $vmset; do
    is_el6=$(sudo ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" $sshhost "grep -q 'release 6' /etc/redhat-release && echo true || echo false")
    if [ "$is_el6" = "true" ]; then
      macaddr=$(sudo ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" $sshhost "ifconfig eth0 | grep eth0 | perl -p -e 's/^.*HWaddr\s(\S+)\s*\$/\$1/'" )
    else
      macaddr=$(sudo ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" $sshhost "ifconfig eth0 | grep ether | perl -p -e 's/^.*ether\s+(\S+)\s+.*Ether.*\$/\$1/'" )
    fi
    if [ "x$macaddr" = "x" ]; then
       fatal "Failed to get \$macaddr for $sshhost.  (next step is probably to determine why the host did not end up in /etc/hosts which is usually because /mnt/vm-share/$sshhost.hello did not get written due to an nfs issue)"
    fi
    ipaddr=$(grep "$sshhost.example.com" /etc/hosts | perl -p -i -e 's/^(\S+)\s+.*$/$1/')
    if [ "x$ipaddr" = "x" ]; then
      fatal "Failed find ipaddr for $sshhost.example.com in /etc/hosts"
    fi
    if `grep -q $sshhost.example.com /tmp/default-network.xml`; then
      fatal "$sshhost already exists in /tmp/default-network.xml, you may need to update your the default network manually"
    fi
    dhcp_entry="<host mac=\"$macaddr\" name=\"$sshhost.example.com\" ip=\"$ipaddr\" />"
    #sudo sed -i "s#</dhcp>#$(echo $dhcp_entry)\n</dhcp>#" /tmp/default-network.xml
    sudo virsh net-update --config --live default add ip-dhcp-host "$dhcp_entry"
  done
}

remove_dns_entry() {
  domname=$1
  network_name=default
  fname=/tmp/default-${network_name}.xml
  sudo virsh net-dumpxml $network_name > $fname
  echo "name=[\"']$domname\\."
  if ! $(grep -q -P "name=[\"']$domname\\." $fname); then
    echo 'virt dns entry not present'
  else
    thehostline=$(grep -P "name=[\"']$domname\\." $fname)
    #remove whitespace
    thehostxml=`echo $thehostline | perl -p -e s'/^\s*(<host.*\/>)\s*$/$1/'`
    # escape double quotes, just in case
    thehostxml=`echo $thehostxml | perl -p -e s'/"/\\\\"/g'`
    sudo virsh net-update --command delete --section ip-dhcp-host --xml "$thehostxml" $network_name
  fi
}

stop_guests() {
  if [ $# -ne 0 ]; then
    vmset="$@"
  fi
  for domname in $vmset; do
    destroy_if_running $domname &
  done
  wait
  VMSET=$vmset wait_for_status 'shut off'
}

install_foreman() {
  # Make sure the VM is subscribed to the right repos before running
  # this command.  Hint:
  #   subscription-manager register
  # Find the right poolID to attach using line below
  #   subscription-manager list --available
  #   subscription-manager attach --pool=XXXXXX
  #   yum-config-manager --disable rhel-server-ost-6-preview-rpms
  #   yum-config-manager --disable rhel-server-ost-6-folsom-rpms
  #   yum-config-manager --enable rhel-server-ost-6-3-rpms
  domname=$1
  foreman_provisioning=$2
  if [ ! -f /mnt/vm-share/vftool/vftool.bash ]; then
    mkdir -p /mnt/vm-share/vftool
    cp vftool.bash  /mnt/vm-share/vftool
  fi
  [[ -z $INSTALLURL ]] || setinstallurl="INSTALLURL=$INSTALLURL"
  sudo ssh -t -t -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" $domname "$setinstallurl bash -x /mnt/vm-share/vftool/vftool.bash install_foreman_here $foreman_provisioning >/tmp/$domname-foreman-install.log 2>&1"
}

install_foreman_here() {
  # override this if want to test against locally cloned
  # redhat-openstack/astpaor repo
  INSTALLER_DIR=${INSTALLER_DIR:=/usr/share/openstack-foreman-installer/bin}

  # install foreman on *this* host (i.e., you are most likely running
  # this directly on a vm)
  PROV_NETWORK=${PROV_NETWORK:="192.168.101"}

  export FOREMAN_PROVISIONING=$1
  if [ "x$FOREMAN_PROVISIONING" = "xtrue" ]; then
    export FOREMAN_GATEWAY=$PROV_NETWORK.1
  else
    export FOREMAN_GATEWAY=false
  fi

  export PRIVATE_CONTROLLER_IP=192.168.200.10
  export PRIVATE_INTERFACE=eth1
  export PRIVATE_NETMASK=192.168.200.0/24
  export PUBLIC_CONTROLLER_IP=192.168.201.10
  export PUBLIC_INTERFACE=eth2
  export PUBLIC_NETMASK=192.168.201.0/24

  # oddly, hostname --fqdn does not return a fqdn, but plain
  # old hostname does in this setup...
  export PUPPETMASTER=`hostname`

  # intended to be run as root directly on vm
  install_pkgs "openstack-foreman-installer augeas"
  # install rubygem-foreman_api with modern foreman
  if $(rpm -q --queryformat "%{RPMTAG_VERSION}" foreman | grep -qP '^(2|1.[6789])') ; then
    install_pkgs "rubygem-foreman_api"
  fi
  if [ "x$FOREMAN_PROVISIONING" = "xtrue" ]; then
    augtool <<EOA
      set /files/etc/sysconfig/network-scripts/ifcfg-eth1/BOOTPROTO none
      set /files/etc/sysconfig/network-scripts/ifcfg-eth1/IPADDR    $PROV_NETWORK.2
      set /files/etc/sysconfig/network-scripts/ifcfg-eth1/NETMASK   255.255.255.0
      set /files/etc/sysconfig/network-scripts/ifcfg-eth1/NM_CONTROLLED no
      set /files/etc/sysconfig/network-scripts/ifcfg-eth1/ONBOOT    yes
      save
EOA
    ifup eth1

    INSTALLURL=${INSTALLURL:='http://yourrhel6mirror.com/somepath/os/x86_64'}
    ESCAPEDINSTALLURL=$(echo $INSTALLURL | perl -p -e 's/\//\\\//g')
    perl -p -i -e "s/^m\.path=.*\$/m\.path=\"$ESCAPEDINSTALLURL\"/" \
      /usr/share/openstack-foreman-installer/bin/seeds.rb
  fi
  export SEED_ADMIN_PASSWORD=changeme
  cd $INSTALLER_DIR
  # not sure why these didn't set admin password to changeme......
  #perl -p -i -e 's/rake db:seed/rake db:seed SEED_ADMIN_PASSWORD=changeme/g' foreman_server.sh
  #if [ -f /usr/share/foreman/db/seeds.d/04-admin.rb ]; then
  #  perl -p -i -e 's/user.password = random/user.password = changeme/g' /usr/share/foreman/db/seeds.d/04-admin.rb
  #fi
  yes | bash -x ./foreman_server.sh
  # .....but this does!
  perl -p -i -e 's/random = User.random_password/random = "changeme"/' /usr/share/foreman/lib/tasks/reset_permissions.rake
  foreman-rake permissions:reset
}

get_logs() {
  if [ $# -ne 0 ]; then
    destdir=$1
    if [ ! -d $destdir ]; then
      mkdir $destdir
    fi
  else
    destdir='/mnt/vm-share/logs/latest'
  fi
  for vm in $VMSET; do
    sudo ssh -t -t -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" $vm "/mnt/vm-share/vftool/vftool.bash copy_logs_from_here $destdir"
  done
}

copy_log_or_warn() {
  src=$1
  dest=$2
  if [ -e $dest ]; then
    echo "NOT OVERWRITING $dest"
    return 1
  else
    cp -ra --no-clobber $src $dest
  fi
}

copy_logs_from_here() {
  destdir=$1

  copy_log_or_warn /var/log/messages $destdir/$(hostname -s).messages
  copy_log_or_warn /var/log/pacemaker.log $destdir/$(hostname -s).pacemaker.log
  copy_log_or_warn /var/log/mysqld.log $destdir/$(hostname -s).mysqld.log
  copy_log_or_warn /var/log/mariadb/mariadb.log $destdir/$(hostname -s).mariadb.log
  for d in keystone glance nova neutron cinder ceilometer mongodb httpd horizon heat audit; do
    copy_log_or_warn /var/log/$d $destdir/$(hostname -s).$d
  done
}

foreman_provisioned_vm() {
  # create a guest and have it pxe boot from foreman
  # TODO
  # autopick a macaddr
  # create the host in foreman using api

  domname=$1
  image=$poolpath/$domname.qcow2
  sudo /usr/bin/qemu-img create -f qcow2 -o preallocation=metadata $image 9G
  sudo virt-install --connect=qemu:///system \
    --network network:foreman1,mac=52:54:00:BE:EF:01 \
    --network network:openstackvms1_1 \
    --network network:openstackvms1_2 \
    --pxe \
    --name=$domname \
    --disk $image,format=qcow2 \
    --ram 7000 \
    --vcpus=6 \
    --os-variant rhel6 \
    --vnc

}

installforemanv1() {
  workdir=~/foreman-astapor
  git clone git://github.com/jsomara/astapor.git -b foreman_11 $workdir
  cd $workdir
  echo BEGIN FOREMAN INSTALLER SCRIPT
  sudo bash -x foreman_server.sh
  echo END FOREMAN INSTALLER SCRIPT

  # make the client script accessible on our vm share
  test -f /tmp/foreman_client.sh || fatal "No /tmp/foreman_client.sh"
  sudo mv /tmp/foreman_client.sh /mnt/vm-share/
}

installforemanv2() {
  workdir=$HOME/foreman-installer-v2
  mkdir -p $workdir
  cd $workdir
  MODULE_PATH=$workdir/modules

  mkdir -p $workdir/foreman-installer
  mkdir -p $MODULE_PATH
  wget http://github.com/theforeman/foreman-installer/tarball/master -O - | tar xzvf - -C foreman-installer --strip-components=1
  ln -s $workdir/foreman-installer/foreman_installer $MODULE_PATH/foreman_installer

  for mod in apache concat dhcp dns foreman foreman_proxy git passenger puppet tftp xinetd ; do
    mkdir -p $MODULE_PATH/$mod
    wget http://github.com/theforeman/puppet-$mod/tarball/master -O - | tar xzvf - -C $MODULE_PATH/$mod --strip-components=1
  done

  cp $MODULE_PATH/foreman_installer/answers.yaml $MODULE_PATH/foreman_installer/answers.yaml.orig
  cat >$MODULE_PATH/foreman_installer/answers.yaml <<EOY
---
puppet: false
puppetmaster: false
foreman:
  user: foreman
EOY

  cat $MODULE_PATH/foreman_installer/answers.yaml

  #echo include foreman_installer | puppet apply --modulepath $MODULE_PATH

}

installmsysql() {

  modulepath=/etc/puppet/modules/production
  if [ ! -e $modulepath/mysql -o ! -e $modulepath/stdlib ]; then
    fatal "installmysql() missing mysql or stdlib under $modulepath"
  fi

  cat >/tmp/mysql-db.pp <<EOM
class { 'mysql::server':
    config_hash => {
       'root_password' => 'foreman'
    }
}

mysql::db { 'foreman':
    user     => 'foreman',
    password => 'foreman',
    host     => 'localhost',
    grant    => ['all'],
    charset => 'utf8',
    require => File['/root/.my.cnf'],
}
EOM

  sudo puppet apply --debug --verbose --modulepath=$modulepath /tmp/mysql-db.pp
  chkconfig mysqld on  || fatal "Could not 'chkconfig mysqld on'"
}

append_user_auth_keys() {
  # add user pub key to /mnt/vm-share/authorized_keys for convenience

  if [ ! -f ~/.ssh/id_rsa.pub ]; then ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa ; fi

  sudo sh -c "cat $HOME/.ssh/id_rsa.pub >> /mnt/vm-share/authorized_keys"
  sudo chmod ugo+r /mnt/vm-share/authorized_keys

}

ntp_setup() {
  # TODO: this all should happen in prep_images instead
  # setup ntp on host and guests
  install_pkgs "ntp"

  test -f /etc/ntp.conf.sav || sudo cp /etc/ntp.conf /etc/ntp.conf.sav

  cat >/mnt/vm-share/ntp.conf <<EONTP
restrict default kod nomodify notrap nopeer noquery
restrict -6 default kod nomodify notrap nopeer noquery
restrict 127.0.0.1
restrict -6 ::1
server 0.rhel.pool.ntp.org iburst
server 1.rhel.pool.ntp.org iburst
server 2.rhel.pool.ntp.org iburst
EONTP

  sudo cp /mnt/vm-share/ntp.conf /etc/ntp.conf
  sudo chkconfig ntpd on
  sudo service ntpd restart
  for domname in $vmset; do
    if ! sudo virsh list | grep -qP "\b$domname\b"; then
      warn "$domname is not running"
    else
      sudo ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" $domname 'yum -y install ntp; cp /mnt/vm-share/ntp.conf /etc/ntp.conf; chkconfig ntpd on; service ntpd restart'
    fi
  done
}

install_auth_keys() {
  # this is typically handled in the post of the kicstart,
  # so this function only exists for convenience
  for domname in $vmset; do
    if ! sudo virsh --quiet list | grep -qP "\b$domname\b"; then
      fatal "$domname is not running"
    fi
    sudo ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" $domname 'mkdir -p /root/.ssh; chmod 700 /root/.ssh; cp /mnt/vm-share/authorized_keys /root/.ssh/authorized_keys; chmod 0600 /root/.ssh/authorized_keys'
  done
}

registerguests() {
  # register guest vm's to foreman
  test -f /mnt/vm-share/foreman_client.sh || fatal "/mnt/vm-share/foreman_client.sh does not exist"

  for i in $domsuffixes; do
    domname=$domprefix$i
    if ! sudo virsh list | grep -qP "\b$domname\b"; then
      warn "$domname is not running, skipping"
    else
      sudo ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" $domname "bash -x /mnt/vm-share/foreman_client.sh"
    fi
    exit 0
  done
}

rebootsnaphelper_singlenode() {
  flag=$1
  snapname=$2
  domname=$3
  destroy_if_running $domname
  sudo qemu-img snapshot $flag $snapname $poolpath/$domname.qcow2
  sudo virsh start $domname

}

rebootsnaphelper() {
  flag=$1
  shift
  if [ $# -eq 0 ]; then
    echo "Give me some vm names to reboot / snap"
    exit 1
  fi
  if [ "x$SNAPNAME" = "x" ]; then
      SNAPNAME=snap_$(date +%Y%m%d_%H%M%S)
  fi
  for domname in $@; do
    rebootsnaphelper_singlenode $flag $SNAPNAME $domname &
  done
  wait
  VMSET="$@" wait_for_port 22
}

reboot_snap_revert() {
  if [ "x$SNAPNAME" = "x" ]; then
    echo 'set SNAPNAME to revert to'
    exit 1
  fi
  rebootsnaphelper '-a' $@
}

reboot_snap_take() {
  rebootsnaphelper '-c' $@
}

snap_list() {
  if [ $# -eq 0 ]; then
    for domname in $vmset; do
      sudo qemu-img snapshot -l $poolpath/$domname.qcow2
    done
  else
    for domname in $@; do
      sudo qemu-img snapshot -l $poolpath/$domname.qcow2
    done
  fi
}

run() {
  if [ $# -eq 0 ]; then
    echo "Give me a command to run on $VMSET"
    exit 1
  fi
  for domname in $vmset; do
    ssh -t -t -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" root@$domname "$@"&
  done
  wait
}

configure_nic() {
  if [ $# -ne 5 ]; then
     fatal "5 arguments expected for configure_nic"
  fi
  domname=$1
  type=$2  # only "static" supported now
  iface=$3
  ipaddr=$4
  netmask=$5

  mkdir -p /mnt/vm-share/tmp/nic

  netdevicename=$(echo $iface | perl -p -e 's/eth/net/')
  macaddr=$(virsh dumpxml $domname | grep -B 4 -A 2 "alias name=.$netdevicename" | grep 'mac address' | perl -p -e 's/^.*address=.(.................).*$/$1/')

  # EL6
  cat >/mnt/vm-share/tmp/nic/$domname-$iface.aug <<EOA
      set /files/etc/sysconfig/network-scripts/ifcfg-$iface/BOOTPROTO none
      set /files/etc/sysconfig/network-scripts/ifcfg-$iface/IPADDR    $ipaddr
      set /files/etc/sysconfig/network-scripts/ifcfg-$iface/NETMASK   $netmask
      set /files/etc/sysconfig/network-scripts/ifcfg-$iface/NM_CONTROLLED no
      set /files/etc/sysconfig/network-scripts/ifcfg-$iface/ONBOOT    yes
      save
EOA

  # EL7
  cat >/mnt/vm-share/tmp/nic/$domname-$iface.cfg <<EOC
TYPE=Ethernet
DEVICE=$iface
BOOTPROTO=none
ONBOOT=yes
NETMASK=$netmask
IPADDR=$ipaddr
USERCTL=no
MACADDR=$macaddr
EOC

  ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" root@$domname \
    "grep -qs 'release 6' /etc/redhat-release && augtool -f /mnt/vm-share/tmp/nic/$domname-$iface.aug; grep -qs 'release 7' /etc/redhat-release && cp /mnt/vm-share/tmp/nic/$domname-$iface.cfg /etc/sysconfig/network-scripts/ifcfg-$iface; /sbin/ifup $iface"
}

# todo maybe not destroy default network given an option
delete_all_networks() {
  for the_network in `sudo virsh --quiet net-list --all | awk '{print $1}'`; do
    sudo virsh net-destroy $the_network
    sudo virsh net-undefine $the_network
  done
  echo 'It would probably be a good idea to restart libvirtd at this point.'
}

delete_vms() {
  for domname in $@; do
    vol=$(sudo virsh dumpxml $domname | grep 'source file' | perl -p -e "s/^.*source file='(.*)'.*\$/\$1/")
    echo "vol is " $vol
    sudo virsh destroy $domname
    sudo virsh undefine $domname
    sudo virsh vol-delete $vol
    sudo rm /mnt/vm-share/$domname.hello
    sudo perl -p -i -e "s/^(.*$domname.*)\n\$//" /etc/hosts
    remove_dns_entry $domname
  done
}

# this only successfully deletes volumes in the one-volume-per-vm case
delete_all_vms() {
  for domname in `sudo virsh --quiet list --all | awk '{print $2}'`; do
    delete_vms $domname
  done
  echo 'It would probably be a good idea to restart libvirtd at this point.'
}

# this only successfully deletes volumes in the one-volume-per-vm case
stop_all() {
  for domname in `sudo virsh --quiet list | awk '{print $2}'`; do
    destroy_if_running $domname
  done
}

[[ "$#" -lt 1 ]] && usage
case "$1" in
  "host_depends")
     host_depends
     ;;
  "el7_host_depends")
     el7_host_depends
     ;;
  "host_permissive")
     host_permissive
     ;;
  "el7_host_permissive")
     el7_host_permissive
     ;;
  "libvirt_prep")
     libvirt_prep
     ;;
  "create_foreman_networks")
     create_foreman_networks
     ;;
  "vm_auth_keys")
     vm_auth_keys
     ;;
  "kick_first_vm")
     kick_first_vm
     ;;
  "el7_kick_first_vm")
     el7_kick_first_vm
     ;;
  "create_images")
     create_images
     ;;
  "clone_image")
     clone_image $2 $3
     ;;
  "prep_images")
     prep_images
     ;;
  "first_snaps")
     first_snaps
     ;;
  "start_guests")
     start_guests "${@:2}"
     ;;
  "populate_etc_hosts")
     populate_etc_hosts
     ;;
  "populate_default_dns")
     populate_default_dns
     ;;
  "ntp_setup")
     ntp_setup
     ;;
  "install_foreman")
     install_foreman "${@:2}"
     ;;
  "install_foreman_here")
     install_foreman_here $2
     ;;
  "install-mysql")
     installmysql
     ;;
  "foreman-with-mysql")
     foremanwithmysql
     ;;
  "register-guests")
     registerguests
     ;;
  # other useful subcommands, not used in typical "all" case
  "stop_guests")
     stop_guests "${@:2}"
     ;;
  "stop_all")
     stop_all
     ;;
  "snap_list")
     snap_list "${@:2}"
     ;;
  "reboot_snap_revert")
     reboot_snap_revert "${@:2}"
     ;;
  "reboot_snap_take")
     reboot_snap_take "${@:2}"
     ;;
  "append_user_auth_keys")
     append_user_auth_keys
     ;;
  "install_auth_keys")
     install_auth_keys
     ;;
  "installoldrubydeps")
     installoldrubydeps
     ;;
  "wait_for_port")
     wait_for_port "${@:2}"
     ;;
  "wait_for_status")
     wait_for_status "${@:2}"
     ;;
  "configure_nic")
     configure_nic "${@:2}"
     ;;
  "run")
     run "${@:2}"
     ;;
  "default_network_ip")
     default_network_ip
     ;;
  "delete_all_networks")
     delete_all_networks
     ;;
  "delete_vms")
     delete_vms "${@:2}"
     ;;
  "delete_all_vms")
     delete_all_vms
     ;;
  "copy_logs_from_here")
     copy_logs_from_here "${@:2}"
     ;;
  "get_logs")
     get_logs "${@:2}"
     ;;
  "resize_image")
     resize_image "${@:2}"
     ;;
  "all")
     host_depends
     host_permissive
     libvirt_prep
     default_network_ip
     create_foreman_networks
     vm_auth_keys
     kick_first_vm
     create_images
     prep_images
     first_snaps
     start_guests
     populate_etc_hosts
     #installforemanv2
     #installmysql
     #foremanwithmysql
     #registerguests
     ;;
  *) usage
     ;;
esac
