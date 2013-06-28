#!/bin/bash

domprefix=${DOMPREFIX:=r64vm}
domsuffixes=${DOMSUFFIXES:="1 2 3 4 5 6"}
poolpath=${POOLPATH:=/home/vms}
        #/var/lib/libvirt/images

if [ "x$VMSET" = "x" ]; then
  vmset=$(echo $domsuffixes | perl -p -e "s/(\S+)/$domprefix\$1/g")
else
  vmset=$VMSET
fi

# todo
# * update everywhere to use VMSET env var (derived from domprefix and
#     domsuffix if not provided)
# * set_vm_network <vmname> <interface #> <network name>
#   - updates existing network interface to point to <network name>
# * delete_vm_network <vmname> <interface #>
# * change the names of default created networks
#     3 nat with no dhcp named nodhcpN
#     3 closed named closedN
# * add underscores to function names to stop the insanity
# * support a different named first vm, like "initvm"
# * support cases like foreman-provisioning-test
# * substitute 192.168.122 -> something like $default_network_ip_prefix
# * create /vs convenience link to /mnt/vm-share

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
    sudo yum install -y $install_list
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

hostdepends(){
  install_pkgs "nfs-utils libguestfs-tools libvirt virt-manager git mysql-server tigervnc-server tigervnc-server-module tigervnc xorg-x11-twm xorg-x11-server-utils ntp emacs-nox"
}

hostpermissive(){
  sudo /sbin/iptables --flush
  sudo sysctl -w net.ipv4.ip_forward=1
  sudo sed -i 's/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/g' /etc/sysctl.conf
  sudo setenforce 0
}

libvirtprep(){
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

  # define some networks
for i in 1 2; do
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
  sudo virsh net-define /tmp/openstackvms2_$i.xml
  sudo virsh net-start openstackvms2_$i
  sudo virsh net-define /tmp/foreman$i.xml
  sudo virsh net-start foreman$i
done

  # this shouldn't be necessary, but i've seen issues on rhel6...
  # sudo virsh net-define /usr/share/libvirt/networks/default.xml
  # sudo virsh net-start default
  sudo /sbin/service libvirtd restart
}

defaultnetworkip() {
  default_ip_prefix=${DEFAULT_IP_PREFIX:=192.168.7}
  sudo virsh net-dumpxml default > /tmp/default-network.xml
  sudo virsh net-destroy default
  sudo virsh net-undefine default
  sudo sed -i "s#192.168.122#$default_ip_prefix#g" /tmp/default-network.xml
  sudo virsh net-define /tmp/default-network.xml
  sudo virsh net-start default
  sudo /sbin/service libvirtd start
}

vmauthkeys(){
  sudo sh -c "if [ ! -f /root/.ssh/id_rsa.pub ]; then ssh-keygen -t rsa -N '' -f /root/.ssh/id_rsa ; fi"

  sudo mkdir -p /mnt/vm-share
  sudo chmod ugo+rwx /mnt/vm-share;
  if ! `grep -q vm-share /etc/exports`; then
    sudo sh -c "echo '/mnt/vm-share 192.168.0.0/16(rw,sync,no_root_squash)' >> /etc/exports"
    sudo /sbin/service nfs restart
  fi

  sudo cp -f /root/.ssh/id_rsa.pub /mnt/vm-share/authorized_keys
  sudo chmod ugo+r /mnt/vm-share/authorized_keys
}

kickfirstvm(){

[[ -z $INSTALLURL ]] && fatal "INSTALLURL Is not defined"

domname="$domprefix"1
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
mount 192.168.122.1:/mnt/vm-share /mnt/vm-share
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
    --autostart \
    --os-variant rhel6 \
    --vnc

echo "view the install (if you want) with:"
echo "   virt-viewer --connect qemu+ssh://root@`hostname`/system $domname"
}

# create images to test foreman provisioning
# first image has 2 nic's: default + foreman1
# 2nd and 3rd images have 3 nic's: foreman1 + openstackvms1_1 + openstackvms1_2
#createimagesforprov() {
#
#}

createimages() {
  ATTEMPTS=60
  FAILED=0
  while [ sudo virsh list | grep -q "$domprefix"1 ]; do
    FAILED=$(expr $FAILED + 1)
    echo "waiting for ${domprefix}1 to stop. $FAILED"
    if [ $FAILED -ge $ATTEMPTS ]; then
      fatal "createimages() ${domprefix}1 must not be stopped to continue.  perhaps it is not done being installed yet."
    fi
    sleep 10
  done

  for i in $domsuffixes; do
    if [ "$i" = "1" ]; then
      continue
    fi
    sudo virt-clone -o "$domprefix"1 -n $domprefix$i -f $poolpath/$domprefix$i.qcow2
    sudo virt-sysprep -d $domprefix$i
  done
}

prepimages() {
  for i in $domsuffixes; do
    domname=$domprefix$i
    if sudo virsh list | grep -q $domname; then
      fatal "prepimages()  $domname must not be stopped to continue"
    fi
    mntpnt=/mnt/$domname

    sudo mkdir -p $mntpnt
    # when the host boots up, write a "we're here" file to /mnt/vm-share
    sudo guestmount -a $poolpath/$domname.qcow2 -i $mntpnt
    echo '#!/bin/bash
mount /mnt/vm-share' > /tmp/$domname.rc.local
    echo 'echo `ifconfig eth0 | grep "inet " | perl -p -e "s/.*inet .*?(\d\S+\d).*\\\$/\\\$1/"`' " $domname $domname.example.com> /mnt/vm-share/$domname.hello" >> /tmp/$domname.rc.local
    sudo cp /tmp/$domname.rc.local $mntpnt/etc/rc.d/rc.local
    sudo chmod ugo+x $mntpnt/etc/rc.d/rc.local
    # disable selinux if the kickstart did not
    sudo sh -c "echo 'SELINUX=disabled' > $mntpnt/etc/selinux/config"
    sudo sh -c "echo 'NETWORKING=yes
HOSTNAME=$domname.example.com' > $mntpnt/etc/sysconfig/network"
    # always mount /mnt/vm-share
    if ! sudo cat $mntpnt/etc/fstab | grep -q vm-share; then
      sudo sh -c "echo '192.168.122.1:/mnt/vm-share /mnt/vm-share nfs defaults 0 0' >> $mntpnt/etc/fstab"
    fi
    # noapic, no ipv6
    if ! sudo cat $mntpnt/boot/grub/grub.conf | grep -q 'kernel.*ipv6.disable'; then
      sudo sh -c "perl -p -i -e 's/^(\s*kernel\s+.*)\$/\$1 noapic ipv6.disable=1/' $mntpnt/boot/grub/grub.conf"
    fi
    sleep 2
    sudo umount $mntpnt
  done
}

firstsnaps() {
  # take initial snapshots
  for i in $domsuffixes; do
    domname=$domprefix$i
    if sudo virsh list | grep -q $domname; then
      fatal "firstsnaps()  $domname must not be stopped to continue"
    fi
    sudo qemu-img snapshot -c initial_snap $poolpath/$domname.qcow2
  done
}

startguests() {
  for i in $domsuffixes; do
    domname=$domprefix$i
    sudo virsh start $domname
  done
}

populateetchosts() {
  ATTEMPTS=30
  FAILED=0
  num_expected=$(echo $domsuffixes | awk '{print NF}')
  count=`ls /mnt/vm-share/$domprefix*.hello | wc -w`
  while [ $count -lt $num_expected  ]; do
    FAILED=$(expr $FAILED + 1)
    echo $FAILED
    if [ $FAILED -ge $ATTEMPTS ]; then
      echo "VM(s) did not write their IP info in /mnt/vm-share/$domprefix*.hello"
      echo "Manual investigation is required"
      exit 1
    fi
    sleep 10
    count=`ls /mnt/vm-share/$domprefix*.hello | wc -w`
  done

  cat >/mnt/vm-share/fill-etc-hosts.bash <<EOD
  domsuffixes="$domsuffixes"
  for i in \$domsuffixes; do
    domname=$domprefix\$i
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
  for i in $domsuffixes; do
    sshhost=$domprefix$i
    sudo ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" $sshhost 'bash /mnt/vm-share/fill-etc-hosts.bash'
  done
}

populatedefaultdns() {
  # /etc/hosts alone isn't enough to get around the dreaded
  # "getaddrinfo: Name or service not known"
  # so update libvirt dns

  sudo virsh net-dumpxml default > /tmp/default-network.xml
  for i in $domsuffixes; do
    sshhost=$domprefix$i
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
  
  stopguests
  sudo /etc/init.d/libvirtd restart
  startguests
}

stopguests() {
  for i in $domsuffixes; do
    domname=$domprefix$i
    sudo virsh destroy $domname
  done
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

appenduserauthkeys() {
  # add user pub key to /mnt/vm-share/authorized_keys for convenience

  if [ ! -f ~/.ssh/id_rsa.pub ]; then ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa ; fi

  sudo sh -c "cat $HOME/.ssh/id_rsa.pub >> /mnt/vm-share/authorized_keys"
  sudo chmod ugo+r /mnt/vm-share/authorized_keys

}

ntpsetup() {
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
  for i in $domsuffixes; do
    domname=$domprefix$i
    if ! sudo virsh list | grep -q $domname; then
      warn "$domname is not running"
    else
      sudo ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" $domname 'yum -y install ntp; cp /mnt/vm-share/ntp.conf /etc/ntp.conf; chkconfig ntpd on; service ntpd restart'
    fi
  done
}

installauthkeys() {
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
    sudo virsh destroy $domname
    sudo qemu-img snapshot $flag $SNAPNAME $poolpath/$domname.qcow2
    sudo virsh start $domname
  done
}

rebootsnaprevert() {
  if [ "x$SNAPNAME" = "x" ]; then
    echo 'set SNAPNAME to revert to'
    exit 1
  fi
  rebootsnaphelper '-a' $@
}

rebootsnaptake() {
  rebootsnaphelper '-c' $@
}

snaplist() {
  if [ $# -eq 0 ]; then
    for i in $domsuffixes; do
      domname=$domprefix$i
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
    sudo virsh destroy $domname
    sudo virsh undefine $domname
    sudo virsh vol-delete $vol
  done
}

# this only successfully deletes volumes in the one-volume-per-vm case
delete_all_vms() {
  for domname in `sudo virsh --quiet list --all | awk '{print $2}'`; do
    destory_vms $domname
  done
  echo 'It would probably be a good idea to restart libvirtd at this point.'
}

[[ "$#" -lt 1 ]] && usage
case "$1" in
  "host-depends")
     hostdepends
     ;;
  "host-permissive")
     hostpermissive
     ;;
  "libvirt-prep")
     libvirtprep
     ;;
  "vm-auth-keys")
     vmauthkeys
     ;;
  "kick-first-vm")
     kickfirstvm
     ;;
  "create-images")
     createimages
     ;;
  "prep-images")
     prepimages
     ;;
  "first-snaps")
     firstsnaps
     ;;
  "start-guests")
     startguests
     ;;
  "populate-etc-hosts")
     populateetchosts
     ;;
  "populate-default-dns")
     populatedefaultdns
     ;;
  "ntp-setup")
     ntpsetup
     ;;
  "install-foreman")
     installforeman
     ;;
  "install-foremanv2")
     installforemanv2
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
  "stop-guests")
     stopguests
     ;;
  "snap-list")
     snaplist
     ;;
  "reboot-snap-revert")
     rebootsnaprevert "${@:2}"
     ;;
  "reboot-snap-take")
     rebootsnaptake "${@:2}"
     ;;
  "append-user-auth-keys")
     appenduserauthkeys
     ;;
  "install-auth-keys")
     installauthkeys
     ;;
  "installoldrubydeps")
     installoldrubydeps
     ;;
  "default-network-ip")
     defaultnetworkip
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
     hostdepends
     hostpermissive
     libvirtprep
     defaultnetworkip
     vmauthkeys
     kickfirstvm
     createimages
     prepimages && sleep 60 # make sure unmounted before continuing
     firstsnaps
     startguests
     populateetchosts
     ntpsetup
     installforemanv2
     #installmysql
     #foremanwithmysql
     registerguests
     ;;
  *) usage
     ;;
esac
