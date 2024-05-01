#!/usr/bin/env bash
# shellcheck disable=1090

CWD="$(pwd)"
SCRIPT_NAME="$(basename "${0}")"
LOG_FILE="${CWD}/${SCRIPT_NAME}.log"
PASSED_ENV_VARS="${CWD}/.${SCRIPT_NAME}.env"
FUNCTIONS="${CWD}/functions/functions.sh"
CORE_PACKAGES="${CWD}/packages/core-packages.csv"

# Logging the entire script and also outputing to terminal
exec 3>&1 4>&2 > >(tee --append "${LOG_FILE}") 2>&1


# Sourcing log functions
# you need to be in functions directory for this sourcing to work
pushd functions || exit 1
if ! source "${FUNCTIONS}"; then
    echo "Error! Could not source ${FUNCTIONS}"
    exit 1
fi
popd || exit 1

if [ -f "${PASSED_ENV_VARS}" ]; then
    source "${PASSED_ENV_VARS}"
    log_info "Sourced variables from last installation"
fi

function usage() {
    cat << EOF

Usage: ./${SCRIPT_NAME} [OPTIONS [ARGS]]

DESCRIPTION:
    This is a bash script used for installing Arch Linux.
    Configure config/installation_config.conf for configuring the installation.

OPTIONS:
    -h, --help
        Show this help message

    -l, --list
        List available disks

    -c, --clean
        Clean the environment for a fresh usage of the script

    -d, --disk DISK
        Provide disk for installation
        Example:
        ./${SCRIPT_NAME} --disk sda

EOF
}

# Check for internet
function check_internet() {
    log_info "Check Internet"
	if ! ping -c1 -w1 8.8.8.8 > /dev/null 2>&1; then
        log_info "Visit https://wiki.arch.org/wiki/Handbook:AMD64/Installation/Networking"
        log_error "No Internet Connection" && exit 1
	fi

    log_ok "Connected to internet"
}

# Initializing keys and setting pacman
function configuring_pacman(){
    log_info "Configuring pacman"

    CORES="$(nproc)"
    if [ $CORES -gt 1 ]; then
        ((CORES -= 1))
    fi

    CONF_FILE="/etc/pacman.conf"

    log_info "Configuring pacman to use up to ${CORES} parallel downloads"
    sed --regexp-extended --in-place "s|^#ParallelDownloads.*|ParallelDownloads = ${CORES}|g" "${CONF_FILE}" 

    log_info "Refreshing sources"
	exit_on_error pacman --noconfirm --sync --refresh

    log_info "Installing the keyring"
	exit_on_error pacman --noconfirm --sync --refresh archlinux-keyring

    echo PASSED_CONFIGURING_PACMAN="PASSED" >> "${PASSED_ENV_VARS}"
    log_ok "DONE"
}

# Selecting the disk to install on
function disks() {
    log_info "Select installation disk"

    DISK="$(lsblk --nodeps --noheadings --exclude 7 --output NAME,SIZE | sort --key=2 | awk '{print $1; exit}')"
    ANSWER=""

    log_warning "From this point there is no going back! Proceed with caution."
    log_info "Available disks:"
    lsblk --nodeps --noheadings --exclude 7 --output NAME,SIZE

    log_info "Disk chosen: ${DISK}"

    # Allow user to read
    sleep 3

    while [[ "${ANSWER}" != 'yes' && "${ANSWER}" != 'no' ]]; do
        printf "Select disk for installation (yes/no): "
        read -r ANSWER
    done

    if [[ "${ANSWER}" == 'no' ]]; then
        log_error "Please pass the installation disk with the argument -d, --disk DISK"
        usage
        exit 1
    fi

    # 40 GiB
    MIN_DISK_SIZE=42949672960
    DISK_SIZE=$(lsblk --bytes --nodeps --noheadings --output SIZE "/dev/${DISK}")

    # shellcheck disable=2086
    if ! [ ${DISK_SIZE} -ge ${MIN_DISK_SIZE} ]; then
        log_error "Disk ${DISK} should be at least 40GiB."
        exit 1
    fi
    
    log_ok "DONE"
}

# Creating partitions
function partitioning() {
    log_info "Partitioning disk"

    log_info "Wiping the data on disk ${DISK}"
    exit_on_error wipefs --all "/dev/${DISK}"

    if [[ -n $(ls /sys/firmware/efi/efivars 2>/dev/null) ]];then
        MODE="UEFI"
        # Make a GPT partitioning type - compatible with UEFI
        exit_on_error parted --script "/dev/${DISK}" mklabel gpt && \
            parted --script "/dev/${DISK}" mkpart fat32 2048s 1GiB && \
            parted --script "/dev/${DISK}" set 1 esp on && \
            parted --script "/dev/${DISK}" mkpart linux-swap 1GiB 5GiB && \
            parted --script "/dev/${DISK}" mkpart ext4 5GiB 35GiB && \
            parted --script "/dev/${DISK}" mkpart ext4 35GiB 100% && \
            parted --script "/dev/${DISK}" align-check optimal 1 
    else
        MODE="BIOS"
        # Make a MBR partitioning type - compatible with BIOS
        exit_on_error parted --script "/dev/${DISK}" mklabel msdos && \
            parted --script "/dev/${DISK}" mkpart primary ext4 2048s 35GiB && \
            parted --script "/dev/${DISK}" mkpart primary linux-swap 35GiB 39GiB && \
            parted --script "/dev/${DISK}" mkpart primary ext4 39GiB 100% && \
            parted --script "/dev/${DISK}" align-check optimal 1 
    fi

    log_ok "DONE"
}

# Formatting partitions
function formatting() {
    log_info "Formatting partitions"

    PARTITIONS="$(blkid --output device | grep "${DISK}" | sort)"

    if [[ "${MODE}" = "UEFI" ]]; then
        BOOT_P="$(echo "${PARTITIONS}" | sed -n '1p')"
        exit_on_error mkfs.vfat -F32 "${BOOT_P}"

        SWAP_P="$(echo "${PARTITIONS}" | sed -n '2p')"
        ROOT_P="$(echo "${PARTITIONS}" | sed -n '3p')"
        HOME_P="$(echo "${PARTITIONS}" | sed -n '4p')"
    elif [[ "${MODE}" = "BIOS" ]]; then 
        ROOT_P=$(echo "${PARTITIONS}" | sed -n '1p')
        SWAP_P=$(echo "${PARTITIONS}" | sed -n '2p')
        HOME_P=$(echo "${PARTITIONS}" | sed -n '3p')
    fi

    exit_on_error mkswap "${SWAP_P}" && \
        swapon "${SWAP_P}" && \
        mkfs.ext4 -F "${HOME_P}" && \
        mkfs.ext4 -F "${ROOT_P}"

    echo PASSED_FORMATTING="PASSED" >> "${PASSED_ENV_VARS}"
    echo SWAP_P="${SWAP_P}" >> "${PASSED_ENV_VARS}"
    log_ok "DONE"
}

# Mounting partitons
function mounting() {
    log_info "Mounting partitions"

    exit_on_error mkdir --parents /mnt && \
        mount "${ROOT_P}" /mnt && \
        mkdir --parents /mnt/home && \
        mount "${HOME_P}" /mnt/home

    [[ "${MODE}" = "UEFI" ]] && \
        exit_on_error mkdir --parents /mnt/boot && \
            mount "${BOOT_P}" /mnt/boot

    echo PASSED_MOUNTING="PASSED" >> "${PASSED_ENV_VARS}"
    log_ok "DONE"
}

# Installing packages
function install_core_packages(){
    log_info "Installing core packages on the new system"

    # shellcheck disable=SC2046
	exit_on_error pacstrap -K /mnt $(awk -F ',' '{printf "%s ", $1}' "${CORE_PACKAGES}")

    echo PASSED_INSTALL_CORE_PACKAGES="PASSED" >> "${PASSED_ENV_VARS}"
    log_ok "DONE"
}

# Generating fstab
function generate_fstab(){
    log_info "Generating fstab"

    exit_on_error genfstab -U /mnt >> /mnt/etc/fstab

    echo PASSED_GENERATE_FSTAB="PASSED" >> "${PASSED_ENV_VARS}"
    log_ok "DONE"
}

# Enter the new environment
function enter_environment() {
    log_info "Copying all information to installation disk"

    TEMP_DIR="temp_install_dir"
    mkdir --parents "/mnt/${TEMP_DIR}"

    log_info "Copying all scripts to new environment"
    exit_on_error cp --archive "${CWD}/*" "/mnt/${TEMP_DIR}/"

    log_info "(STAGE 2) Entering new environment"
    exec 1>&3 2>&4

    # shellcheck disable=SC2016
    exit_on_error arch-chroot /mnt /bin/bash "${TEMP_DIR}/stage2_installation.sh" "${MODE}" "${DISK}"
}

# MAIN
function main() {
    log_info "(STAGE 1) Preparing the new installation"
    touch "${PASSED_ENV_VARS}"
	check_internet
    # Check if variable DISK is set or not: https://stackoverflow.com/questions/3601515/how-to-check-if-a-variable-is-set-in-bash
	[ -z "${PASSED_CONFIGURING_PACMAN+x}" ] && configuring_pacman
	[ -z "${DISK+x}" ] && disks
    partitioning
    [ -z "${PASSED_FORMATTING+x}" ] && formatting
    [ -z "${PASSED_MOUNTING+x}" ] && mounting
    [ -z "${PASSED_INSTALL_CORE_PACKAGES+x}" ] && install_core_packages
    [ -z "${PASSED_GENERATE_FSTAB+x}" ] && generate_fstab
    enter_environment

    log_info "Take out the USB stick after rebooting is finished"
    log_info "Or opt to boot from the hard disk"
    log_info "Rebooting"
    sleep 5
    reboot
}

# Gather options
while [[ ! $# -eq 0 ]]; do
    case "${1}" in
        -h | --help)
            usage
            exit 0
            ;;

        -l | --list)
            log_info "Listing disks"
            lsblk --nodeps --noheadings --exclude 7 --output NAME,SIZE
            log_ok "DONE"
            exit 0
            ;;

        -c | --clean)
            log_info "Starting cleaning"

            umount --recursive /mnt 2>/dev/null
            swapoff "${SWAP_P}" 2>/dev/null
            rm "${PASSED_ENV_VARS}"

            log_ok "DONE"
            exit 0
            ;;

        -d | --disk)
            if [ -z "${2-}" ]; then
                usage
                exit 1
            fi
            shift
            DISK="${1}"

            if ! lsblk --nodeps --noheadings --output NAME,SIZE "/dev/${DISK}"; then
                log_error "Wrong disk choice: ${DISK}"
                log_info "List available disks with -l, --list"
                usage
                exit 1
            fi
            ;;

        *)
            echo "Invalid option: ${1}"
            usage
            exit 1
            ;;
    esac
    shift
done


main
