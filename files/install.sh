#! /bin/bash
# @date 2020-03-24
# @brief Short script to automatically restore a HAT.tec system using fsarchiver.

DEFAULT_LUKSPASS="hattec-student-unlock"
DEFAULT_ROOT_MOUNT=/mnt
NUM_OF_PROCS=$(( "$(nproc)" + 1))
#################

# @function Show the usage of the script
showUsage() {
    echo -e "\nUsage: $0 -d [DEVICE] -f [FILENAME.fsa] (-m [ROOT_MOUNT])"
    echo -e "\nRestores a HAT.tec system using fsarchiver."
    echo -e "\nREQUIRES"
    echo -e "\n fsarchiver (www.fsarchiver.org) must be installed."
    echo -e "\nARGUMENTS"
    echo -e "  -d, --device \t The block device to which the systems should be restored, e.g. /dev/nvmeX or /dev/sdX."
    echo -e "  -f, --file \t The fsarchiver .fsa-file to be used as source."
    echo -e "  -m, --mount \t (optional) The mountpoint used for fixing the boot loader after the image was successfully restored. Defaults to \"$DEFAULT_ROOT_MOUNT\""
    echo -e "\nEXAMPLES"
    echo -e "\nRestores the systems to /dev/nvme0n1 from test.fsa"
    echo -e "  $0 -d /dev/nvme0n1 -f test.fsa"
    echo ""
}

if [ $# -eq 0 ]; then
    echo "No arguments supplied. See -h for available options!"
    exit 1
fi

# From: http://stackoverflow.com/a/24501190/1267320
# Code template for parsing command line parameters using only portable shell
# code, while handling both long and short params, handling '-f file' and
# '-f=file' style param data and also capturing non-parameters to be inserted
# back into the shell positional parameters.
while [ -n "$1" ]; do
        # Copy so we can modify it (can't modify $1)
        OPT="$1"
        # Detect argument termination
        if [ x"$OPT" = x"--" ]; then
                shift
                for OPT ; do
                        REMAINS="$REMAINS \"$OPT\""
                done
                break
        fi

        # Parse current opt / argument
        while [ x"$OPT" != x"-" ] ; do
                case "$OPT" in
                        # Handle --flag=value opts like this
                        #-c=* | --config=* )
                            #CONFIGFILE="${OPT#*=}"
                            #shift
                            #;;
                        # and --flag value opts like this
                        # Anything unknown is recorded for later
                        -h* | --help )
                            HELP=true
                            ;;
                        -d* | --device )
                            DEVICE=$2
                            ;;
                        -f* | --file )
                            FSARCHIVER_FILE=$2
                            ;;
                        -m* | --mount )
                            ROOT_MOUNT=$2
                            ;;
                        * )
                            REMAINS="$REMAINS \"$OPT\""
                            break
                            ;;
                esac
                # Check for multiple short options
                # NOTICE: be sure to update this pattern to match valid options
                NEXTOPT="${OPT#-[hfdlm]}" # try removing single short opt
                if [ x"$OPT" != x"$NEXTOPT" ] ; then
                        OPT="-$NEXTOPT"  # multiple short opts, keep going
                else
                        break  # long form, exit inner loop
                fi
        done
        # Done with that param. move to next
        shift
done
# Set the non-parameters back into the positional parameters ($1 $2 ..)
eval set -- "$REMAINS"

# analyse parameter
if [[ $HELP == true ]] ; then
	showUsage
else
    if [ "$EUID" -ne 0 ]; then
        echo "Restore script needs to be run as root."
        exit 1
    fi

    if [ -z "$DEVICE" ]; then
        echo "No block device given. Use -d to set a block device, e.g. /dev/sdX. See -h for more help."
        exit 1
    fi

    if [ -z "$FSARCHIVER_FILE" ]; then
        echo "No fsarchiver .fsa file given. Use -f to set a the fsa file. See -h for more help."
        exit 1
    fi

    while true; do
        read -p "You want to install to $DEVICE. Is that correct? (y/n)" -r yn
        case $yn in
            [Yy]* ) break;;
            [Nn]* ) echo "Terminating."; exit 0;;
            * ) echo "Please answer yes or no.";;
        esac
    done

    MOUNT_TEST=$(cat /proc/mounts | grep "$DEVICE")
    if [ -n "$MOUNT_TEST" ]
    then
        echo "At least one partition of the selected drive seems to be currently mounted. Cannot continue!"
        exit 1
    fi

    reset

    echo -e "This script will restore the HAT.tec system into a LUKS-encrypted device.\n"\
    "The default password to open the device is \"$DEFAULT_LUKSPASS\".\n"\
    "If you need to change it, enter a new password. Otherwise just leave it blank.\n"\
    "(You could change it inside the running OS later as well...)"

    read -s -p "Enter LUKS-Password ($DEFAULT_LUKSPASS): " LUKSPASS
    LUKSPASS=${LUKSPASS:-${DEFAULT_LUKSPASS}}

    #remove all filesystem headers
    wipefs -af $DEVICE
    #remove all GPT header stuff
    sgdisk -Z $DEVICE
    #create new GPT header
    sgdisk -o $DEVICE
    #create the partitions
    sgdisk -n 1:2048:+200M -t 1:EF00 -c 1:"efi" $DEVICE
    sgdisk -n 2:+0M:+2G -t 2:8300 -c 2:"boot" $DEVICE
    sgdisk -n 3:+0M -t 3:8300 -c 3:"root" $DEVICE

    PARTITION_PREFIX=
    if [[ $DEVICE == "/dev/nvme"* ]]; then
        echo "We are on nvme disk. Using partition prefix (p)."
        PARTITION_PREFIX="p"
    fi

    # Set some shortcuts to the appropriate partitions
    EFI_PARTITION=$DEVICE$PARTITION_PREFIX"1"
    BOOT_PARTITION=$DEVICE$PARTITION_PREFIX"2"
    LUKS_PARTITION=$DEVICE$PARTITION_PREFIX"3"

    # Encrypt the LUKS partition using the provided LUKS key (or use the default value, if none)
    echo "Now creating LUKS encrypted partition. This will take some time."
    echo $LUKSPASS | cryptsetup -q luksFormat $LUKS_PARTITION
    LUKS_UUID=`blkid -s UUID -o value $LUKS_PARTITION`
    LUKS_MAPPERNAME=luks-$LUKS_UUID
    echo "Opening LUKS-encrypted device $LUKS_MAPPERNAME"
    echo $LUKSPASS | cryptsetup luksOpen $LUKS_PARTITION $LUKS_MAPPERNAME

    ROOT_PARTITION=/dev/mapper/$LUKS_MAPPERNAME

    echo "Extracting fsarchiver image from $FSARCHIVER_FILE to $DEVICE..."
    sleep 1
    fsarchiver restfs -j$NUM_OF_PROCS -v -c - $FSARCHIVER_FILE id=0,dest=$EFI_PARTITION id=1,dest=$BOOT_PARTITION id=2,dest=$ROOT_PARTITION

    # Get the UUIDs of the partitions
    # EFI_UUID=`blkid -s UUID -o value $EFI_PARTITION`
    # BOOT_UUID=`blkid -s UUID -o value $BOOT_PARTITION`
    # ROOT_UUID=`blkid -s UUID -o value $ROOT_PARTITION`

    ROOT_MOUNT=${ROOT_MOUNT:-${DEFAULT_ROOT_MOUNT}}

    echo "Now mounting luksroot on $ROOT_MOUNT"
    mount "$ROOT_PARTITION" "$ROOT_MOUNT"

    sleep 1
    echo "Now mounting boot partition on $ROOT_MOUNT/boot"
    mount "$BOOT_PARTITION" "$ROOT_MOUNT"/boot

    sleep 1
    cd /

    echo "Now mounting EFI partition on $ROOT_MOUNT/boot/efi"
    mount "$EFI_PARTITION" "$ROOT_MOUNT"/boot/efi

    echo "Mounting system and proc filesystems..."
    sleep 1
    mount -t proc proc "$ROOT_MOUNT"/proc
    mount -o bind /sys "$ROOT_MOUNT"/sys
    mount -o bind /dev "$ROOT_MOUNT"/dev
    mount -o bind /dev/pts "$ROOT_MOUNT"/dev/pts

    echo "$LUKS_MAPPERNAME UUID=$LUKS_UUID none luks" > $ROOT_MOUNT/etc/crypttab

    echo "update-initramfs -u -k all
    update-grub
    grub-install
    exit" > "$ROOT_MOUNT"/install-update-grub.sh

    chroot "$ROOT_MOUNT" /bin/bash /install-update-grub.sh
    rm -f "$ROOT_MOUNT"/install-update-grub.sh

    umount "$ROOT_MOUNT"/dev/pts
    umount "$ROOT_MOUNT"/dev
    umount "$ROOT_MOUNT"/sys
    umount "$ROOT_MOUNT"/proc

    sleep 1
    umount "$ROOT_MOUNT"/boot/efi
    sleep 1
    umount "$ROOT_MOUNT"/boot
    sleep 1
    umount "$ROOT_MOUNT"
    sleep 1

    cryptsetup luksClose $LUKS_MAPPERNAME

    echo "Restoring of HAT.tec system $FSARCHIVER_FILE to $DEVICE finished."
fi

exit 0
