packer {
  required_plugins {
    tart = {
      version = ">= 1.16.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

# Keep variable surface compatible with shared Make vars.
variable "user_data_disk_max_size_gb" {
  type        = number
  default     = 160
  description = "Maximum logical size (GB) of the User disk image artifact created on the host during packer build."
}

variable "user_library_disk_max_size_gb" {
  type        = number
  default     = 120
  description = "Maximum logical size (GB) for User Library disk image."
}

variable "git_bare_store_disk_max_size_gb" {
  type        = number
  default     = 8
  description = "Maximum logical size (GB) for Git Bare Store disk image."
}

variable "git_store_disk_max_size_gb" {
  type        = number
  default     = 9
  description = "Maximum logical size (GB) for Git Store disk image."
}

variable "nix_store_disk_max_size_gb" {
  type        = number
  default     = 100
  description = "Maximum logical size (GB) for Nix Store disk image."
}

variable "user_build_chains_cache_disk_max_size_gb" {
  type        = number
  default     = 64
  description = "Maximum logical size (GB) for Build Chains disk image."
}

variable "user_vm_images_disk_max_size_gb" {
  type        = number
  default     = 512
  description = "Maximum logical size (GB) for VM Images disk image."
}

variable "user_data_disk_initial_size_gb" {
  type        = number
  default     = 64
  description = "Initial APFS volume size (GB) to use inside the User disk."
}

variable "user_library_disk_initial_size_gb" {
  type        = number
  default     = 20
  description = "Initial APFS volume size (GB) to use inside the User Library disk."
}

variable "git_bare_store_disk_initial_size_gb" {
  type        = number
  default     = 4
  description = "Initial APFS volume size (GB) to use inside the Git Bare Store disk."
}

variable "git_store_disk_initial_size_gb" {
  type        = number
  default     = 6
  description = "Initial APFS volume size (GB) to use inside the Git Store disk."
}

variable "nix_store_disk_initial_size_gb" {
  type        = number
  default     = 90
  description = "Initial APFS volume size (GB) to use inside the Nix Store disk."
}

variable "user_vm_images_disk_initial_size_gb" {
  type        = number
  default     = 120
  description = "Initial APFS volume size (GB) to use inside the VM Images disk."
}

variable "user_build_chains_cache_disk_initial_size_gb" {
  type        = number
  default     = 16
  description = "Initial APFS volume size (GB) to use inside the Build Chains disk."
}

variable "user_data_disk_image_path" {
  type        = string
  default     = ""
  description = "Optional override for Data disk image path."
}

variable "user_library_disk_image_path" {
  type        = string
  default     = ""
  description = "Optional override for User Library disk image path."
}

variable "git_bare_store_disk_image_path" {
  type        = string
  default     = ""
  description = "Optional override for Git Bare Store disk image path."
}

variable "git_store_disk_image_path" {
  type        = string
  default     = ""
  description = "Optional override for Git Store disk image path."
}

variable "nix_store_disk_image_path" {
  type        = string
  default     = ""
  description = "Optional override for Nix Store disk image path."
}

variable "user_build_chains_cache_disk_image_path" {
  type        = string
  default     = ""
  description = "Optional override for Build Chains disk image path."
}

variable "user_vm_images_disk_image_path" {
  type        = string
  default     = ""
  description = "Optional override for VM Images disk image path."
}

variable "vm_name" {
  type        = string
  default     = "nxmatic-tahoe"
  description = "Name of the Tart VM to create."
}

variable "vm_base_name" {
  type        = string
  default     = "ghcr.io/cirruslabs/macos-tahoe-vanilla:latest"
  description = "Base Tart VM image to clone from (local VM name or registry reference)."
}

variable "macos_build_source_mode" {
  type        = string
  default     = "clone"
  description = "Source mode for VM creation: clone or ipsw."
  validation {
    condition     = contains(["clone", "ipsw"], var.macos_build_source_mode)
    error_message = "MacOS build source mode must be either clone or ipsw."
  }
}

variable "macos_ipsw" {
  type        = string
  default     = "latest"
  description = "IPSW source used when macos_build_source_mode=ipsw (URL/path/latest)."
}

variable "tart_home" {
  type        = string
  default     = ""
  description = "Optional Tart home directory."
}

variable "macos_primary_account_name" {
  type        = string
  default     = "nxmatic"
  description = "Primary account short name used for post-install configuration."
}

variable "macos_primary_account_full_name" {
  type        = string
  default     = "Stephane Lacoin (aka nxmatic)"
  description = "Preferred full display name for the primary account."
}

variable "macos_primary_account_alias" {
  type        = string
  default     = "nxmatic"
  description = "Optional additional short-name alias."
}

variable "macos_primary_account_expected_uid" {
  type        = number
  default     = 501
  description = "Expected UID for the primary account."
}

variable "macos_enable_darwin_boot_args" {
  type        = bool
  default     = true
  description = "Whether provisioning should manage NVRAM boot-args inside the guest."
}

variable "macos_darwin_boot_args" {
  type        = string
  default     = "-v"
  description = "Boot-args tokens to ensure in NVRAM."
}

variable "macos_data_home_user" {
  type        = string
  default     = "nxmatic"
  description = "Preferred user for data-home replication."
}

variable "macos_nix_store_volume_label" {
  type        = string
  default     = "Nix Store"
  description = "APFS volume label expected for the dedicated Nix store role disk."
}

variable "macos_nix_store_system_mount_point" {
  type        = string
  default     = "/nix"
  description = "Canonical system mountpoint used for Nix store exposure inside guest."
}

variable "macos_nix_store_configure_system_mount" {
  type        = bool
  default     = true
  description = "Whether provisioning enforces dedicated Nix volume availability at configured mountpoint."
}

variable "macos_nix_store_configure_synthetic" {
  type        = bool
  default     = true
  description = "Whether provisioning may use synthetic mountpoint plumbing for /nix realization when needed."
}

variable "macos_bootstrap_ssh_username" {
  type        = string
  default     = ""
  description = "Optional SSH username used by Packer communicator during bootstrap."
}

variable "macos_bootstrap_ssh_password" {
  type        = string
  default     = ""
  description = "Optional SSH password used by Packer communicator during bootstrap. If empty, defaults to admin."
}

variable "macos_vm_scripts_dir" {
  type        = string
  default     = "/private/tmp/scripts"
  description = "Directory inside VM from which provisioning scripts are executed."
}

variable "macos_env_pointer_file" {
  type        = string
  default     = "/private/tmp/macos-image-template.envrc.path"
  description = "Path of file in VM that stores runtime envrc filename."
}

variable "nix_installer_url" {
  type        = string
  default     = "https://artifacts.nixos.org/nix-installer"
  description = "URL used to download modern Nix installer script."
}

variable "nix_installer_path" {
  type        = string
  default     = "/Users/nxmatic/.tart/sbin/nix-installer"
  description = "Path inside the VM where the Nix installer script is staged."
}

variable "nix_install_at_build" {
  type        = bool
  default     = false
  description = "Whether to run modern Nix installer during packer build. Default false to defer Nix bootstrap."
}

variable "attach_data_disk_during_build" {
  type        = bool
  default     = false
  description = "Unused in vanilla grow flow; kept for Make var compatibility."
}

variable "enable_build_console" {
  type        = bool
  default     = false
  description = "Whether to keep Tart built-in graphical console enabled while packer build runs (local UI window)."
}

variable "enable_boot_command" {
  type        = bool
  default     = false
  description = "Whether to run automated macOS setup keystrokes (boot_command)."
}

variable "system_container_size_gb" {
  type        = number
  default     = 0
  description = "Target size (GB) for APFS system container. 0 means max available size."
  validation {
    condition     = var.system_container_size_gb >= 0
    error_message = "System container size must be greater than or equal to 0 GB (0 means max available size)."
  }
}

variable "root_disk_size_gb" {
  type        = number
  default     = 100
  description = "Root VM disk size (GB)."
  validation {
    condition     = var.root_disk_size_gb >= 50
    error_message = "Root disk size must be greater than or equal to 50 GB."
  }
}

variable "root_disk_format" {
  type        = string
  default     = "raw"
  description = "Root VM disk image format used by tart create (raw or asif)."
  validation {
    condition     = contains(["raw", "asif"], var.root_disk_format)
    error_message = "Root disk format must be either 'raw' or 'asif'."
  }
}

variable "recovery_partition_mode" {
  type        = string
  default     = "relocate"
  description = "Recovery partition handling mode: keep, delete or relocate."
  validation {
    condition     = contains(["keep", "delete", "relocate"], var.recovery_partition_mode)
    error_message = "Recovery partition mode must be one of: keep, delete, or relocate."
  }
}

locals {
  use_ipsw                     = var.macos_build_source_mode == "ipsw"
  macos_bootstrap_ssh_username = var.macos_bootstrap_ssh_username != "" ? var.macos_bootstrap_ssh_username : (local.use_ipsw ? var.macos_primary_account_name : "admin")
  macos_bootstrap_ssh_password = var.macos_bootstrap_ssh_password != "" ? var.macos_bootstrap_ssh_password : "admin"
}

source "tart-cli" "tart" {
  vm_base_name = local.use_ipsw ? "" : var.vm_base_name
  from_ipsw    = local.use_ipsw ? var.macos_ipsw : ""
  vm_name      = var.vm_name
  cpu_count    = 7
  memory_gb    = 32
  display      = "1728x1080"
  headless     = !var.enable_build_console
  disable_vnc  = true
  disk_size_gb = var.root_disk_size_gb
  disk_format  = var.root_disk_format
  ssh_password = local.macos_bootstrap_ssh_password
  ssh_username = local.macos_bootstrap_ssh_username
  ssh_timeout  = "180s"
  boot_wait               = "5s"
  boot_key_interval       = "20ms"
  boot_keygroup_interval  = "80ms"
  run_extra_args = []
  boot_command = var.enable_boot_command ? [
    "<wait40s><spacebar>",
  ] : []
  create_grace_time   = "15s"
  recovery_partition  = var.recovery_partition_mode
}

build {
  sources = ["source.tart-cli.tart"]

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "mkdir -p /private/tmp",
    ]
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "printf '%s\\n' 'admin' | sudo -S -p '' bash -c \"install -d -m 0750 /etc/sudoers.d && printf '%s\\n' '${local.macos_bootstrap_ssh_username} ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-packer-nopasswd && chmod 0440 /etc/sudoers.d/99-packer-nopasswd\"",
      "sudo -n -l >/dev/null",
    ]
  }

  provisioner "file" {
    source      = "${path.root}/../scripts/resize-system-container.sh"
    destination = "/private/tmp/resize-system-container.sh"
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "chmod 0755 /private/tmp/resize-system-container.sh",
      "SYSTEM_CONTAINER_SIZE_GB='${var.system_container_size_gb}' bash -euxo pipefail /private/tmp/resize-system-container.sh",
    ]
  }
}
