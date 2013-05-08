vms-and-foreman
===============

Build VM's from scratch on RHEL64, and install Foreman to manage them
for openstack.

Note: The *kick-first-vm subcommand* has a couple of caveats:
*INSTALL_URL must be defined before the kick-first-vm subcommand is
executed.  
*Currently, the user must still manually connect to the
console during the kickstart and enter the keyboard and language.
(This needs to be fixed!)

If you are using this tool to setup foreman and VM's from scratch for
the first time, it is recommended to execute each step independently
(this should still save you loads of time from doing it manually!):


    $ bash -x vftool.bash host-depends
    $ bash -x vftool.bash host-permissive
    $ bash -x vftool.bash libvirt-prep
    $ bash -x vftool.bash vm-auth-keys
    
    $ export INSTALLURL=http://your-top-secret-rhel6-install-tree/Server/x86_64/os/
    $ bash -x vftool.bash kick-first-vm
    # connect to the vm and manually input keyboard/language
    
    $ bash -x vftool.bash create-images
    $ bash -x vftool.bash prep-images
    $ bash -x vftool.bash first-snaps  # not necessary, but useful
    $ bash -x vftool.bash start-guests
    $ bash -x vftool.bash populate-etc-hosts
    $ bash -x vftool.bash ntp-setup

Your three guests are now running and ready to use!  Time to install
the foreman.

    $ bash -x vftool.bash install-foreman
    $ bash -x vftool.bash register-guests



