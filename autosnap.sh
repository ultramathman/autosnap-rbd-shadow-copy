#!/bin/bash

# Snapshot script for Ceph RBD and Samba vfs shadow_copy2
# Written by Laurent Barbe <laurent+autosnap@ksperis.com>
# Version 0.1 - 2013-08-09
#
# Install this file and config file in /etc/ceph/scripts/
# Edit autosnap.conf
#
# Add in crontab :
# 00 0    * * *   root    /bin/bash /etc/ceph/scripts/autosnap.sh
#
# Add in your smb.conf in global or specific share section :
# vfs objects = shadow_copy2
# shadow:snapdir = .snapshots
# shadow:sort = desc

# Config file
configfile=/etc/ceph/scripts/autosnap.conf
if [ ! -f $configfile ]; then
	echo "Config file not found $configfile"
	exit 0
fi
source $configfile


makesnapshot() {
	share=$1

	snapname=`date -u +GMT-%Y.%m.%d-%H.%M.%S-autosnap`

	echo "* Create snapshot for $share: @$snapname"
	[[ "$useenhancedio" = "yes" ]] && {
		/sbin/sysctl dev.enhanceio.$share.do_clean=1
		while [[ `cat /proc/sys/dev/enhanceio/$share/do_clean` == 1 ]]; do sleep 1; done
	}
	mountpoint -q $sharedirectory/$share \
		&& sync \
		&& echo -n "synced, " \
		&& xfs_freeze -f $sharedirectory/$share \
		&& [[ "$useenhancedio" = "yes" ]] && {
				/sbin/sysctl dev.enhanceio.$share.do_clean=1
				while [[ `cat /proc/sys/dev/enhanceio/$share/do_clean` == 1 ]]; do sleep 1; done
				echo -n "wb cache cleaned, "
			} \
			|| /bin/echo -n "no cache, " \
		&& rbd --id=$id --keyring=$keyring snap create $rbdpool/$share@$snapname \
		&& echo "snapshot created."
	xfs_freeze -u $sharedirectory/$share

}


mountshadowcopy() {
	share=$1
	shadowcopylist=""
	# GET ALL EXISTING SNAPSHOT ON RBD
	snapcollection=$(rbd snap ls $rbdpool/$share | awk '{print $2}' | grep -- 'GMT-.*-autosnap$' | sort | sed 's/-autosnap$//g')

	datestart=$(date -u +%Y.%m.%d -d "$daterange")
        echo "start $datestart"
        dateend=$(date -u +%Y.%m.%d)
        echo "end $dateend"

        for snapitem in $(echo "$snapcollection")
        do
            timestamp=$(echo "$snapitem"|awk -F- '{print $2}')
            # Do inclusive range check
	    if [[ "$timestamp" == "$datestart" ||
                        "$timestamp" >  "$datestart" && "$timestamp" <  "$dateend" ||
                        "$timestamp" == "$dateend" ]]
            then
                echo "$snapitem in range, adding to mount list."
                shadowcopylist=$(echo "$shadowcopylist $snapitem")
            else
                echo "$snapitem not in range, ignoring."
            fi
	done

	# Shadow copies to mount
	echo -e "* Shadow Copy to mount for $rbdpool/$share :\n$shadowcopylist" | sed 's/^$/-/g'

	# GET MOUNTED SNAP
	[ ! -d $sharedirectory/$share/.snapshots ] && echo "Snapshot directory $sharedirectory/$share/.snapshots does not exist. Please create it before run." && return
	snapmounted=$(mount|grep $sharedirectory/$share/.snapshots|awk '{print $3}'|awk -F/ '{print $NF}'|sed 's/^@//g')
        # Cleanup abandoned snap mountpoints                                                                                                                                                                      
        for mountdir in $(ls "$sharedirectory/$share/.snapshots"|sed 's/^@//g')
        do
            if [[ ! $(echo "$snapmounted"|grep "$mountdir") ]]
            then
                echo "$sharedirectory/$share/.snapshots/@$mountdir exists but not mounted, removing."
                rmdir "$sharedirectory/$share/.snapshots/@$mountdir"
            fi
        done

	# Umount Snapshots not selected in shadowcopylist
	for snapshot in $snapmounted; do
		mountdir=$sharedirectory/$share/.snapshots/@$snapshot
		echo "$shadowcopylist" | grep -q "$snapshot" || {
			umount $mountdir || umount -l $mountdir
			rmdir $mountdir
			rbd unmap /dev/rbd/$rbdpool/$share@$snapshot-autosnap
		}
	done

	# Mount snaps in $shadowcopylist not already mount
	for snapshot in $shadowcopylist; do
		mountdir=$sharedirectory/$share/.snapshots/@$snapshot
		mountpoint -q $mountdir || {
			[ ! -d $mountdir ] && mkdir $mountdir
			rbd showmapped | awk '{print $4}' | grep "^$" || rbd map $rbdpool/$share@$snapshot-autosnap
			mount $mntoptions /dev/rbd/$rbdpool/$share@$snapshot-autosnap $mountdir
		}
	done

}


if [[ "$snapshotenable" = "yes" ]]; then
	for share in $sharelist; do
		makesnapshot $share
	done
fi

[[ "$snapshotenable" = "yes" ]] && [[ "$mountshadowcopyenable" = "yes" ]] && sleep 60

if [[ "$mountshadowcopyenable" = "yes" ]]; then
	for share in $sharelist; do
		mountshadowcopy $share
	done
fi

