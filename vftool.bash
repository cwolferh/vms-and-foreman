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

if [ "x$INITIMAGE" = "x" ]; then
  initimage=$(echo $vmset | perl -p -e 's/^(\S+)\s?.*$/$1/')
else
  initimage=$INITIMAGE
fi

# todo
# * support cases like foreman-provisioning-test
# * create /vs convenience link to /mnt/vm-share
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

usage(){
    echo "Usage: $0 host-depends | all"
    exit 1
}

fatal(){
    echo "VF FATAL: $1"
    exit 1
}
warn(){
    echo "VF WARN: $1"
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
   if ! $(sudo virsh domstate $domname | grep -q 'shut off'); then
     sudo virsh destroy $domname
   fi
}

start_if_not_running() {
   domname=$1
   if ! $(sudo virsh domstate $domname | grep -q 'running'); then
     sudo virsh start $domname
   fi
}

host_depends(){
  install_pkgs "nfs-utils libguestfs-tools libvirt virt-manager git
  tigervnc-server tigervnc-server-module tigervnc xorg-x11-twm
  xorg-x11-server-utils ntp emacs-nox virt-install virt-viewer"
}

host_permissive(){
  sudo /sbin/iptables --flush
  sudo sysctl -w net.ipv4.ip_forward=1
  sudo sed -i 's/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/g' /etc/sysctl.conf
  sudo setenforce 0
  # TODO Fedora-ize, one adjustment of many:
  # sudo firewall-cmd --add-service=nfs
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
selinux --disabled
skipx
logging --level=info
timezone  America/Los_Angeles
bootloader --location=mbr --append="console=tty0 console=ttyS0,115200 rd_NO_PLYMOUTH"
clearpart --all
part /boot --fstype ext4 --size=100
part swap --size=100
part pv.01 --size=5000
volgroup lv_admin --pesize=32768 pv.01
logvol / --fstype ext4 --name=lv_root --vgname=lv_admin --size=4000 --grow
zerombr
network --bootproto=dhcp --noipv6 --device=eth0

%post

mkdir -p /mnt/vm-share
mount $default_ip_prefix.1:/mnt/vm-share /mnt/vm-share
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
    --extra-args="ks=file:/$domname.ks ksdevice=eth0 noipv6 ip=dhcp keymap=us lang=en_US" \
    --name=$domname \
    --location=$INSTALLURL \
    --disk $image,format=qcow2 \
    --ram 7000 \
    --vcpus=6 \
    --os-variant rhel6 \
    --vnc

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
  while $(sudo virsh list | grep -q "$initimage") ; do
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

  if $(sudo virsh list | grep -q "$src_domname") ; then
    fatal "clone_image() $src_domname must not be stopped to clone it."
  fi
  if $(sudo virsh list | grep -q "$dest_domname") ; then
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
    if sudo virsh list | grep -q $domname; then
      fatal "prep_images()  $domname must not be stopped to continue"
    fi
    mntpnt=/mnt/$domname

    sudo mkdir -p $mntpnt
    # when the host boots up, write a "we're here" file to /mnt/vm-share
    sudo guestmount -a $poolpath/$domname.qcow2 -i $mntpnt
    echo '#!/bin/bash
mount /mnt/vm-share' > /tmp/$domname.rc.local
    echo 'echo `ifconfig eth0 | grep "inet " | perl -p -e "s/.*inet .*?(\d\S+\d).*\\\$/\\\$1/"`' " $domname.example.com $domname> /mnt/vm-share/$domname.hello" >> /tmp/$domname.rc.local
    echo '/etc/init.d/ntpd stop; ntpdate clock.redhat.com; /etc/init.d/ntpd start;' >> /tmp/$domname.rc.local
    sudo cp /tmp/$domname.rc.local $mntpnt/etc/rc.d/rc.local
    sudo chmod ugo+x $mntpnt/etc/rc.d/rc.local
    # disable selinux if the kickstart did not
    sudo sh -c "echo 'SELINUX=disabled' > $mntpnt/etc/selinux/config"
    sudo sh -c "echo 'NETWORKING=yes
HOSTNAME=$domname.example.com' > $mntpnt/etc/sysconfig/network"
    # always mount /mnt/vm-share
    if ! sudo cat $mntpnt/etc/fstab | grep -q vm-share; then
      sudo sh -c "echo '$default_ip_prefix.1:/mnt/vm-share /mnt/vm-share nfs defaults 0 0' >> $mntpnt/etc/fstab"
    fi
    # noapic, no ipv6
    if ! sudo cat $mntpnt/boot/grub/grub.conf | grep -q 'kernel.*ipv6.disable'; then
      sudo sh -c "perl -p -i -e 's/^(\s*kernel\s+.*)\$/\$1 noapic ipv6.disable=1/' $mntpnt/boot/grub/grub.conf"
    fi
    # ssh keys
    sudo sh -c "mkdir -p $mntpnt/root/.ssh; chmod 700 $mntpnt/root/.ssh; cp /mnt/vm-share/authorized_keys $mntpnt/root/.ssh/authorized_keys; chmod 0600 $mntpnt/root/.ssh/authorized_keys"
    sleep 2
    sudo umount $mntpnt
  done
}

first_snaps() {
  # take initial snapshots
  for domname in $vmset; do
    if sudo virsh list | grep -q $domname; then
      fatal "first_snaps()  $domname must not be stopped to continue"
    fi
    sudo qemu-img snapshot -c initial_snap $poolpath/$domname.qcow2
  done
}

start_guests() {
  for domname in $vmset; do
    start_if_not_running $domname
  done
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
    if \$(grep -qs \$domname /etc/hosts) ;then
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

  sudo virsh net-dumpxml default > /tmp/default-network.xml
  for sshhost in $vmset; do
    macaddr=$(sudo ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" $sshhost "ifconfig eth0 | grep eth0 | perl -p -e 's/^.*HWaddr\s(\S+)\s*\$/\$1/'" )
    ipaddr=$(resolveip -s $sshhost)
    echo macaddr is $macaddr
    dhcp_entry="<host mac=\"$macaddr\" name=\"$sshhost.example.com\" ip=\"$ipaddr\" />"
    echo dhcp_entry is $dhcp_entry
    sudo sed -i "s#</dhcp>#$(echo $dhcp_entry)\n</dhcp>#" /tmp/default-network.xml
  done
  sudo virsh net-destroy default
  sudo virsh net-undefine default
  sudo virsh net-define /tmp/default-network.xml
  sudo virsh net-start default
  sudo virsh net-autostart default
  
  stop_guests
  sudo /etc/init.d/libvirtd restart
  sudo virsh net-start default
  start_guests
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
  for domname in $vmset; do
    destroy_if_running $domname
  done
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
  sudo ssh -t -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" $domname "$setinstallurl bash -x /mnt/vm-share/vftool/vftool.bash install_foreman_here $foreman_provisioning >/tmp/$domname-foreman-install.log 2>&1"
}

install_foreman_here() {
  # install foreman on *this* host (i.e., you are most likely running
  # this directly on a vm)
  PROV_NETWORK=${PROV_NETWORK:="192.168.101"}

  # foreman-related installer
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
    cd /usr/share/openstack-foreman-installer/bin
    yes | ./foreman_server.sh
 fi
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

installoldrubydeps() {
  # using rhel6 system ruby
  install_pkgs "yum-utils yum-rhn-plugin"
  sudo rpm -Uvh http://download.fedoraproject.org/pub/epel/6/x86_64/epel-release-6-8.noarch.rpm
  sudo yum-config-manager --enable rhel-6-server-optional-rpms
  sudo yum -y install https://yum.puppetlabs.com/el/6/products/x86_64/puppetlabs-release-6-7.noarch.rpm
  sudo yum clean all
  install_pkgs "augeas puppet git policycoreutils-python facter"
  sudo gem install highline
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

foreman-with-mysql() {
  sudo /sbin/service foreman stop
  sudo /sbin/service foreman-proxy stop
  sudo /sbin/service httpd stop

  install_pkgs "rubygem-mysql foreman-mysql foreman-console"
  # foreman was installed with sqlite, now point to mysql
  if [ ! -e /usr/share/foreman/config/database.yml.sqlite.SAV ]; then
    sudo mv /usr/share/foreman/config/database.yml /usr/share/foreman/config/database.yml.sqlite.SAV
  fi

  cat >/usr/share/foreman/config/database.yml <<EOD
production:
adapter: mysql
database: foreman
host: localhost
username: foreman
password: foreman
socket: "/var/lib/mysql/mysql.sock"
encoding: utf8
timeout: 5000
EOD

  # TODO verify we need this
  cp /usr/lib/ruby/site_ruby/1.8/puppet/reports/foreman.rb /usr/lib/ruby/site_ruby/1.8/puppet/reports/foreman-report.rb || fatal "Could not copy foreman.rb into target directory"
  exit 0
  RAILS_ENV=production rake db:migrate
  RAILS_ENV=production rake puppet:import:hosts_and_facts

  sudo /sbin/service foreman start
  sudo /sbin/service foreman-proxy start
  sudo /sbin/service httpd start

}

install_triple_o() {
  # following https://github.com/tripleo/incubator/blob/master/devtest.md on fedora
  mkdir ~/tripleo
  export TRIPLEO_ROOT=~/tripleo
  export PATH=$PATH:$TRIPLEO_ROOT/incubator/scripts
  cd $TRIPLEO_ROOT
  git clone https://github.com/tripleo/incubator.git
  sed -i "s/^ALWAYS_ELEMENTS=.*/ALWAYS_ELEMENTS='vm local-config stackuser fedora disable-selinux'/g" incubator/scripts/boot-elements
  git clone https://github.com/tripleo/bm_poseur.git
  git clone https://github.com/stackforge/diskimage-builder.git
  git clone https://github.com/stackforge/tripleo-image-elements.git
  git clone https://github.com/stackforge/tripleo-heat-templates.git
  install-dependencies
  setup-network
  cd $TRIPLEO_ROOT/tripleo-image-elements/elements/boot-stack
  sed -i "s/\"user\": \"stack\",/\"user\": \"`whoami`\",/" config.json

  cd $TRIPLEO_ROOT/incubator/
  boot-elements boot-stack -o seed
  SEED_IP=`scripts/get-vm-ip seed`
  export no_proxy=$no_proxy,$SEED_IP
  scp root@$SEED_IP:stackrc $TRIPLEO_ROOT/seedrc
  sed -i "s/localhost/$SEED_IP/" $TRIPLEO_ROOT/seedrc
  source $TRIPLEO_ROOT/seedrc
  create-nodes 1 512 10 3
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
    if ! sudo virsh list | grep -q $domname; then
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
    if ! sudo virsh --quiet list | grep -q $domname; then
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
    if ! sudo virsh list | grep -q $domname; then
      warn "$domname is not running, skipping"
    else
      sudo ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" $domname "bash -x /mnt/vm-share/foreman_client.sh"
    fi
    exit 0
  done
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
    destroy_if_running $domname
    sudo qemu-img snapshot $flag $SNAPNAME $poolpath/$domname.qcow2
    sudo virsh start $domname
  done
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
    destroy_if_running $domname
    sudo virsh undefine $domname
    sudo virsh vol-delete $vol
    sudo rm /mnt/vm-share/$domname.hello
    sudo perl -p -i -e "s/^(.*$domname.*)\$//" /etc/hosts
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

[[ "$#" -lt 1 ]] && usage
case "$1" in
  "host_depends")
     host_depends
     ;;
  "host_permissive")
     host_permissive
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
     start_guests
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
  "install_triple_o")
     install_triple_o
     ;;
  "register-guests")
     registerguests
     ;;
  # other useful subcommands, not used in typical "all" case
  "stop_guests")
     stop_guests
     ;;
  "snap_list")
     snap_list
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
     ntp_setup
     #installforemanv2
     #installmysql
     #foremanwithmysql
     #registerguests
     ;;
  *) usage
     ;;
esac
