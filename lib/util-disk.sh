######################################################################
##                                                                  ##
##            System and Partitioning Functions                     ##
##                                                                  ##
######################################################################

# Unmount partitions.
umount_partitions() {
    MOUNTED=""
    MOUNTED=$(mount | grep "${MOUNTPOINT}" | awk '{print $3}' | sort -r)
    swapoff -a

    for i in ${MOUNTED[@]}; do
        umount $i >/dev/null 2>>/tmp/.errlog
    done

   check_for_error
}

# Revised to deal with partion sizes now being displayed to the user
confirm_mount() {
    if [[ $(mount | grep $1) ]]; then
        DIALOG " $_MntStatusTitle " --infobox "$_MntStatusSucc" 0 0
        sleep 2
        PARTITIONS=$(echo $PARTITIONS | sed "s~${PARTITION} [0-9]*[G-M]~~" | sed "s~${PARTITION} [0-9]*\.[0-9]*[G-M]~~" | sed s~${PARTITION}$' -'~~)
        NUMBER_PARTITIONS=$(( NUMBER_PARTITIONS - 1 ))
    else
        DIALOG " $_MntStatusTitle " --infobox "$_MntStatusFail" 0 0
        sleep 2
        prep_menu
    fi
}

# This function does not assume that the formatted device is the Root installation device as
# more than one device may be formatted. Root is set in the mount_partitions function.
select_device() {
    DEVICE=""
    devices_list=$(lsblk -lno NAME,SIZE,TYPE | grep 'disk' | awk '{print "/dev/" $1 " " $2}' | sort -u);

    for i in ${devices_list[@]}; do
        DEVICE="${DEVICE} ${i}"
    done

    DIALOG " $_DevSelTitle " --menu "$_DevSelBody" 0 0 4 ${DEVICE} 2>${ANSWER} || prep_menu
    DEVICE=$(cat ${ANSWER})
}

# Finds all available partitions according to type(s) specified and generates a list
# of them. This also includes partitions on different devices.
find_partitions() {
    PARTITIONS=""
    NUMBER_PARTITIONS=0
    partition_list=$(lsblk -lno NAME,SIZE,TYPE | grep $INCLUDE_PART | sed 's/part$/\/dev\//g' | sed 's/lvm$\|crypt$/\/dev\/mapper\//g' | \
      awk '{print $3$1 " " $2}' | sort -u)

    for i in ${partition_list}; do
        PARTITIONS="${PARTITIONS} ${i}"
        NUMBER_PARTITIONS=$(( NUMBER_PARTITIONS + 1 ))
    done

    # Double-partitions will be counted due to counting sizes, so fix
    NUMBER_PARTITIONS=$(( NUMBER_PARTITIONS / 2 ))

    # Deal with partitioning schemes appropriate to mounting, lvm, and/or luks.
    case $INCLUDE_PART in
        'part\|lvm\|crypt')
            # Deal with incorrect partitioning for main mounting function
            if ([[ $SYSTEM == "UEFI" ]] && [[ $NUMBER_PARTITIONS -lt 2 ]]) || ([[ $SYSTEM == "BIOS" ]] && [[ $NUMBER_PARTITIONS -eq 0 ]]); then
                DIALOG " $_ErrTitle " --msgbox "$_PartErrBody" 0 0
                create_partitions
            fi
            ;;
        'part\|crypt')
            # Ensure there is at least one partition for LVM
            if [[ $NUMBER_PARTITIONS -eq 0 ]]; then
            DIALOG " $_ErrTitle " --msgbox "$_LvmPartErrBody" 0 0
            create_partitions
            fi
            ;;
        'part\|lvm') # Ensure there are at least two partitions for LUKS
            if [[ $NUMBER_PARTITIONS -lt 2 ]]; then
            DIALOG " $_ErrTitle " --msgbox "$_LuksPartErrBody" 0 0
            create_partitions
            fi
            ;;
    esac
}

create_partitions() {
    # Securely destroy all data on a given device.
    secure_wipe() {
        # Warn the user. If they proceed, wipe the selected device.
        DIALOG " $_PartOptWipe " --yesno "$_AutoPartWipeBody1 ${DEVICE} $_AutoPartWipeBody2" 0 0
        if [[ $? -eq 0 ]]; then
            clear

            # Install wipe where not already installed. Much faster than dd
            if [[ ! -e /usr/bin/wipe ]]; then
                pacman -Sy --noconfirm wipe 2>/tmp/.errlog
                check_for_error
            fi

            clear
            wipe -Ifre ${DEVICE}

            # Alternate dd command - requires pv to be installed
            #dd if=/dev/zero | pv | dd of=${DEVICE} iflag=nocache oflag=direct bs=4096 2>/tmp/.errlog
            check_for_error
            else
            create_partitions
            fi
    }

    # BIOS and UEFI
    auto_partition() {
        # Provide warning to user
        DIALOG " $_PrepPartDisk " --yesno "$_AutoPartBody1 $DEVICE $_AutoPartBody2 $_AutoPartBody3" 0 0

        if [[ $? -eq 0 ]]; then
            # Find existing partitions (if any) to remove
            parted -s ${DEVICE} print | awk '/^ / {print $1}' > /tmp/.del_parts

            for del_part in $(tac /tmp/.del_parts); do
                parted -s ${DEVICE} rm ${del_part} 2>/tmp/.errlog
                check_for_error
            done

            # Identify the partition table
            part_table=$(parted -s ${DEVICE} print | grep -i 'partition table' | awk '{print $3}' >/dev/null 2>&1)

            # Create partition table if one does not already exist
            ([[ $SYSTEM == "BIOS" ]] && [[ $part_table != "msdos" ]]) && parted -s ${DEVICE} mklabel msdos 2>/tmp/.errlog
            ([[ $SYSTEM == "UEFI" ]] && [[ $part_table != "gpt" ]]) && parted -s ${DEVICE} mklabel gpt 2>/tmp/.errlog
            check_for_error

            # Create paritions (same basic partitioning scheme for BIOS and UEFI)
            if [[ $SYSTEM == "BIOS" ]]; then
                parted -s ${DEVICE} mkpart primary ext3 1MiB 513MiB 2>/tmp/.errlog
            else
                parted -s ${DEVICE} mkpart ESP fat32 1MiB 513MiB 2>/tmp/.errlog
            fi

            parted -s ${DEVICE} set 1 boot on 2>>/tmp/.errlog
            parted -s ${DEVICE} mkpart primary ext3 513MiB 100% 2>>/tmp/.errlog
            check_for_error

            # Show created partitions
            lsblk ${DEVICE} -o NAME,TYPE,FSTYPE,SIZE > /tmp/.devlist
            DIALOG "" --textbox /tmp/.devlist 0 0
        else
            create_partitions
        fi
    }

    # Partitioning Menu
    DIALOG " $_PrepPartDisk " --menu "$_PartToolBody" 0 0 7 \
      "$_PartOptWipe" "BIOS & UEFI" \
      "$_PartOptAuto" "BIOS & UEFI" \
      "cfdisk" "BIOS" \
      "cgdisk" "UEFI" \
      "fdisk"  "BIOS & UEFI" \
      "gdisk"  "UEFI" \
      "parted" "BIOS & UEFI" 2>${ANSWER}

    clear
    # If something selected
    if [[ $(cat ${ANSWER}) != "" ]]; then
        if ([[ $(cat ${ANSWER}) != "$_PartOptWipe" ]] &&  [[ $(cat ${ANSWER}) != "$_PartOptAuto" ]]); then
            $(cat ${ANSWER}) ${DEVICE}
        else
            [[ $(cat ${ANSWER}) == "$_PartOptWipe" ]] && secure_wipe && create_partitions
        [[ $(cat ${ANSWER}) == "$_PartOptAuto" ]] && auto_partition
    fi
fi

prep_menu
}

# Set static list of filesystems rather than on-the-fly. Partially as most require additional flags, and
# partially because some don't seem to be viable.
# Set static list of filesystems rather than on-the-fly.
select_filesystem() {
    # prep variables
    fs_opts=""
    CHK_NUM=0

    DIALOG " $_FSTitle " --menu "$_FSBody" 0 0 12 \
      "$_FSSkip" "-" \
        "btrfs" "mkfs.btrfs -f" \
        "ext2" "mkfs.ext2 -q" \
        "ext3" "mkfs.ext3 -q" \
        "ext4" "mkfs.ext4 -q" \
        "f2fs" "mkfs.f2fs" \
        "jfs" "mkfs.jfs -q" \
        "nilfs2" "mkfs.nilfs2 -fq" \
        "ntfs" "mkfs.ntfs -q" \
        "reiserfs" "mkfs.reiserfs -q" \
        "vfat" "mkfs.vfat -F32" \
        "xfs" "mkfs.xfs -f" 2>${ANSWER}

    case $(cat ${ANSWER}) in
        "$_FSSkip") FILESYSTEM="$_FSSkip"
            ;;
        "btrfs") FILESYSTEM="mkfs.btrfs -f"
            CHK_NUM=16
            fs_opts="autodefrag compress=zlib compress=lzo compress=no compress-force=zlib compress-force=lzo discard \
            noacl noatime nodatasum nospace_cache recovery skip_balance space_cache ssd ssd_spread"
            modprobe btrfs
            ;;
        "ext2") FILESYSTEM="mkfs.ext2 -q"
            ;;
        "ext3") FILESYSTEM="mkfs.ext3 -q"
            ;;
        "ext4") FILESYSTEM="mkfs.ext4 -q"
            CHK_NUM=8
        fs_opts="data=journal data=writeback dealloc discard noacl noatime nobarrier nodelalloc"
            ;;
        "f2fs") FILESYSTEM="mkfs.f2fs"
            fs_opts="data_flush disable_roll_forward disable_ext_identify discard fastboot flush_merge \
            inline_xattr inline_data inline_dentry no_heap noacl nobarrier noextent_cache noinline_data norecovery"
            CHK_NUM=16
            modprobe f2fs
            ;;
        "jfs") FILESYSTEM="mkfs.jfs -q"
            CHK_NUM=4
            fs_opts="discard errors=continue errors=panic nointegrity"
            ;;
        "nilfs2") FILESYSTEM="mkfs.nilfs2 -fq"
            CHK_NUM=7
            fs_opts="discard nobarrier errors=continue errors=panic order=relaxed order=strict norecovery"
            ;;
        "ntfs") FILESYSTEM="mkfs.ntfs -q"
            ;;
        "reiserfs") FILESYSTEM="mkfs.reiserfs -q"
            CHK_NUM=5
            fs_opts="acl nolog notail replayonly user_xattr"
            ;;
        "vfat") FILESYSTEM="mkfs.vfat -F32"
            ;;
        "xfs") FILESYSTEM="mkfs.xfs -f"
            CHK_NUM=9
            fs_opts="discard filestreams ikeep largeio noalign nobarrier norecovery noquota wsync"
            ;;
        *)  prep_menu 
            ;;
    esac

    # Warn about formatting!
    if [[ $FILESYSTEM != $_FSSkip ]]; then
        DIALOG " $_FSTitle " --yesno "\n$FILESYSTEM $PARTITION\n\n" 0 0
        if [[ $? -eq 0 ]]; then
            ${FILESYSTEM} ${PARTITION} >/dev/null 2>/tmp/.errlog
            check_for_error
        else
            select_filesystem
        fi
    fi
}

mount_partitions() {
    # This subfunction allows for special mounting options to be applied for relevant fs's.
    # Seperate subfunction for neatness.
    mount_opts() {
    FS_OPTS=""
    echo "" > ${MOUNT_OPTS}

    for i in ${fs_opts}; do
      FS_OPTS="${FS_OPTS} ${i} - off"
    done

    DIALOG " $(echo $FILESYSTEM | sed "s/.*\.//g" | sed "s/-.*//g") " --checklist "$_btrfsMntBody" 0 0 $CHK_NUM \
    $FS_OPTS 2>${MOUNT_OPTS}

    # Now clean up the file
    sed -i 's/ /,/g' ${MOUNT_OPTS}
    sed -i '$s/,$//' ${MOUNT_OPTS}

    # If mount options selected, confirm choice
    if [[ $(cat ${MOUNT_OPTS}) != "" ]]; then
        DIALOG " $_MntStatusTitle " --yesno "\n${_btrfsMntConfBody}$(cat ${MOUNT_OPTS})\n" 10 75
        [[ $? -eq 1 ]] && mount_opts
    fi
}

# Subfunction to save repetition of code
mount_current_partition() {
    # Make the mount directory
    mkdir -p ${MOUNTPOINT}${MOUNT} 2>/tmp/.errlog

    # Get mounting options for appropriate filesystems
    [[ $fs_opts != "" ]] && mount_opts

    # Use special mounting options if selected, else standard mount
    if [[ $(cat ${MOUNT_OPTS}) != "" ]]; then
        mount -o $(cat ${MOUNT_OPTS}) ${PARTITION} ${MOUNTPOINT}${MOUNT} 2>>/tmp/.errlog
    else
        mount ${PARTITION} ${MOUNTPOINT}${MOUNT} 2>>/tmp/.errlog
    fi

    check_for_error
    confirm_mount ${MOUNTPOINT}${MOUNT}

    # Identify if mounted partition is type "crypt" (LUKS on LVM, or LUKS alone)
    if [[ $(lsblk -lno TYPE ${PARTITION} | grep "crypt") != "" ]]; then
        # cryptname for bootloader configuration either way
        LUKS=1
        LUKS_NAME=$(echo ${PARTITION} | sed "s~^/dev/mapper/~~g")

        # Check if LUKS on LVM (parent = lvm /dev/mapper/...)
        cryptparts=$(lsblk -lno NAME,FSTYPE,TYPE | grep "lvm" | grep -i "crypto_luks" | uniq | awk '{print "/dev/mapper/"$1}')
        for i in ${cryptparts}; do
            if [[ $(lsblk -lno NAME ${i} | grep $LUKS_NAME) != "" ]]; then
                LUKS_DEV="$LUKS_DEV cryptdevice=${i}:$LUKS_NAME"
                LVM=1
                break;
            fi
        done

        # Check if LUKS alone (parent = part /dev/...)
        cryptparts=$(lsblk -lno NAME,FSTYPE,TYPE | grep "part" | grep -i "crypto_luks" | uniq | awk '{print "/dev/"$1}')
        for i in ${cryptparts}; do
            if [[ $(lsblk -lno NAME ${i} | grep $LUKS_NAME) != "" ]]; then
                LUKS_UUID=$(lsblk -lno UUID,TYPE,FSTYPE ${i} | grep "part" | grep -i "crypto_luks" | awk '{print $1}')
                LUKS_DEV="$LUKS_DEV cryptdevice=UUID=$LUKS_UUID:$LUKS_NAME"
                break;
            fi
        done

        # If LVM logical volume....
    elif [[ $(lsblk -lno TYPE ${PARTITION} | grep "lvm") != "" ]]; then
        LVM=1

        # First get crypt name (code above would get lv name)
        cryptparts=$(lsblk -lno NAME,TYPE,FSTYPE | grep "crypt" | grep -i "lvm2_member" | uniq | awk '{print "/dev/mapper/"$1}')
        for i in ${cryptparts}; do
            if [[ $(lsblk -lno NAME ${i} | grep $(echo $PARTITION | sed "s~^/dev/mapper/~~g")) != "" ]]; then
                LUKS_NAME=$(echo ${i} | sed s~/dev/mapper/~~g)
                break;
            fi
        done

        # Now get the device (/dev/...) for the crypt name
        cryptparts=$(lsblk -lno NAME,FSTYPE,TYPE | grep "part" | grep -i "crypto_luks" | uniq | awk '{print "/dev/"$1}')
        for i in ${cryptparts}; do
            if [[ $(lsblk -lno NAME ${i} | grep $LUKS_NAME) != "" ]]; then
                # Create UUID for comparison
                LUKS_UUID=$(lsblk -lno UUID,TYPE,FSTYPE ${i} | grep "part" | grep -i "crypto_luks" | awk '{print $1}')

                # Check if not already added as a LUKS DEVICE (i.e. multiple LVs on one crypt). If not, add.
                if [[ $(echo $LUKS_DEV | grep $LUKS_UUID) == "" ]]; then
                  LUKS_DEV="$LUKS_DEV cryptdevice=UUID=$LUKS_UUID:$LUKS_NAME"
                  LUKS=1
                fi

                break;
            fi
        done
    fi
}

# Seperate function due to ability to cancel
make_swap() {
    # Ask user to select partition or create swapfile
    DIALOG " $_PrepMntPart " --menu "$_SelSwpBody" 0 0 7 "$_SelSwpNone" $"-" "$_SelSwpFile" $"-" ${PARTITIONS} 2>${ANSWER} || prep_menu

    if [[ $(cat ${ANSWER}) != "$_SelSwpNone" ]]; then
        PARTITION=$(cat ${ANSWER})

        if [[ $PARTITION == "$_SelSwpFile" ]]; then
            total_memory=$(grep MemTotal /proc/meminfo | awk '{print $2/1024}' | sed 's/\..*//')
            DIALOG " $_SelSwpFile " --inputbox "\nM = MB, G = GB\n" 9 30 "${total_memory}M" 2>${ANSWER} || make_swap
            m_or_g=$(cat ${ANSWER})

            while [[ $(echo ${m_or_g: -1} | grep "M\|G") == "" ]]; do
                DIALOG " $_SelSwpFile " --msgbox "\n$_SelSwpFile $_ErrTitle: M = MB, G = GB\n\n" 0 0
                DIALOG " $_SelSwpFile " --inputbox "\nM = MB, G = GB\n" 9 30 "${total_memory}M" 2>${ANSWER} || make_swap
                m_or_g=$(cat ${ANSWER})
            done

          fallocate -l ${m_or_g} ${MOUNTPOINT}/swapfile 2>/tmp/.errlog
          chmod 600 ${MOUNTPOINT}/swapfile 2>>/tmp/.errlog
          mkswap ${MOUNTPOINT}/swapfile 2>>/tmp/.errlog
          swapon ${MOUNTPOINT}/swapfile 2>>/tmp/.errlog
          check_for_error

        else # Swap Partition
            # Warn user if creating a new swap
            if [[ $(lsblk -o FSTYPE  ${PARTITION} | grep -i "swap") != "swap" ]]; then
                DIALOG " $_PrepMntPart " --yesno "\nmkswap ${PARTITION}\n\n" 0 0
                [[ $? -eq 0 ]] && mkswap ${PARTITION} >/dev/null 2>/tmp/.errlog || mount_partitions
            fi
            # Whether existing to newly created, activate swap
            swapon  ${PARTITION} >/dev/null 2>>/tmp/.errlog
            check_for_error
            # Since a partition was used, remove that partition from the list
            PARTITIONS=$(echo $PARTITIONS | sed "s~${PARTITION} [0-9]*[G-M]~~" | sed "s~${PARTITION} [0-9]*\.[0-9]*[G-M]~~" | sed s~${PARTITION}$' -'~~)
            NUMBER_PARTITIONS=$(( NUMBER_PARTITIONS - 1 ))
        fi
    fi
}

####                ####
#### MOUNTING FUNCTION BEGINS HERE  ####
####                ####

# prep variables
MOUNT=""
LUKS_NAME=""
LUKS_DEV=""
LUKS_UUID=""
LUKS=0
LVM=0
BTRFS=0

# Warn users that they CAN mount partitions without formatting them!
DIALOG " $_PrepMntPart " --msgbox "$_WarnMount1 '$_FSSkip' $_WarnMount2" 0 0

# LVM Detection. If detected, activate.
lvm_detect

# Ensure partitions are unmounted (i.e. where mounted previously), and then list available partitions
INCLUDE_PART='part\|lvm\|crypt'
umount_partitions
find_partitions

# Identify and mount root
DIALOG " $_PrepMntPart " --menu "$_SelRootBody" 0 0 7 ${PARTITIONS} 2>${ANSWER} || prep_menu
PARTITION=$(cat ${ANSWER})
ROOT_PART=${PARTITION}

# Format with FS (or skip)
select_filesystem

# Make the directory and mount. Also identify LUKS and/or LVM
mount_current_partition

# Identify and create swap, if applicable
make_swap

# Extra Step for VFAT UEFI Partition. This cannot be in an LVM container.
if [[ $SYSTEM == "UEFI" ]]; then
    DIALOG " $_PrepMntPart " --menu "$_SelUefiBody" 0 0 7 ${PARTITIONS} 2>${ANSWER} || prep_menu
    PARTITION=$(cat ${ANSWER})
    UEFI_PART=${PARTITION}

    # If it is already a fat/vfat partition...
    if [[ $(fsck -N $PARTITION | grep fat) ]]; then
        DIALOG " $_PrepMntPart " --yesno "$_FormUefiBody $PARTITION $_FormUefiBody2" 0 0 && mkfs.vfat -F32 ${PARTITION} >/dev/null 2>/tmp/.errlog
    else
        mkfs.vfat -F32 ${PARTITION} >/dev/null 2>/tmp/.errlog
    fi
    check_for_error

    # Inform users of the mountpoint options and consequences
    DIALOG " $_PrepMntPart " --menu "$_MntUefiBody"  0 0 2 \
      "/boot" "systemd-boot"\
     "/boot/efi" "-" 2>${ANSWER}

    [[ $(cat ${ANSWER}) != "" ]] && UEFI_MOUNT=$(cat ${ANSWER}) || prep_menu

    mkdir -p ${MOUNTPOINT}${UEFI_MOUNT} 2>/tmp/.errlog
    mount ${PARTITION} ${MOUNTPOINT}${UEFI_MOUNT} 2>>/tmp/.errlog
    check_for_error
    confirm_mount ${MOUNTPOINT}${UEFI_MOUNT}
fi

    # All other partitions
    while [[ $NUMBER_PARTITIONS > 0 ]]; do
        DIALOG " $_PrepMntPart " --menu "$_ExtPartBody" 0 0 7 "$_Done" $"-" ${PARTITIONS} 2>${ANSWER} || prep_menu
        PARTITION=$(cat ${ANSWER})

        if [[ $PARTITION == $_Done ]]; then
            break;
        else
            MOUNT=""
            select_filesystem

            # Ask user for mountpoint. Don't give /boot as an example for UEFI systems!
            [[ $SYSTEM == "UEFI" ]] && MNT_EXAMPLES="/home\n/var" || MNT_EXAMPLES="/boot\n/home\n/var"
            DIALOG " $_PrepMntPart $PARTITON " --inputbox "$_ExtPartBody1$MNT_EXAMPLES\n" 0 0 "/" 2>${ANSWER} || prep_menu
            MOUNT=$(cat ${ANSWER})

            # loop while the mountpoint specified is incorrect (is only '/', is blank, or has spaces).
            while [[ ${MOUNT:0:1} != "/" ]] || [[ ${#MOUNT} -le 1 ]] || [[ $MOUNT =~ \ |\' ]]; do
              # Warn user about naming convention
              DIALOG " $_ErrTitle " --msgbox "$_ExtErrBody" 0 0
              # Ask user for mountpoint again
              DIALOG " $_PrepMntPart $PARTITON " --inputbox "$_ExtPartBody1$MNT_EXAMPLES\n" 0 0 "/" 2>${ANSWER} || prep_menu
              MOUNT=$(cat ${ANSWER})
            done

            # Create directory and mount.
            mount_current_partition

            # Determine if a seperate /boot is used. 0 = no seperate boot, 1 = seperate non-lvm boot,
            # 2 = seperate lvm boot. For Grub configuration
            if  [[ $MOUNT == "/boot" ]]; then
              [[ $(lsblk -lno TYPE ${PARTITION} | grep "lvm") != "" ]] && LVM_SEP_BOOT=2 || LVM_SEP_BOOT=1
            fi

        fi
    done
}


######################################################################
##                                                                  ##
##             Encryption (dm_crypt) Functions                      ##
##                                                                  ##
######################################################################

# Had to write it in this way due to (bash?) bug(?), as if/then statements in a single
# "create LUKS" function for default and "advanced" modes were interpreted as commands,
# not mere string statements. Not happy with it, but it works...

# Save repetition of code.
luks_password() {
    DIALOG " $_PrepLUKS " --clear --insecure --passwordbox "$_LuksPassBody" 0 0 2> ${ANSWER} || prep_menu
    PASSWD=$(cat ${ANSWER})

    DIALOG " $_PrepLUKS " --clear --insecure --passwordbox "$_PassReEntBody" 0 0 2> ${ANSWER} || prep_menu
    PASSWD2=$(cat ${ANSWER})

    if [[ $PASSWD != $PASSWD2 ]]; then
        DIALOG " $_ErrTitle " --msgbox "$_PassErrBody" 0 0
        luks_password
    fi
}

luks_open() {
    LUKS_ROOT_NAME=""
    INCLUDE_PART='part\|crypt\|lvm'
    umount_partitions
    find_partitions

    # Select encrypted partition to open
    DIALOG " $_LuksOpen " --menu "$_LuksMenuBody" 0 0 7 ${PARTITIONS} 2>${ANSWER} || luks_menu
    PARTITION=$(cat ${ANSWER})

    # Enter name of the Luks partition and get password to open it
    DIALOG " $_LuksOpen " --inputbox "$_LuksOpenBody" 10 50 "cryptroot" 2>${ANSWER} || luks_menu
    LUKS_ROOT_NAME=$(cat ${ANSWER})
    luks_password

    # Try to open the luks partition with the credentials given. If successful show this, otherwise
    # show the error
    DIALOG " $_LuksOpen " --infobox "$_PlsWaitBody" 0 0
    echo $PASSWD | cryptsetup open --type luks ${PARTITION} ${LUKS_ROOT_NAME} 2>/tmp/.errlog
    check_for_error

  l sblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINT ${PARTITION} | grep "crypt\|NAME\|MODEL\|TYPE\|FSTYPE\|SIZE" > /tmp/.devlist
    DIALOG " $_DevShowOpt " --textbox /tmp/.devlist 0 0

    luks_menu
}

luks_setup() {
    modprobe -a dm-mod dm_crypt
    INCLUDE_PART='part\|lvm'
    umount_partitions
    find_partitions

    # Select partition to encrypt
    DIALOG " $_LuksEncrypt " --menu "$_LuksCreateBody" 0 0 7 ${PARTITIONS} 2>${ANSWER} || luks_menu
    PARTITION=$(cat ${ANSWER})

    # Enter name of the Luks partition and get password to create it
    DIALOG " $_LuksEncrypt " --inputbox "$_LuksOpenBody" 10 50 "cryptroot" 2>${ANSWER} || luks_menu
    LUKS_ROOT_NAME=$(cat ${ANSWER})
    luks_password
}

luks_default() {
    # Encrypt selected partition or LV with credentials given
    DIALOG " $_LuksEncrypt " --infobox "$_PlsWaitBody" 0 0
    sleep 2
    echo $PASSWD | cryptsetup -q luksFormat ${PARTITION} 2>/tmp/.errlog

    # Now open the encrypted partition or LV
    echo $PASSWD | cryptsetup open ${PARTITION} ${LUKS_ROOT_NAME} 2>/tmp/.errlog
    check_for_error
}

luks_key_define() {
    DIALOG " $_PrepLUKS " --inputbox "$_LuksCipherKey" 0 0 "-s 512 -c aes-xts-plain64" 2>${ANSWER} || luks_menu

    # Encrypt selected partition or LV with credentials given
    DIALOG " $_LuksEncryptAdv " --infobox "$_PlsWaitBody" 0 0
    sleep 2

    echo $PASSWD | cryptsetup -q $(cat ${ANSWER}) luksFormat ${PARTITION} 2>/tmp/.errlog
    check_for_error

    # Now open the encrypted partition or LV
    echo $PASSWD | cryptsetup open ${PARTITION} ${LUKS_ROOT_NAME} 2>/tmp/.errlog
    check_for_error
}

luks_show() {
    echo -e ${_LuksEncruptSucc} > /tmp/.devlist
    lsblk -o NAME,TYPE,FSTYPE,SIZE ${PARTITION} | grep "part\|crypt\|NAME\|TYPE\|FSTYPE\|SIZE" >> /tmp/.devlist
    DIALOG " $_LuksEncrypt " --textbox /tmp/.devlist 0 0

    luks_menu
}

luks_menu() {
    LUKS_OPT=""

    DIALOG " $_PrepLUKS " --menu "$_LuksMenuBody$_LuksMenuBody2$_LuksMenuBody3" 0 0 4 \
    "$_LuksOpen" "cryptsetup open --type luks" \
    "$_LuksEncrypt" "cryptsetup -q luksFormat" \
    "$_LuksEncryptAdv" "cryptsetup -q -s -c luksFormat" \
    "$_Back" "-" 2>${ANSWER}

    case $(cat ${ANSWER}) in
        "$_LuksOpen") luks_open
            ;;
        "$_LuksEncrypt")  luks_setup
                luks_default
                luks_show
            ;;
        "$_LuksEncryptAdv") luks_setup
            luks_key_define
            luks_show
            ;;
        *) prep_menu
            ;;
    esac

    luks_menu
}


######################################################################
##                                                                  ##
##             Logical Volume Management Functions                  ##
##                                                                  ##
######################################################################

# LVM Detection.
lvm_detect() {
    LVM_PV=$(pvs -o pv_name --noheading 2>/dev/null)
    LVM_VG=$(vgs -o vg_name --noheading 2>/dev/null)
    LVM_LV=$(lvs -o vg_name,lv_name --noheading --separator - 2>/dev/null)

    if [[ $LVM_LV != "" ]] && [[ $LVM_VG != "" ]] && [[ $LVM_PV != "" ]]; then
        DIALOG " $_PrepLVM " --infobox "$_LvmDetBody" 0 0
        modprobe dm-mod 2>/tmp/.errlog
        check_for_error
        vgscan >/dev/null 2>&1
        vgchange -ay >/dev/null 2>&1
    fi
}

lvm_show_vg() {
    VG_LIST=""
    vg_list=$(lvs --noheadings | awk '{print $2}' | uniq)

    for i in ${vg_list}; do
        VG_LIST="${VG_LIST} ${i} $(vgdisplay ${i} | grep -i "vg size" | awk '{print $3$4}')"
    done

    # If no VGs, no point in continuing
    if [[ $VG_LIST == "" ]]; then
        DIALOG " $_ErrTitle " --msgbox "$_LvmVGErr" 0 0
        lvm_menu
    fi

    # Select VG
    DIALOG " $_PrepLVM " --menu "$_LvmSelVGBody" 0 0 5 \
    ${VG_LIST} 2>${ANSWER} || lvm_menu
}

# Create Volume Group and Logical Volumes
lvm_create() {
    # subroutine to save a lot of repetition.
    check_lv_size() {
        LV_SIZE_INVALID=0
        chars=0

        # Check to see if anything was actually entered and if first character is '0'
        ([[ ${#LVM_LV_SIZE} -eq 0 ]] || [[ ${LVM_LV_SIZE:0:1} -eq "0" ]]) && LV_SIZE_INVALID=1

        # If not invalid so far, check for non numberic characters other than the last character
        if [[ $LV_SIZE_INVALID -eq 0 ]]; then
            while [[ $chars -lt $(( ${#LVM_LV_SIZE} - 1 )) ]]; do
                [[ ${LVM_LV_SIZE:chars:1} != [0-9] ]] && LV_SIZE_INVALID=1 && break;
                chars=$(( chars + 1 ))
            done
        fi

        # If not invalid so far, check that last character is a M/m or G/g
        if [[ $LV_SIZE_INVALID -eq 0 ]]; then
            LV_SIZE_TYPE=$(echo ${LVM_LV_SIZE:$(( ${#LVM_LV_SIZE} - 1 )):1})

            case $LV_SIZE_TYPE in
                "m"|"M"|"g"|"G") LV_SIZE_INVALID=0 ;;
                *) LV_SIZE_INVALID=1 ;;
            esac

        fi

        # If not invalid so far, check whether the value is greater than or equal to the LV remaining Size.
        # If not, convert into MB for VG space remaining.
        if [[ ${LV_SIZE_INVALID} -eq 0 ]]; then
            case ${LV_SIZE_TYPE} in
                "G"|"g")
                    if [[ $(( $(echo ${LVM_LV_SIZE:0:$(( ${#LVM_LV_SIZE} - 1 ))}) * 1000 )) -ge ${LVM_VG_MB} ]]; then
                        LV_SIZE_INVALID=1
                    else
                        LVM_VG_MB=$(( LVM_VG_MB - $(( $(echo ${LVM_LV_SIZE:0:$(( ${#LVM_LV_SIZE} - 1 ))}) * 1000 )) ))
                    fi
                    ;;
                "M"|"m")
                    if [[ $(echo ${LVM_LV_SIZE:0:$(( ${#LVM_LV_SIZE} - 1 ))}) -ge ${LVM_VG_MB} ]]; then
                        LV_SIZE_INVALID=1
                    else
                        LVM_VG_MB=$(( LVM_VG_MB - $(echo ${LVM_LV_SIZE:0:$(( ${#LVM_LV_SIZE} - 1 ))}) ))
                    fi
                    ;;
                *) LV_SIZE_INVALID=1
                    ;;
            esac

        fi
    }

    #             #
    # LVM Create Starts Here  #
    #             #

    # Prep Variables
    LVM_VG=""
    VG_PARTS=""
    LVM_VG_MB=0

    # Find LVM appropriate partitions.
    INCLUDE_PART='part\|crypt'
    umount_partitions
    find_partitions
    # Amend partition(s) found for use in check list
    PARTITIONS=$(echo $PARTITIONS | sed 's/M\|G\|T/& off/g')

    # Name the Volume Group
    DIALOG " $_LvmCreateVG " --inputbox "$_LvmNameVgBody" 0 0 "" 2>${ANSWER} || prep_menu
    LVM_VG=$(cat ${ANSWER})

    # Loop while the Volume Group name starts with a "/", is blank, has spaces, or is already being used
    while [[ ${LVM_VG:0:1} == "/" ]] || [[ ${#LVM_VG} -eq 0 ]] || [[ $LVM_VG =~ \ |\' ]] || [[ $(lsblk | grep ${LVM_VG}) != "" ]]; do
        DIALOG "$_ErrTitle" --msgbox "$_LvmNameVgErr" 0 0
        DIALOG " $_LvmCreateVG " --inputbox "$_LvmNameVgBody" 0 0 "" 2>${ANSWER} || prep_menu
        LVM_VG=$(cat ${ANSWER})
    done

    # Select the partition(s) for the Volume Group
    DIALOG " $_LvmCreateVG " --checklist "$_LvmPvSelBody $_UseSpaceBar" 0 0 7 ${PARTITIONS} 2>${ANSWER} || prep_menu
    [[ $(cat ${ANSWER}) != "" ]] && VG_PARTS=$(cat ${ANSWER}) || prep_menu

    # Once all the partitions have been selected, show user. On confirmation, use it/them in 'vgcreate' command.
    # Also determine the size of the VG, to use for creating LVs for it.
    DIALOG " $_LvmCreateVG " --yesno "$_LvmPvConfBody1${LVM_VG} $_LvmPvConfBody2${VG_PARTS}" 0 0

    if [[ $? -eq 0 ]]; then
        DIALOG " $_LvmCreateVG " --infobox "$_LvmPvActBody1${LVM_VG}.$_PlsWaitBody" 0 0
        sleep 1
        vgcreate -f ${LVM_VG} ${VG_PARTS} >/dev/null 2>/tmp/.errlog
        check_for_error

        # Once created, get size and size type for display and later number-crunching for lv creation
        VG_SIZE=$(vgdisplay $LVM_VG | grep 'VG Size' | awk '{print $3}' | sed 's/\..*//')
        VG_SIZE_TYPE=$(vgdisplay $LVM_VG | grep 'VG Size' | awk '{print $4}')

        # Convert the VG size into GB and MB. These variables are used to keep tabs on space available and remaining
        [[ ${VG_SIZE_TYPE:0:1} == "G" ]] && LVM_VG_MB=$(( VG_SIZE * 1000 )) || LVM_VG_MB=$VG_SIZE

        DIALOG " $_LvmCreateVG " --msgbox "$_LvmPvDoneBody1 '${LVM_VG}' $_LvmPvDoneBody2 (${VG_SIZE} ${VG_SIZE_TYPE}).\n\n" 0 0
    else
        lvm_menu
    fi

    #
    # Once VG created, create Logical Volumes
    #

    # Specify number of Logical volumes to create.
    DIALOG " $_LvmCreateVG " --radiolist "$_LvmLvNumBody1 ${LVM_VG}. $_LvmLvNumBody2" 0 0 9 \
      "1" "-" off "2" "-" off "3" "-" off "4" "-" off "5" "-" off "6" "-" off "7" "-" off "8" "-" off "9" "-" off 2>${ANSWER}

    [[ $(cat ${ANSWER}) == "" ]] && lvm_menu || NUMBER_LOGICAL_VOLUMES=$(cat ${ANSWER})

    # Loop while the number of LVs is greater than 1. This is because the size of the last LV is automatic.
    while [[ $NUMBER_LOGICAL_VOLUMES -gt 1 ]]; do
        DIALOG " $_LvmCreateVG (LV:$NUMBER_LOGICAL_VOLUMES) " --inputbox "$_LvmLvNameBody1" 0 0 "lvol" 2>${ANSWER} || prep_menu
        LVM_LV_NAME=$(cat ${ANSWER})

        # Loop if preceeded with a "/", if nothing is entered, if there is a space, or if that name already exists.
        while [[ ${LVM_LV_NAME:0:1} == "/" ]] || [[ ${#LVM_LV_NAME} -eq 0 ]] || [[ ${LVM_LV_NAME} =~ \ |\' ]] || [[ $(lsblk | grep ${LVM_LV_NAME}) != "" ]]; do
            DIALOG " $_ErrTitle " --msgbox "$_LvmLvNameErrBody" 0 0
            DIALOG " $_LvmCreateVG (LV:$NUMBER_LOGICAL_VOLUMES) " --inputbox "$_LvmLvNameBody1" 0 0 "lvol" 2>${ANSWER} || prep_menu
            LVM_LV_NAME=$(cat ${ANSWER})
        done

        DIALOG " $_LvmCreateVG (LV:$NUMBER_LOGICAL_VOLUMES) " --inputbox "\n${LVM_VG}: ${VG_SIZE}${VG_SIZE_TYPE} (${LVM_VG_MB}MB \
          $_LvmLvSizeBody1).$_LvmLvSizeBody2" 0 0 "" 2>${ANSWER} || prep_menu
        LVM_LV_SIZE=$(cat ${ANSWER})
        check_lv_size

        # Loop while an invalid value is entered.
        while [[ $LV_SIZE_INVALID -eq 1 ]]; do
            DIALOG " $_ErrTitle " --msgbox "$_LvmLvSizeErrBody" 0 0
            DIALOG " $_LvmCreateVG (LV:$NUMBER_LOGICAL_VOLUMES) " --inputbox "\n${LVM_VG}: ${VG_SIZE}${VG_SIZE_TYPE} \
              (${LVM_VG_MB}MB $_LvmLvSizeBody1).$_LvmLvSizeBody2" 0 0 "" 2>${ANSWER} || prep_menu
            LVM_LV_SIZE=$(cat ${ANSWER})
            check_lv_size
        done

        # Create the LV
        lvcreate -L ${LVM_LV_SIZE} ${LVM_VG} -n ${LVM_LV_NAME} 2>/tmp/.errlog
        check_for_error
        DIALOG " $_LvmCreateVG (LV:$NUMBER_LOGICAL_VOLUMES) " --msgbox "\n$_Done\n\nLV ${LVM_LV_NAME} (${LVM_LV_SIZE}) $_LvmPvDoneBody2.\n\n" 0 0
        NUMBER_LOGICAL_VOLUMES=$(( NUMBER_LOGICAL_VOLUMES - 1 ))
    done

    # Now the final LV. Size is automatic.
    DIALOG " $_LvmCreateVG (LV:$NUMBER_LOGICAL_VOLUMES) " --inputbox "$_LvmLvNameBody1 $_LvmLvNameBody2 (${LVM_VG_MB}MB)." 0 0 "lvol" 2>${ANSWER} || prep_menu
    LVM_LV_NAME=$(cat ${ANSWER})
     
    # Loop if preceeded with a "/", if nothing is entered, if there is a space, or if that name already exists.
    while [[ ${LVM_LV_NAME:0:1} == "/" ]] || [[ ${#LVM_LV_NAME} -eq 0 ]] || [[ ${LVM_LV_NAME} =~ \ |\' ]] || [[ $(lsblk | grep ${LVM_LV_NAME}) != "" ]]; do
        DIALOG " $_ErrTitle " --msgbox "$_LvmLvNameErrBody" 0 0
        DIALOG " $_LvmCreateVG (LV:$NUMBER_LOGICAL_VOLUMES) " --inputbox "$_LvmLvNameBody1 $_LvmLvNameBody2 (${LVM_VG_MB}MB)." 0 0 "lvol" 2>${ANSWER} || prep_menu
        LVM_LV_NAME=$(cat ${ANSWER})
    done

    # Create the final LV
    lvcreate -l +100%FREE ${LVM_VG} -n ${LVM_LV_NAME} 2>/tmp/.errlog
    check_for_error
    NUMBER_LOGICAL_VOLUMES=$(( NUMBER_LOGICAL_VOLUMES - 1 ))
    LVM=1
    DIALOG " $_LvmCreateVG " --yesno "$_LvmCompBody" 0 0 && show_devices || lvm_menu
}

lvm_del_vg() {
    # Generate list of VGs for selection
    lvm_show_vg

    # Ask for confirmation
    DIALOG " $_LvmDelVG " --yesno "$_LvmDelQ" 0 0

    # if confirmation given, delete
    if [[ $? -eq 0 ]]; then
        vgremove -f $(cat ${ANSWER}) >/dev/null 2>&1
    fi

    lvm_menu
}

lvm_del_all() {
    LVM_PV=$(pvs -o pv_name --noheading 2>/dev/null)
    LVM_VG=$(vgs -o vg_name --noheading 2>/dev/null)
    LVM_LV=$(lvs -o vg_name,lv_name --noheading --separator - 2>/dev/null)

    # Ask for confirmation
    DIALOG " $_LvmDelLV " --yesno "$_LvmDelQ" 0 0

    # if confirmation given, delete
    if [[ $? -eq 0 ]]; then
        for i in ${LVM_LV}; do
            lvremove -f /dev/mapper/${i} >/dev/null 2>&1
        done

        for i in ${LVM_VG}; do
            vgremove -f ${i} >/dev/null 2>&1
        done

        for i in ${LV_PV}; do
            pvremove -f ${i} >/dev/null 2>&1
        done
    fi

    lvm_menu
}

lvm_menu() {
    DIALOG " $_PrepLVM $_PrepLVM2 " --infobox "$_PlsWaitBody" 0 0
    sleep 1
    lvm_detect

    DIALOG " $_PrepLVM $_PrepLVM2 " --menu "$_LvmMenu" 0 0 4 \
      "$_LvmCreateVG" "vgcreate -f, lvcreate -L -n" \
      "$_LvmDelVG" "vgremove -f" \
      "$_LvMDelAll" "lvrmeove, vgremove, pvremove -f" \
      "$_Back" "-" 2>${ANSWER}

    case $(cat ${ANSWER}) in
        "$_LvmCreateVG") lvm_create ;;
        "$_LvmDelVG") lvm_del_vg ;;
        "$_LvMDelAll") lvm_del_all ;;
        *) prep_menu ;;
    esac
}