#!/usr/bin/env bash
# shellcheck disable=SC1090

TEMP_DIR="$(dirname "${0}")"
SCRIPT_NAME="$(basename "${0}")"
LOG_FILE="${SCRIPT_NAME}.log"
PASSED_ENV_VARS=".${SCRIPT_NAME}.env"
FUNCTIONS="functions.sh"
CONFIG_FILE="installation_config.conf"
LIGHTDM_CONF="99-switch-monitor.conf"
SSH_HARDENING_DIR="config/sshd_config.d/"

MODE="${1}"
DISK="${2}"

pushd "${TEMP_DIR}" || exit 1

# Logging the entire script
exec 3>&1 4>&2 > >(tee -a "${LOG_FILE}") 2>&1

# Sourcing log functions
# you need to be in functions directory for this sourcing to work
pushd functions || exit 1
if ! source "${FUNCTIONS}"; then
  echo "Error! Could not source ${FUNCTIONS}"
  exit 1
fi
popd || exit 1

# Sourcing configuration file
# you need to be in config directory for this sourcing to work
pushd config || exit 1
if ! source "${CONFIG_FILE}"; then
  echo "Error! Could not source ${CONFIG_FILE}"
  exit 1
fi
popd || exit 1

DE_PACKAGES="packages/${DE}-packages.csv"

if [ -z "${MODE}" ] || [ -z "${DISK}" ]; then
  log_error "Variables are not set. MODE: ${MODE}, DISK: ${DISK}" && exit 1
fi

function check_config() {
  [-z "${TIMEZONE+x}"] &&
    log_error "Variable was not found in configuration file ${CONFIG_FILE}: TIMEZONE" &&
    exit 1
  [-z "${TIMEZONE}"] && log_error "Variable TIMEZONE cannot be empty." && exit 1
  # all available time zones are in /usr/share/zoneinfo/
  TIMEZONES="$(find -mindepth 2 -maxdepth 2 -type f -printf "%P\n" | grep -v 'posix\|right\|Etc')"
  if ! echo "${TIMEZONES}" | grep "${TIMEZONE}"; then
    log_error "Variable TIMEZONE must be one from /usr/share/zoneinfo/. Set as: ${TIMEZONE}"
    log_info "Examples:"
    echo "${TIMEZONES}"
    exit 1
  fi

  [-z "${LANG+x}"] &&
    log_error "Variable was not found in configuration file ${CONFIG_FILE}: LANG" &&
    exit 1
  [-z "${LANG}"] && log_error "Variable LANG cannot be empty." && exit 1
  if ! grep "${LANG}" /etc/locale.gen; then
    log_error "Variable LANG must be one from /etc/locale.gen file. Set as: ${TIMEZONE}"
    exit 1
  fi

  [-z "${HOSTNAME+x}"] &&
    log_error "Variable was not found in configuration file ${CONFIG_FILE}: HOSTNAME" &&
    exit 1
  [-z "${HOSTNAME}"] && log_error "Variable HOSTNAME cannot be empty." && exit 1

  [-z "${LUKS_AND_LVM+x}"] &&
    log_error "Variable was not found in configuration file ${CONFIG_FILE}: LUKS_AND_LVM" &&
    exit 1
  if [[ "${LUKS_AND_LVM}" != 'yes' && "${LUKS_AND_LVM}" != 'no' ]]; then
    log_error "Variable LUKS_AND_LVM from ${CONFIG_FILE} must be either 'yes' or 'no'."
    exit 1
  fi

  [-z "${SINGLE_PARTITION+x}"] &&
    log_error "Variable was not found in configuration file ${CONFIG_FILE}: SINGLE_PARTITION" &&
    exit 1
  if [[ "${SINGLE_PARTITION}" != 'yes' && "${SINGLE_PARTITION}" != 'no' ]]; then
    log_error "Variable SINGLE_PARTITION from ${CONFIG_FILE} must be either 'yes' or 'no'."
    exit 1
  fi

  [-z "${DESKTOP+x}"] &&
    log_error "Variable was not found in configuration file ${CONFIG_FILE}: DESKTOP" &&
    exit 1
  if [[ "${DESKTOP}" != 'yes' && "${DESKTOP}" != 'no' ]]; then
    log_error "Variable DESKTOP from ${CONFIG_FILE} must be either 'yes' or 'no'."
    exit 1
  fi

  [-z "${DE+x}"] &&
    log_error "Variable was not found in configuration file ${CONFIG_FILE}: DE" &&
    exit 1
  if [[ "${DE}" != 'i3' && "${DE}" != 'gnome' ]]; then
    log_error "Variable DE from ${CONFIG_FILE} must be either 'yes' or 'no'."
    exit 1
  fi
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

  log_info "Increasing number of parallel downloads to ${CORES}"
  sed --regexp-extended --in-place "s|^#ParallelDownloads.*|ParallelDownloads = ${CORES}|g" "${CONF_FILE}"

  log_info "Disabling for the moment signature checking"
  # Disable signature checking because it keeps failing for some unknown reason
  sed --regexp-extended --in-place "s|^SigLevel.*|SigLevel = Never|g" "${CONF_FILE}"

  log_info "Refreshing sources"
  exit_on_error pacman --noconfirm --sync --refresh

  echo PASSED_CONFIGURING_PACMAN="PASSED" >> "${PASSED_ENV_VARS}"
  log_ok "DONE"
}

# Setting up time
function set_time() {
  log_info "Setting up time"

  if [ -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
    exit_on_error ln --symbolic --force "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime &&
      hwclock --systohc
  else
    log_error "Cannot set timezone ${TIMEZONE}. Look at function set_time() from stage2_installation."
    exit 1
  fi

  echo PASSED_SET_TIME="PASSED" >> "${PASSED_ENV_VARS}"
  log_ok "DONE"
}

# Changing the language to english
function change_language() {
  log_info "Setting up language"

  sed --in-place "/${LANG}/s|^#||" /etc/locale.gen
  echo "LANG=${LANG}" > /etc/locale.conf
  locale-gen

  echo PASSED_CHANGE_LANGUAGE="PASSED" >> "${PASSED_ENV_VARS}"
  log_ok "DONE"
}

# Setting the hostname
function set_hostname() {
  log_info "Setting hostname to ${HOSTNAME}"

  echo "${HOSTNAME}" > /etc/hostname

  echo PASSED_SET_HOSTNAME="PASSED" >> "${PASSED_ENV_VARS}"
  log_ok "DONE"
}

# Change root password
function change_root_password() {
  log_info "Change root password"

  while ! passwd; do
    sleep 1
  done

  echo PASSED_CHANGE_ROOT_PASSWORD="PASSED" >> "${PASSED_ENV_VARS}"
  log_ok "DONE"
}

# Set user and password
function set_user() {
  log_info "Setting administrator account"

  NAME=""

  while [ -z "${NAME}" ]; do
    printf "Enter name for the local user: "
    read -r NAME
  done

  log_info "Creating ${NAME} user and adding it to wheel group"
  exit_on_error useradd --create-home --groups wheel --shell /bin/bash "${NAME}"

  log_info "Adding wheel to sudoers"
  echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/01-wheel_group

  log_info "Setting up user password"
  while ! passwd "${NAME}"; do
    sleep 1
  done

  echo PASSED_SET_USER="PASSED" >> "${PASSED_ENV_VARS}"
  log_ok "DONE"
}

function configure_luks_and_lvm() {
  log_info "Configuring LUKS and LVM"

  ORIG_STRING="$(grep "^HOOKS" /etc/mkinitcpio.conf)"
  NEW_STRING="${ORIG_STRING//filesystem/plymouth encrypt lvm2 filesystem}"

  log_info "Adding encrypt and lvm2 parameters to HOOKS in mkinitcpio.conf"
  TEMP_FILE="$(mktemp)"

  awk -v ORIG="${ORIG_STRING}" -v NEW="${NEW_STRING}" '{
    sub(/^HOOKS.*/, NEW)
    print
  }' /etc/mkinitcpio.conf > "${TEMP_FILE}"

  cat "${TEMP_FILE}" > /etc/mkinitcpio.conf

  log_info "Regenerating initramfs"
  exit_on_error mkinitcpio -P

  log_info "Set boot theme"
  exit_on_error plymouth-set-default-theme -R bgrt

  log_info "Configuring the boot loader"
  ENCRYPTED_PART_UUID="$(blkid | awk '/LUKS/ {gsub(/"/,""); print $2}')"

  ORIG_STRING="$(grep "^GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub)"
  NEW_STRING="${ORIG_STRING//quiet/quiet splash cryptdevice=${ENCRYPTED_PART_UUID}:cryptlvm root=/dev/vgroup/root}"

  awk -v ORIG="${ORIG_STRING}" -v NEW="${NEW_STRING}" '{
    sub(/^GRUB_CMDLINE_LINUX_DEFAULT.*/, NEW)
    print
  }' /etc/default/grub > "${TEMP_FILE}"

  cat "${TEMP_FILE}" > /etc/default/grub

  echo PASSED_CONFIGURE_LUKS_AND_LVM="PASSED" >> "${PASSED_ENV_VARS}"
  log_ok "DONE"
}

# Installing grub and creating configuration
function grub_configuration() {
  log_info "Installing and configuring grub"

  if [[ "${MODE}" = "UEFI" ]]; then
    exit_on_error pacman --noconfirm --sync efibootmgr &&
      grub-install --target=x86_64-efi --efi-directory=/boot &&
      grub-mkconfig --output=/boot/grub/grub.cfg
  elif [[ "${MODE}" = "BIOS" ]]; then
    exit_on_error grub-install "/dev/${DISK}" &&
      grub-mkconfig --output=/boot/grub/grub.cfg
  else
    log_error "An error occured at grub step. Exiting"
  fi

  echo PASSED_GRUB_CONFIGURATION="PASSED" >> "${PASSED_ENV_VARS}"
  log_ok "DONE"
}

# Enabling services
function enable_services() {
  log_info "Enabling NetworkManager and sshd"

  exit_on_error systemctl enable NetworkManager &&
    systemctl enable sshd

  echo PASSED_ENABLE_SERVICES="PASSED" >> "${PASSED_ENV_VARS}"
  log_ok "DONE"
}

#Install yay: script taken from Luke Smith
function yay_install() {
  log_info "Installing yay - AUR package manager"

  log_info "Cloning yay repository"
  sudo -u "${NAME}" mkdir -p "/home/${NAME}/.local/yay"
  exit_on_error sudo -u "${NAME}" git -C "/home/${NAME}/.local" clone --depth 1 --single-branch \
    --no-tags -q "https://aur.archlinux.org/yay.git" "/home/${NAME}/.local/yay" ||
    {
      pushd "/home/${NAME}/.local/yay" || exit 1
      exit_on_error sudo -u "${NAME}" git pull --force origin master
      popd || exit 1
    }

  log_info "Installing yay"
  pushd "/home/${NAME}/.local/yay" || exit 1
  exit_on_error sudo -u "${NAME}" makepkg --noconfirm -si || return 1
  popd || exit 1

  # shellcheck disable=SC2046
  if [[ "${DESKTOP}" = "yes" ]] && [ -n "${DE}" ] && grep --quiet 'AUR' "${DE_PACKAGES}"; then
    log_info "Installing AUR packages"
    exit_on_error sudo -u "${NAME}" yay --noconfirm -S $(awk -F ',' '/AUR/ {printf "%s ", $1}' "${DE_PACKAGES}")
  fi

  echo PASSED_YAY_INSTALL="PASSED" >> "${PASSED_ENV_VARS}"
  log_ok "DONE"
}

function apply_configuration() {
  log_info "Downloading and applying new configuration"

  log_info "Cloning the configuration repository"
  sudo -u "${NAME}" mkdir --parents "/home/${NAME}/git_clone"
  pushd "/home/${NAME}/git_clone" || exit 1
  exit_on_error sudo -u "${NAME}" git clone https://github.com/arghpy/dotfiles .
  popd || exit 1

  log_info "Cloning tmux plugin manager"
  pushd "/home/${NAME}/" || exit 1
  exit_on_error sudo -u "${NAME}" git clone https://github.com/tmux-plugins/tpm .tmux/plugins/tpm
  popd || exit 1

  log_info "Copying in configuration in ${NAME} home"
  sudo -u "${NAME}" cp --recursive "/home/${NAME}/git_clone/"* "/home/${NAME}/"
  sudo -u "${NAME}" cp --recursive "/home/${NAME}/git_clone/".* "/home/${NAME}/"

  log_info "Removing clone repository"
  rm -rf "/home/${NAME}/git_clone/"
  rm -rf "/home/${NAME}/.git"
  rm -rf "/home/${NAME}/.github"
  rm -rf "/home/${NAME}/.linters_config"
  rm -f "/home/${NAME}/README.md"

  if [[ "${DE}" != "i3" ]]; then
    rm -rf "/home/${NAME}/.config/i3*"
    rm -f "/home/${NAME}/.xprofile"
  fi

  log_info "Apply SSH hardening options"
  exit_on_error cp --recursive "${SSH_HARDENING_DIR}" /etc/ssh/

  echo PASSED_APPLY_CONFIGURATION="PASSED" >> "${PASSED_ENV_VARS}"
  log_ok "DONE"
}

function install_additional_packages() {
  log_info "Installing additonal packages on the new system"

  # shellcheck disable=SC2046
  exit_on_error pacman --noconfirm --sync --refresh $(awk -F ',' '/repo/ {printf "%s ", $1}' "${DE_PACKAGES}")

  log_info "Processing fonts"
  exit_on_error fc-cache -f -v

  echo PASSED_INSTALL_ADDITONAL_PACKAGES="PASSED" >> "${PASSED_ENV_VARS}"
  log_ok "DONE"
}

function configure_additional_packages() {
  log_info "Configuring additional packages"

  if [[ "${DE}" = "i3" ]]; then
    log_info "Configuring lightdm"

    mkdir -p /etc/lightdm/lightdm.conf.d

    # you need to be in functions directory for this sourcing to work
    pushd config || exit 1
    sed "s|user_account|${NAME}|g" "${LIGHTDM_CONF}" > "/etc/lightdm/lightdm.conf.d/${LIGHTDM_CONF}"
    exit_on_error systemctl enable lightdm
    popd || exit 1

    log_ok "DONE"
  elif [[ "${DE}" = "gnome" ]]; then
    log_info "Enabling gdm service for gnome"
    exit_on_error systemctl enable gdm
  fi

  echo PASSED_CONFIGURE_ADDITONAL_PACKAGES="PASSED" >> "${PASSED_ENV_VARS}"
  log_ok "DONE"
}

# MAIN
function main() {
  touch "${PASSED_ENV_VARS}"
  check_config
  [ -z "${PASSED_CONFIGURING_PACMAN+x}" ] && configuring_pacman
  [ -z "${PASSED_SET_TIME+x}" ] && set_time
  [ -z "${PASSED_CHANGE_LANGUAGE+x}" ] && change_language
  [ -z "${PASSED_SET_HOSTNAME+x}" ] && set_hostname
  [ -z "${PASSED_CHANGE_ROOT_PASSWORD+x}" ] && change_root_password
  [ -z "${PASSED_SET_USER+x}" ] && set_user

  if [ "${DESKTOP}" = "yes" ] && [ -n "${DE}" ]; then
    [ -z "${PASSED_INSTALL_ADDITIONAL_PACKAGES+x}" ] && install_additional_packages
    [ -z "${PASSED_CONFIGURE_ADDITIONAL_PACKAGES+x}" ] && configure_additional_packages
  fi

  if [ "${LUKS_AND_LVM}" = "yes" ] &&
    [ -z "${PASSED_CONFIGURE_LUKS_AND_LVM+x}" ]; then
    configure_luks_and_lvm
  fi
  [ -z "${PASSED_GRUB_CONFIGURATION+x}" ] && grub_configuration
  [ -z "${PASSED_ENABLE_SERVICES+x}" ] && enable_services
  [ -z "${PASSED_YAY_INSTALL+x}" ] && yay_install
  [ -z "${PASSED_APPLY_CONFIGURATION+x}" ] && apply_configuration

  log_ok "DONE"
  exec 1>&3 2>&4

  popd || exit 1
  log_info "Removing installation scripts"
  rm -rf "${TEMP_DIR}"

  log_info "Re-enabling signature checking"
  # Enable signature checking
  sed --regexp-extended --in-place "s|^SigLevel.*|SigLevel    = Required DatabaseOptional|g" "${CONF_FILE}"
}

main
