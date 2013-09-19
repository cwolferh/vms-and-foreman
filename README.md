vms-and-foreman
===============

Build VM's from scratch on RHEL64, and install Foreman to manage them
for openstack.

Note: The *kick-first-vm subcommand* has a the caveat that
*INSTALL_URL must be defined before the kick-first-vm subcommand is
executed.  

If you are using this tool to setup foreman and VM's from scratch for
the first time, it is recommended to execute each step independently
(this should still save you loads of time from doing it manually!):

    # name of the first image we kickstart, our base image
    $ export INITIMAGE=rhel64init

    # $VMSET is the default set of vm's that this tool typically works
    # with.

    # If you are going to use foreman for provisioning, we only
    # have one vm for now, the foreman host.
    $ export VMSET='set1fore1'

    # Otherwise, if not using foreman in provisioning-mode, define all the vms to
    # build (e.g. foreman and two clients):
    $ export VMSET='set1fore1 set1client1 set1client2'

    $ bash -x vftool.bash host_depends
    $ bash -x vftool.bash host_permissive
    $ bash -x vftool.bash libvirt_prep
    
    $ bash -x vftool.bash default_network_ip  # change to 192.168.7
    $ bash -x vftool.bash create_foreman_networks
    $ bash -x vftool.bash vm_auth_keys
    
    # The following builds $INITIMAGE
    $ export INSTALLURL=http://your-top-secret-rhel6-install-tree/Server/x86_64/os/
    $ bash -x vftool.bash kick_first_vm
        
    # The following creates and updates images in $VMSET based on $INITIMAGE
    $ bash -x vftool.bash create_images
    $ bash -x vftool.bash prep_images
    $ bash -x vftool.bash first_snaps  # not necessary, but useful
    $ bash -x vftool.bash start_guests
    $ bash -x vftool.bash populate_etc_hosts
    $ bash -x vftool.bash populate_default_dns
    # wait for host(s) to start up
    # probably not necessary with latest tweaks
    $ bash -x vftool.bash ntp_setup

The guests in $VMSET are now ready to use.

If using foreman for provisioning:

    # Make sure set1fore1 is subscribed only to RHOS and RHEL6
    $ bash -x vftool.bash install_foreman set1fore1 true
    #                                               ^^ provisioning-mode is true

If using foreman not in provisioning-mode:

    # Make sure set1fore1 is subscribed only to RHOS and RHEL6
    $ bash -x vftool.bash install_foreman set1fore1 false
    #                                               ^^ provisioning-mode is false
    $ # bash -x vftool.bash register-guests TODO
  

Other useful commands

    $ bash -x vftool.bash delete_all_networks
    $ bash -x vftool.bash delete_all_vms
    $ bash -x vftool.bash delete_vms <vm_name1> <vn_name2> ...
    $ SNAPNAME=mysnap bash -x vftool.bash reboot_snap_take <vm_name1> <vn_name2> ...
    $ SNAPNAME=mysnap bash -x vftool.bash reboot_snap_revert <vm_name1> <vn_name2> ...


