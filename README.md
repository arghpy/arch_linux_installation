# Arch Generic installation

This is a project that provides an installation
script for [Arch Linux](https://archlinux.org/).

Several installation types are possible:

- server
- desktop:
  - i3 desktop environment: [Home Page](https://i3wm.org/)
  - gnome desktop environment: [Home Page](https://www.gnome.org/)

Minimum dependencies are necessary in order to install
the system.

Neovim and tmux are to be configured automatically on both **i3** and **gnome**.
For the moment the user cannot opt out of this.
Only for server installations where those won't matter.

# Table of Contents

1. [Getting Started](#getting-started)
2. [Usage](#usage)
3. [Issues or Problems](#issues-or-problems)
4. [Wishlist](#wishlist)

## Getting Started

1. Download the latest [Arch Linux Iso](https://archlinux.org/download/)
2. Burn it to an USB stick:

- **Windows**: [rufus](https://rufus.ie/en/)
- **Linux**:
  - *Graphical*: [Balena Etcher](https://etcher.balena.io/)
  - *Command-Line*:

    Wipe disk:

    ```shell
    wipefs --all /dev/<disk>
    ```

    Write iso to disk:

    ```shell
    dd if=/path/to/iso of=/dev/<disk> status=progress
    ```

3. Boot the system with bootable USB stick

> [!NOTE]
> You need to disable **Secure Boot** in UEFI/BIOS settings

## Usage

After booting in the new system:

1. Make sure you are connected to internet.

2. Install `git`:

```shell
pacman -Sy git
```

> [!WARNING]
> In case there are problems with signing keys:
>
> - disable signature checking
>
> ```shell
> sed --rexexp-extended --in-place "s|^SigLevel.*|SigLevel = Never|g" /etc/pacman.conf
> ```

3. Clone repository:

```shell
git clone https://github.com/arghpy/arch_linux_installation
```

4. Go into repository:

```shell
cd arch_linux_installation
```

5. Configure [installation_config.conf](config/installation_config.conf)

6. Consult the `--help` of the script:

```shell
./stage1_installation.sh --help
```

7. Start the installation:

```shell
./stage1_installation.sh
```

> [!IMPORTANT]
> The installation is interactive. Please pay attention to prompts and answers.
> The minumum space required for the installation to work is 40GiB.

## Issues or Problems

In case of failure, logs are in the form `stage{1,2}_installation.sh.log`.

For viewing them in a 'coloured' way, use:

```shell
less -R <log_file>
```

Please submit errors in the form of issues. Attach the logs
themselves or screenshots of them.

## Wishlist

1. Allow user to opt in/out of applying configuration
2. Allow user to delete and add any desired package:

- checks will be done on core packages
- configuration will be applied dynamically
