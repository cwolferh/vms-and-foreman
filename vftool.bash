domprefix=el64vm
domsuffixes="1 2 3"

usage(){
    echo "Usage: $0 host-depends | all"
    exit 1
}

fatal(){
    echo "Fatal: $1"
    exit 1
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
  install_pkgs "nfs-utils libguestfs-tools libvirt virt-manager git mysql-server tigervnc-server tigervnc-server-module tigervnc xorg-x11-twm xorg-x11-server-utils"
}

hostpermissive(){
  sudo /sbin/iptables --flush
  sudo sysctl -w net.ipv4.ip_forward=1
  sudo sed -i 's/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/g' /etc/sysctl.conf
  sudo setenforce 0
}

libvirtprep(){
  sudo /sbin/service libvirtd start

  cat >/tmp/openstackvms.xml <<EOF
<network>
  <name>openstackvms</name>
  <bridge name="virbr1" stp="off" delay="0" />
</network>
EOF

  sudo virsh net-define /tmp/openstackvms.xml
  sudo virsh net-start openstackvms

  # this shouldn't be necessary, but i've seen issues on rhel6...
  sudo virsh net-define /usr/share/libvirt/networks/default.xml
  sudo virsh net-start default

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
image=/var/lib/libvirt/images/$domname.qcow2
test -f $image && fatal "image $image already exists"
sudo /usr/bin/qemu-img create -f qcow2 -o preallocation=metadata $image 8G

cat >/tmp/$domname.ks <<EOD
%packages
@base
@core
nfs-utils
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
    --network network:openstackvms \
    --initrd-inject=/tmp/$domname.ks \
    --extra-args="ks=file:/$domname.ks ksdevice=eth0 noipv6 ip=dhcp" \
    --name=$domname \
    --location=$INSTALLURL \
    --disk $image,format=qcow2 \
    --ram 1200 \
    --vcpus=1 \
    --autostart \
    --os-variant rhel6 \
    --vnc

echo "view the install with:"
echo "   virt-viewer --connect qemu+ssh://root@`hostname`/system $domname"
echo "press enter when install is complete."
echo "note that the guest MUST NOT BE RUNNING before continuing"
read

}

createimages() {
  if sudo virsh list | grep -q "$domprefix"1; then
    fatal "createimages() ${domprefix}1 must not be stopped to continue"
  fi

  for i in $domsuffixes; do
    if [ "$i" = "1" ]; then
      continue
    fi
    sudo virt-clone -o "$domprefix"1 -n $domprefix$i -f /var/lib/libvirt/images/$domprefix$i.qcow2
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
    sudo guestmount -a /var/lib/libvirt/images/$domname.qcow2 -i $mntpnt
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
    sudo qemu-img snapshot -c initial_snap /var/lib/libvirt/images/$domname.qcow2
  done
}

startguests() {
  for i in $domsuffixes; do
    domname=$domprefix$i
    sudo virsh start $domname
  done
}

buildetchosts() {
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

stopguests() {
  for i in $domsuffixes; do
    domname=$domprefix$i
    sudo virsh destroy $domname
  done
}

installforeman() {
  workdir=~/foreman-astapor
  git clone git://github.com/jsomara/astapor.git $workdir
  cd $workdir
  sudo bash -x foreman_server.sh

  # make the client script accessible on our vm share
  test -f /tmp/foreman_client.sh || fatal "No /tmp/foreman_client.sh"
  sudo mv /tmp/foreman_client.sh /mnt/vm-share/
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

registerguests() {
  echo "TODO :-)"
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
     "install-foreman")
	installforeman
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
     "stop-guests")
	stopguests
	;;
     "all")
        hostdepends
        hostpermissive
        libvirtprep
	vmauthkeys
	kickfirstvm
	createimages
	prepimages && sleep 60 # make sure unmounted before continuing
        firstsnaps
	startguests
	populateetchosts
	installforeman
        installmysql
        foremanwithmysql
        registerguests
        ;;
     *) usage
        ;;
esac
