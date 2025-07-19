#!/usr/bin/env bash
# shellcheck disable=SC1090

CWD="$(pwd)"
SCRIPT_NAME="$(basename "${0}")"
LOG_FILE="${CWD}/${SCRIPT_NAME}.log"
PASSED_ENV_VARS="${CWD}/.${SCRIPT_NAME}.env"
FUNCTIONS="functions.sh"
CORE_PACKAGES="${CWD}/packages/core-packages.csv"
CONFIG_FILE="${CWD}/config/installation_config.conf"

# Logging the entire script and also outputing to terminal
exec 3>&1 4>&2 > >(tee --append "${LOG_FILE}") 2>&1

# Sourcing log functions
# you need to be in functions directory for this sourcing to work
pushd functions > /dev/null || exit 1
if ! source "${FUNCTIONS}"; then
  echo "Error! Could not source ${FUNCTIONS}"
  exit 1
fi
popd > /dev/null || exit 1

# Sourcing config file
if ! source "${CONFIG_FILE}"; then
  echo "Error! Could not source ${FUNCTIONS}"
  exit 1
fi

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

function check_config() {
  log_info "Checking configuration file ${CONFIG_FILE}"
  [ -z "${TIMEZONE+x}" ] &&
    log_error "Variable was not found in configuration file ${CONFIG_FILE}: TIMEZONE" &&
    exit 1
  [ -z "${TIMEZONE}" ] && log_error "Variable TIMEZONE cannot be empty." && exit 1
  # all available time zones are in /usr/share/zoneinfo/
  pushd /usr/share/zoneinfo/ > /dev/null || exit 1
  TIMEZONES="$(find -mindepth 2 -maxdepth 2 -type f -printf "%P\n" | grep -v 'posix\|right\|Etc')"
  popd > /dev/null || exit 1
  if ! echo "${TIMEZONES}" | grep --quiet "${TIMEZONE}"; then
    log_error "Variable TIMEZONE must be one from /usr/share/zoneinfo/. Set as: ${TIMEZONE}"
    log_info "Examples:"
    echo "${TIMEZONES}"
    exit 1
  fi

  [ -z "${LANG+x}" ] &&
    log_error "Variable was not found in configuration file ${CONFIG_FILE}: LANG" &&
    exit 1
  [ -z "${LANG}" ] && log_error "Variable LANG cannot be empty." && exit 1
  if ! grep --quiet "${LANG}" /etc/locale.gen; then
    log_error "Variable LANG must be one from /etc/locale.gen file. Set as: ${TIMEZONE}"
    exit 1
  fi

  [ -z "${HOSTNAME+x}" ] &&
    log_error "Variable was not found in configuration file ${CONFIG_FILE}: HOSTNAME" &&
    exit 1
  [ -z "${HOSTNAME}" ] && log_error "Variable HOSTNAME cannot be empty." && exit 1

  [ -z "${LUKS_AND_LVM+x}" ] &&
    log_error "Variable was not found in configuration file ${CONFIG_FILE}: LUKS_AND_LVM" &&
    exit 1
  if [[ "${LUKS_AND_LVM}" != 'yes' && "${LUKS_AND_LVM}" != 'no' ]]; then
    log_error "Variable LUKS_AND_LVM from ${CONFIG_FILE} must be either 'yes' or 'no'."
    exit 1
  fi

  [ -z "${SINGLE_PARTITION+x}" ] &&
    log_error "Variable was not found in configuration file ${CONFIG_FILE}: SINGLE_PARTITION" &&
    exit 1
  if [[ "${SINGLE_PARTITION}" != 'yes' && "${SINGLE_PARTITION}" != 'no' ]]; then
    log_error "Variable SINGLE_PARTITION from ${CONFIG_FILE} must be either 'yes' or 'no'."
    exit 1
  fi

  [ -z "${DESKTOP+x}" ] &&
    log_error "Variable was not found in configuration file ${CONFIG_FILE}: DESKTOP" &&
    exit 1
  if [[ "${DESKTOP}" != 'yes' && "${DESKTOP}" != 'no' ]]; then
    log_error "Variable DESKTOP from ${CONFIG_FILE} must be either 'yes' or 'no'."
    exit 1
  fi

  [ -z "${DE+x}" ] &&
    log_error "Variable was not found in configuration file ${CONFIG_FILE}: DE" &&
    exit 1
  if [[ "${DE}" != 'i3' && "${DE}" != 'gnome' ]]; then
    log_error "Variable DE from ${CONFIG_FILE} must be either 'yes' or 'no'."
    exit 1
  fi
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
function configuring_pacman() {
  log_info "Configuring pacman"

  CORES="$(nproc)"
  # shellcheck disable=SC2086
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

  # shellcheck disable=SC2086
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

  if ls /sys/firmware/efi/efivars > /dev/null 2>&1; then
    MODE="UEFI"
    exit_on_error parted --script "/dev/${DISK}" mklabel gpt
  else
    MODE="BIOS"
    exit_on_error parted --script "/dev/${DISK}" mklabel msdos
  fi

  exit_on_error parted --script "/dev/${DISK}" mkpart primary fat32 2048s 1GiB

  if [[ "${LUKS_AND_LVM}" = "yes" ]]; then
    parted --script "/dev/${DISK}" mkpart primary ext4 1GiB 100%
    parted --script "/dev/${DISK}" align-check optimal 1

    # Encrypt the second partition
    PARTITIONS="$(blkid --output device | grep "${DISK}" | sort)"
    ENCRYPTED_DISK="$(echo "${PARTITIONS}" | sed -n '2p')"

    log_info "Preparing encryption for ${ENCRYPTED_DISK} disk"
    while ! cryptsetup luksFormat "${ENCRYPTED_DISK}"; do
      sleep 1
      log_warning "Accept (type YES) and be sure the passwords match"
    done

    # Proceed to create LVMs
    log_info "Opening LUKS partition to create LVM"
    while ! cryptsetup open "${ENCRYPTED_DISK}" cryptlvm; do
      sleep 1
      log_warning "Try entering again the previous LUKS password"
    done
    exit_on_error pvcreate /dev/mapper/cryptlvm
    exit_on_error vgcreate vgroup /dev/mapper/cryptlvm
    exit_on_error lvcreate -L 4G vgroup -n swap

    if [[ "${SINGLE_PARTITION}" = "yes" ]]; then
      exit_on_error lvcreate -l 100%FREE vgroup -n root
    else
      exit_on_error lvcreate -L 30G vgroup -n root
      exit_on_error lvcreate -l 100%FREE vgroup -n home
    fi
  else
    # Make a GPT partitioning type - compatible with both UEFI and BIOS
    exit_on_error parted --script "/dev/${DISK}" mkpart primary linux-swap 1GiB 5GiB

    if [[ "${SINGLE_PARTITION}" = "yes" ]]; then
      exit_on_error parted --script "/dev/${DISK}" mkpart primary ext4 5GiB 100%
    else
      exit_on_error parted --script "/dev/${DISK}" mkpart primary ext4 5GiB 35GiB &&
        parted --script "/dev/${DISK}" mkpart primary ext4 35GiB 100%
    fi

    exit_on_error parted --script "/dev/${DISK}" align-check optimal 1
  fi

  log_ok "DONE"
}

# Formatting partitions
function formatting() {
  log_info "Formatting partitions"

  PARTITIONS="$(blkid --output device | grep "${DISK}" | sort)"

  BOOT_P="$(echo "${PARTITIONS}" | sed -n '1p')"

  if [[ "${LUKS_AND_LVM}" = "yes" ]]; then
    SWAP_P="/dev/vgroup/swap"
    ROOT_P="/dev/vgroup/root"

    [[ "${SINGLE_PARTITION}" = "no" ]] && HOME_P="/dev/vgroup/home"
  else
    SWAP_P="$(echo "${PARTITIONS}" | sed -n '2p')"
    ROOT_P="$(echo "${PARTITIONS}" | sed -n '3p')"

    [[ "${SINGLE_PARTITION}" = "no" ]] && HOME_P="$(echo "${PARTITIONS}" | sed -n '4p')"
  fi

  exit_on_error mkfs.vfat -F32 "${BOOT_P}" &&
    mkswap "${SWAP_P}" &&
    swapon "${SWAP_P}" &&
    mkfs.ext4 -F "${ROOT_P}"

  [[ "${SINGLE_PARTITION}" = "no" ]] && exit_on_error mkfs.ext4 -F "${HOME_P}"

  echo PASSED_FORMATTING="PASSED" >> "${PASSED_ENV_VARS}"
  echo SWAP_P="${SWAP_P}" >> "${PASSED_ENV_VARS}"
  log_ok "DONE"
}

# Mounting partitons
function mounting() {
  log_info "Mounting partitions"

  exit_on_error mount --mkdir "${ROOT_P}" /mnt &&
    mount --mkdir "${BOOT_P}" /mnt/boot

  [[ "${SINGLE_PARTITION}" = "no" ]] && exit_on_error mount --mkdir "${HOME_P}" /mnt/home

  echo PASSED_MOUNTING="PASSED" >> "${PASSED_ENV_VARS}"
  log_ok "DONE"
}

# Installing packages
function install_core_packages() {
  log_info "Installing core packages on the new system"

  # shellcheck disable=SC2046
  exit_on_error pacstrap -K /mnt $(awk -F ',' '{printf "%s ", $1}' "${CORE_PACKAGES}")

  echo PASSED_INSTALL_CORE_PACKAGES="PASSED" >> "${PASSED_ENV_VARS}"
  log_ok "DONE"
}

# Generating fstab
function generate_fstab() {
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
  check_config
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

      umount --recursive /mnt 2> /dev/null
      swapoff "${SWAP_P}" 2> /dev/null
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
