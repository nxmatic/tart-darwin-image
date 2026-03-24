SHELL := /bin/bash
.SHELLFLAGS := -euxo pipefail -c
.ONESHELL:
.SILENT:
.DEFAULT_GOAL := help

# Tooling
FLOX ?= flox
.flox.activate.cmd ?= $(FLOX) activate --
.tart.home ?= $(CURDIR)/.tart
.packer.cmd ?= $(.flox.activate.cmd) packer
.tart.cmd ?= $(.flox.activate.cmd) tart
.env.file ?= .env

define .env.load
set -a
. "$(CURDIR)/$(.env.file)"
set +a
endef

define .packer.run
$(call .env.load)
$(.packer.cmd) $(1)
endef

define .tart.run
$(call .env.load)
$(.tart.cmd) $(1)
endef

.tart.base.ref ?= ghcr.io/cirruslabs/macos-tahoe-vanilla:latest
.tart.clone.force ?= 0
.tart.disk.recreate ?= 0
.tart.disk.blank.fs ?= APFS

.tart.disk.cmd.ensure-parent = mkdir -p "$(dir $1)"
.tart.disk.cmd.prepare-image = if [[ "$(.tart.disk.recreate)" == "1" && -f "$2" ]]; then : "Recreating $1 disk: $2"; rm -f "$2"; fi; if [[ -f "$2" ]]; then : "Reusing existing $1 disk: $2"; else diskutil image create blank --format ASIF --size $3G --fs "$(.tart.disk.blank.fs)" --volumeName "$1" "$2"; fi
.tart.disk.cmd.show-info = : "$1: $2"; ls -lh "$2" 2>/dev/null || true

# Split-friendly grouping convention (future include files):
# - mk/tooling.mk: .*.cmd, .*.env.*
# - mk/flags.mk:   .packer.flags.* and toggle helpers
# - mk/disks.mk:   .tart.disk.* defaults/paths
# - mk/targets.mk: help/validate/build/run and operational targets

# Build defaults
.template.grow ?= templates/vanilla-tahoe.pkr.hcl
.template.customize ?= templates/nxmatic-tahoe.pkr.hcl
.template ?= $(.template.customize)
.tart.vm-name ?= nxmatic-tahoe
.tart.stage1-vm-name ?= big-vanilla-tahoe
.tart.stage2-vm-name ?= nix-store-tahoe
.tart.stage3-vm-name ?= nix-darwin-tahoe
.tart.stage4-vm-name ?= nxmatic-customized-tahoe
# Default cleanup set for rm* targets: all nxmatic stage artifacts + final VM.
# Intentionally excludes stage1 bootstrap artifact (.tart.stage1-vm-name / big-vanilla).
.tart.vm-names ?= $(.tart.stage2-vm-name) $(.tart.stage3-vm-name) $(.tart.stage4-vm-name) $(.tart.vm-name)
.tart.vm.path = $(.tart.home)/vms/$(.tart.vm-name)
.tart.stage1.vm.path = $(.tart.home)/vms/$(.tart.stage1-vm-name)
.tart.stage2.vm.path = $(.tart.home)/vms/$(.tart.stage2-vm-name)
.tart.stage3.vm.path = $(.tart.home)/vms/$(.tart.stage3-vm-name)
.tart.stage4.vm.path = $(.tart.home)/vms/$(.tart.stage4-vm-name)
.tart.stage1.vm.state := $(.tart.stage1.vm.path).state
.tart.stage2.vm.state := $(.tart.stage2.vm.path).state
.tart.stage3.vm.state := $(.tart.stage3.vm.path).state
.tart.stage4.vm.state := $(.tart.stage4.vm.path).state
.tart.final.vm.state := $(.tart.vm.path).state
.provision.profile ?= full

# Account identity defaults (Make-level knobs -> Packer vars -> script env)
.account.primary-name ?= nxmatic
.account.primary-full-name ?= Stephane Lacoin (aka nxmatic)
.account.primary-alias ?= nxmatic
.account.primary-password ?= admin
.account.primary-expected-uid ?= 501
.account.secondary-name ?= super
.account.secondary-password ?= super
.auto-login.user ?= $(if $(call opt-enabled,.debug),$(.account.secondary-name),$(.account.primary-name))
.data.home-user ?= $(.account.primary-name)
.bootstrap.ssh.user ?=
.bootstrap.ssh.password ?=

# Tart disk sizing defaults (GB)
.tart.disk.root.max-size-gb ?= 100
.tart.disk.root.format ?= raw
.tart.disk.user.max-size-gb ?= 160
.tart.disk.user-library.max-size-gb ?= 40
.tart.disk.git-bare-store.max-size-gb ?= 8
.tart.disk.git-store.max-size-gb ?= 9
.tart.disk.nix-store.max-size-gb ?= 180
.tart.disk.user-build-chains-cache.max-size-gb ?= 64
.tart.disk.vm-images.max-size-gb ?= 512

# Tart initial in-VM APFS sizes (GB)
.tart.disk.user.initial-size-gb ?= 64
.tart.disk.user-library.initial-size-gb ?= 20
.tart.disk.git-bare-store.initial-size-gb ?= 4
.tart.disk.git-store.initial-size-gb ?= 6
.tart.disk.nix-store.initial-size-gb ?= 90
.tart.disk.user-build-chains-cache.initial-size-gb ?= 16
.tart.disk.vm-images.initial-size-gb ?= 120

# Optional toggles
.enable-boot-command ?= false
.attach-data-disk-during-build ?= true
.interactive ?= 1
.debug ?= 1
.experimental ?= 0
.macos.enable-darwin-boot-args ?= true
.macos.darwin-boot-args ?= -v
.recovery.partition.mode ?= keep
.nix.store.volume-label ?= Nix Store
.nix.store.system-mount-point ?= /nix
.nix.store.configure-system-mount ?= true
.nix.store.configure-synthetic ?= true

# Tart run profile defaults (for interactive/recovery troubleshooting)
.tart.run.vnc ?= 1
.tart.run.recovery ?= 0
.tart.run.net-bridged ?= Wi-Fi
.tart.run.root-disk-opts ?=
.tart.run.disk.opts ?= sync=none
.tart.run.extra-args ?=

# Optional flag helper:
# enabled when variable is defined and not one of: false 0 no off (case-sensitive)
define opt-enabled
$(if $(filter undefined,$(origin $(1))),,$(if $(filter false 0 no off,$(strip $($(1)))),,1))
endef

define to-bool
$(if $(filter true 1 yes on,$(strip $(1))),true,false)
endef

ifneq ($(call opt-enabled,.interactive),)
.packer.flags.interactive := -debug
else
.packer.flags.interactive :=
endif

ifneq ($(call opt-enabled,.debug),)
ifneq ($(call opt-enabled,.interactive),)
.packer.flags.failure := -on-error=ask
else
.packer.flags.failure := -on-error=abort
endif
else
.packer.flags.failure :=
endif

# Computed default disk paths (align with template defaults)
.tart.disk.user.image-path ?=
.tart.disk.user-library.image-path ?=
.tart.disk.git-bare-store.image-path ?=
.tart.disk.git-store.image-path ?=
.tart.disk.nix-store.image-path ?=
.tart.disk.user-build-chains-cache.image-path ?=
.tart.disk.vm-images.image-path ?=

.tart.disk.user.image-path.effective := $(if $(strip $(.tart.disk.user.image-path)),$(.tart.disk.user.image-path),$(.tart.home)/disks/$(.tart.vm-name)/user-data.asif)
.tart.disk.user-library.image-path.effective := $(if $(strip $(.tart.disk.user-library.image-path)),$(.tart.disk.user-library.image-path),$(.tart.home)/disks/$(.tart.vm-name)/user-library.asif)
.tart.disk.git-bare-store.image-path.effective := $(if $(strip $(.tart.disk.git-bare-store.image-path)),$(.tart.disk.git-bare-store.image-path),$(.tart.home)/disks/$(.tart.vm-name)/git-bare-store.asif)
.tart.disk.git-store.image-path.effective := $(if $(strip $(.tart.disk.git-store.image-path)),$(.tart.disk.git-store.image-path),$(.tart.home)/disks/$(.tart.vm-name)/git-store.asif)
.tart.disk.nix-store.image-path.effective := $(if $(strip $(.tart.disk.nix-store.image-path)),$(.tart.disk.nix-store.image-path),$(.tart.home)/disks/$(.tart.vm-name)/nix-store.asif)
.tart.disk.user-build-chains-cache.image-path.effective := $(if $(strip $(.tart.disk.user-build-chains-cache.image-path)),$(.tart.disk.user-build-chains-cache.image-path),$(.tart.home)/disks/$(.tart.vm-name)/build-chains-cache.asif)
.tart.disk.vm-images.image-path.effective := $(if $(strip $(.tart.disk.vm-images.image-path)),$(.tart.disk.vm-images.image-path),$(.tart.home)/disks/$(.tart.vm-name)/vm-images.asif)

.tart.run.disk.opts.suffix := $(if $(strip $(.tart.run.disk.opts)),:$(strip $(.tart.run.disk.opts)),)

define .packer.vars.full
-var vm_name=$(.tart.vm-name)
-var vm_base_name=$(.tart.base.ref)
-var tart_home=$(.tart.home)
-var provision_profile=$(.provision.profile)
-var enable_build_console=$(call to-bool,$(.debug))
-var macos_primary_account_name=$(.account.primary-name)
-var 'macos_primary_account_full_name=$(.account.primary-full-name)'
-var macos_primary_account_alias=$(.account.primary-alias)
-var 'macos_primary_account_password=$(.account.primary-password)'
-var macos_primary_account_expected_uid=$(.account.primary-expected-uid)
-var macos_debug_mode=$(call to-bool,$(.debug))
-var macos_auto_login_user=$(.auto-login.user)
-var macos_bootstrap_ssh_username=$(.bootstrap.ssh.user)
-var macos_bootstrap_ssh_password=$(.bootstrap.ssh.password)
-var macos_data_home_user=$(.data.home-user)
-var 'macos_nix_store_volume_label=$(.nix.store.volume-label)'
-var 'macos_nix_store_system_mount_point=$(.nix.store.system-mount-point)'
-var macos_nix_store_configure_system_mount=$(call to-bool,$(.nix.store.configure-system-mount))
-var macos_nix_store_configure_synthetic=$(call to-bool,$(.nix.store.configure-synthetic))
-var macos_enable_darwin_boot_args=$(.macos.enable-darwin-boot-args)
-var 'macos_darwin_boot_args=$(.macos.darwin-boot-args)'
-var recovery_partition_mode=$(.recovery.partition.mode)
-var root_disk_format=$(.tart.disk.root.format)
-var root_disk_size_gb=$(.tart.disk.root.max-size-gb)
-var user_data_disk_initial_size_gb=$(.tart.disk.user.initial-size-gb)
-var user_library_disk_initial_size_gb=$(.tart.disk.user-library.initial-size-gb)
-var git_bare_store_disk_initial_size_gb=$(.tart.disk.git-bare-store.initial-size-gb)
-var git_store_disk_initial_size_gb=$(.tart.disk.git-store.initial-size-gb)
-var nix_store_disk_initial_size_gb=$(.tart.disk.nix-store.initial-size-gb)
-var user_build_chains_cache_disk_initial_size_gb=$(.tart.disk.user-build-chains-cache.initial-size-gb)
-var user_vm_images_disk_initial_size_gb=$(.tart.disk.vm-images.initial-size-gb)
-var user_data_disk_max_size_gb=$(.tart.disk.user.max-size-gb)
-var user_library_disk_max_size_gb=$(.tart.disk.user-library.max-size-gb)
-var git_bare_store_disk_max_size_gb=$(.tart.disk.git-bare-store.max-size-gb)
-var git_store_disk_max_size_gb=$(.tart.disk.git-store.max-size-gb)
-var nix_store_disk_max_size_gb=$(.tart.disk.nix-store.max-size-gb)
-var user_build_chains_cache_disk_max_size_gb=$(.tart.disk.user-build-chains-cache.max-size-gb)
-var user_vm_images_disk_max_size_gb=$(.tart.disk.vm-images.max-size-gb)
-var enable_boot_command=$(.enable-boot-command)
-var attach_data_disk_during_build=$(call to-bool,$(.attach-data-disk-during-build))
-var user_data_disk_image_path=$(.tart.disk.user.image-path.effective)
-var user_library_disk_image_path=$(.tart.disk.user-library.image-path.effective)
-var git_bare_store_disk_image_path=$(.tart.disk.git-bare-store.image-path.effective)
-var git_store_disk_image_path=$(.tart.disk.git-store.image-path.effective)
-var nix_store_disk_image_path=$(.tart.disk.nix-store.image-path.effective)
-var user_build_chains_cache_disk_image_path=$(.tart.disk.user-build-chains-cache.image-path.effective)
-var user_vm_images_disk_image_path=$(.tart.disk.vm-images.image-path.effective)
endef

define .packer.vars.grow
-var vm_name=$(.tart.vm-name)
-var vm_base_name=$(.tart.base.ref)
-var tart_home=$(.tart.home)
-var enable_build_console=$(call to-bool,$(.debug))
-var recovery_partition_mode=$(.recovery.partition.mode)
-var root_disk_format=$(.tart.disk.root.format)
-var root_disk_size_gb=$(.tart.disk.root.max-size-gb)
-var enable_boot_command=$(.enable-boot-command)
-var macos_bootstrap_ssh_username=$(.bootstrap.ssh.user)
-var macos_bootstrap_ssh_password=$(.bootstrap.ssh.password)
-var enable_boot_command=$(.enable-boot-command)
endef

define .packer.vars.active
$(strip $(if $(strip $(.packer.vars.override)),$(.packer.vars.override),$(.packer.vars.full)))
endef

define .tart.run.disk.args
--disk="$(.tart.disk.user.image-path.effective)$(.tart.run.disk.opts.suffix)"
--disk="$(.tart.disk.user-library.image-path.effective)$(.tart.run.disk.opts.suffix)"
--disk="$(.tart.disk.git-bare-store.image-path.effective)$(.tart.run.disk.opts.suffix)"
--disk="$(.tart.disk.git-store.image-path.effective)$(.tart.run.disk.opts.suffix)"
--disk="$(.tart.disk.nix-store.image-path.effective)$(.tart.run.disk.opts.suffix)"
--disk="$(.tart.disk.user-build-chains-cache.image-path.effective)$(.tart.run.disk.opts.suffix)"
--disk="$(.tart.disk.vm-images.image-path.effective)$(.tart.run.disk.opts.suffix)"
endef

define .tart.run.console.args
$(if $(call opt-enabled,.tart.run.vnc),$(if $(call opt-enabled,.experimental),--vnc-experimental,--vnc),)
$(if $(call opt-enabled,.tart.run.recovery),--recovery,)
$(if $(strip $(.tart.run.net-bridged)),--net-bridged="$(.tart.run.net-bridged)",)
$(if $(strip $(.tart.run.root-disk-opts)),--root-disk-opts="$(.tart.run.root-disk-opts)",)
endef

.PHONY: help validate validate-packer validate-tart clone-from-vanilla ensure-root-disk-size prepare-disks build build-rootfs build-image build-system-only build-with-role-disks build-nix-store-volume build-nix-install build-nxmatic build-super-token-refresh stage-grow stage-nix-store-volume stage-nix-install stage-nxmatic stage-super-token-refresh stage1 stage2 stage3 stage4 stage5 run run-console run-recovery-console info disks-info rm-runtime rm-runtime-one rm-role-disks rm-role-disks-one rm refresh-console shell-fmt shell-check fmt

# Curated set of targets shown by `make help`
.help.targets ?= help validate validate-packer validate-tart build stage1 stage2 stage3 stage4 stage5 build-with-role-disks run run-console run-recovery-console info disks-info refresh-console rm rm-runtime rm-role-disks shell-fmt shell-check fmt

# Curated set of command-line variables shown by `make help`
.help.vars ?= .interactive .debug .experimental .skip .tart.vm-name .tart.vm-names .tart.base.ref .provision.profile .attach-data-disk-during-build .tart.disk.recreate .tart.clone.force .tart.run.recovery .tart.run.vnc .tart.run.net-bridged .account.primary-name .account.secondary-name .auto-login.user

$(.env.file):
	: "Generating $@ from Make variables"
	printf '%s\n' '# Generated by Make. Edit Make variables instead.' 'TART_HOME=$(.tart.home)' > "$@"

help: ## Show available targets
	set +x
	: "Generating help from rules"
	printf "\nPreamble:\n"
	printf "  Build profile: staged Tahoe image pipeline with explicit stage artifacts.\n"
	printf "  Purpose: deterministic grow -> nix-store -> nix-darwin -> nxmatic -> token-refresh flow.\n"
	printf "  Help view: curated (see .help.targets).\n"
	printf "\nTargets:\n"
	{ \
		(grep -he '^[a-zA-Z0-9_.-]\+:.*##' $(MAKEFILE_LIST) || true) | sed -e 's/:.*##/:\t/' ; \
		(grep -he '^\.PHONY:.*##' $(MAKEFILE_LIST) || true) | sed -e 's/ *##/:\t/' | sed -e 's/^\.PHONY: *//' ; \
	} | awk -F ':\t' 'BEGIN { split("$(.help.targets)", keep, " "); for (i in keep) wanted[keep[i]] = 1 } wanted[$$1] && !seen[$$1]++ { printf "  %-18s %s\n", $$1, $$2 }'
	printf "\nCommand-line variables:\n"
	printf "  Usage: make <target> <var>=<value>\n"
	$(foreach v,$(.help.vars),printf "  %-30s %s\n" "$(v)" "$($(v))";)
	printf "\nSummary:\n"
	printf "  Canonical build target is make build (stage1..stage5).\n"
	printf "  Stage5 logs in as super, refreshes primary token, then applies final autologin policy.\n"
	printf "  Non-debug final autologin resolves to primary account; debug keeps secondary account.\n"

validate: validate-packer validate-tart shell-check ## Run all validations (packer, tart, shell)

validate-packer: $(.env.file) ## Validate the Packer template
	$(call .packer.run,validate $(strip $(.packer.vars.active)) $(.template))

validate-tart: $(.env.file) ## Validate Tart CLI access
	$(call .tart.run,--version) >/dev/null
	$(call .tart.run,list) >/dev/null

clone-from-vanilla: validate-tart $(.env.file) ## Clone Tahoe vanilla image into .tart.vm-name (set .tart.clone.force=1 to replace)
	if [[ "$(.tart.clone.force)" == "1" ]]; then
		if $(call .tart.run,get "$(.tart.vm-name)") >/dev/null 2>&1; then
			$(call .tart.run,delete "$(.tart.vm-name)")
		fi
	fi
	if $(call .tart.run,get "$(.tart.vm-name)") >/dev/null 2>&1; then
		: "VM $(.tart.vm-name) already exists; skipping clone (set .tart.clone.force=1 to replace)."
	else
		$(call .tart.run,clone "$(.tart.base.ref)" "$(.tart.vm-name)")
	fi
	$(MAKE) ensure-root-disk-size .tart.vm-name="$(.tart.vm-name)" .tart.disk.root.max-size-gb="$(.tart.disk.root.max-size-gb)"

ensure-root-disk-size: validate-tart $(.env.file) ## Ensure VM root disk is grown to .tart.disk.root.max-size-gb when VM exists
	if $(call .tart.run,get "$(.tart.vm-name)") >/dev/null 2>&1; then
		: "Ensuring root disk size for $(.tart.vm-name): target $(.tart.disk.root.max-size-gb)G"
		$(call .tart.run,set "$(.tart.vm-name)" --disk-size "$(.tart.disk.root.max-size-gb)")
	else
		: "VM $(.tart.vm-name) not found; skipping root disk resize."
	fi

prepare-disks: ## Create role disk images when enabled and missing
ifneq ($(call opt-enabled,.attach-data-disk-during-build),)
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.user.image-path.effective))
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.user-library.image-path.effective))
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.git-bare-store.image-path.effective))
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.git-store.image-path.effective))
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.nix-store.image-path.effective))
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.user-build-chains-cache.image-path.effective))
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.vm-images.image-path.effective))
	$(call .tart.disk.cmd.prepare-image,Data-Home-$(.data.home-user),$(.tart.disk.user.image-path.effective),$(.tart.disk.user.max-size-gb))
	$(call .tart.disk.cmd.prepare-image,Data Build Chains Cache $(.data.home-user),$(.tart.disk.user-build-chains-cache.image-path.effective),$(.tart.disk.user-build-chains-cache.max-size-gb))
	$(call .tart.disk.cmd.prepare-image,Data Library Cache $(.data.home-user),$(.tart.disk.user-library.image-path.effective),$(.tart.disk.user-library.max-size-gb))
	$(call .tart.disk.cmd.prepare-image,Data VM Images $(.data.home-user),$(.tart.disk.vm-images.image-path.effective),$(.tart.disk.vm-images.max-size-gb))
	$(call .tart.disk.cmd.prepare-image,Git Store,$(.tart.disk.git-store.image-path.effective),$(.tart.disk.git-store.max-size-gb))
	$(call .tart.disk.cmd.prepare-image,Git Bare Store,$(.tart.disk.git-bare-store.image-path.effective),$(.tart.disk.git-bare-store.max-size-gb))
	$(call .tart.disk.cmd.prepare-image,Nix Store,$(.tart.disk.nix-store.image-path.effective),$(.tart.disk.nix-store.max-size-gb))
else
	: "Role disk attachment disabled (.attach-data-disk-during-build=$(strip $(.attach-data-disk-during-build))); skipping image preparation."
endif

build-image: $(.env.file) ## Internal: execute packer build with active template/flags
	if [[ "$(call to-bool,$(.attach-data-disk-during-build))" == "true" ]]; then $(MAKE) prepare-disks .tart.disk.recreate="$(.tart.disk.recreate)" .attach-data-disk-during-build="$(.attach-data-disk-during-build)" .tart.disk.blank.fs="$(.tart.disk.blank.fs)"; else : "Skipping prepare-disks because .attach-data-disk-during-build=$(strip $(.attach-data-disk-during-build))"; fi
	$(call .packer.run,build $(.packer.flags.interactive) $(.packer.flags.failure) $(strip $(.packer.vars.active)) $(.template))

$(.tart.stage1.vm.path): ## Ensure stage1 VM artifact exists (bootstraps via build-system-only when missing)
	if [[ -d "$@" ]]; then
		: "Reusing existing stage1 VM artifact: $@"
	else
		: "Stage1 VM artifact missing: $@; bootstrapping via build-system-only"
		$(MAKE) build-system-only .tart.vm-name="$(.tart.stage1-vm-name)"
	fi

$(.tart.stage1.vm.state): $(.tart.stage1.vm.path) ## Track stage1 VM artifact readiness state
	if [[ -d "$(.tart.stage1.vm.path)" ]]; then
		printf '%s\n' "stage1_vm_name=$(.tart.stage1-vm-name)" "stage1_vm_path=$(.tart.stage1.vm.path)" "generated_at=$$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$@"
		: "Updated stage1 VM state: $@"
	else
		: "Stage1 VM path missing unexpectedly: $(.tart.stage1.vm.path)"
		exit 1
	fi

build-rootfs: $(.tart.stage1.vm.state) ## Ensure stage1 VM artifact exists and is grown

$(.tart.stage2.vm.path): $(.tart.stage1.vm.state) ## Ensure stage2 VM artifact exists (nix-store-volume profile)
	if [[ -d "$@" ]]; then
		: "Reusing existing stage2 VM artifact: $@"
	else
		: "Stage2 VM artifact missing: $@; bootstrapping via build-nix-store-volume"
		$(MAKE) build-nix-store-volume
	fi

$(.tart.stage2.vm.state): $(.tart.stage2.vm.path) ## Track stage2 VM artifact readiness state
	if [[ -d "$(.tart.stage2.vm.path)" ]]; then
		printf '%s\n' "stage2_vm_name=$(.tart.stage2-vm-name)" "stage2_vm_path=$(.tart.stage2.vm.path)" "stage2_profile=nix-store-volume" "generated_at=$$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$@"
		: "Updated stage2 VM state: $@"
	else
		: "Stage2 VM path missing unexpectedly: $(.tart.stage2.vm.path)"
		exit 1
	fi

$(.tart.stage3.vm.path): $(.tart.stage2.vm.state) ## Ensure stage3 VM artifact exists (nix-install profile)
	if [[ -d "$@" ]]; then
		: "Reusing existing stage3 VM artifact: $@"
	else
		: "Stage3 VM artifact missing: $@; bootstrapping via build-nix-install"
		$(MAKE) build-nix-install
	fi

$(.tart.stage3.vm.state): $(.tart.stage3.vm.path) ## Track stage3 VM artifact readiness state
	if [[ -d "$(.tart.stage3.vm.path)" ]]; then
		printf '%s\n' "stage3_vm_name=$(.tart.stage3-vm-name)" "stage3_vm_path=$(.tart.stage3.vm.path)" "stage3_profile=nix-install" "generated_at=$$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$@"
		: "Updated stage3 VM state: $@"
	else
		: "Stage3 VM path missing unexpectedly: $(.tart.stage3.vm.path)"
		exit 1
	fi

$(.tart.stage4.vm.path): $(.tart.stage3.vm.state) ## Ensure stage4 VM artifact exists (nxmatic profile)
	if [[ -d "$@" ]]; then
		: "Reusing existing stage4 VM artifact: $@"
	else
		: "Stage4 VM artifact missing: $@; bootstrapping via build-nxmatic"
		$(MAKE) build-nxmatic
	fi

$(.tart.stage4.vm.state): $(.tart.stage4.vm.path) ## Track stage4 VM artifact readiness state
	if [[ -d "$(.tart.stage4.vm.path)" ]]; then
		printf '%s\n' "stage4_vm_name=$(.tart.stage4-vm-name)" "stage4_vm_path=$(.tart.stage4.vm.path)" "stage4_profile=nxmatic" "generated_at=$$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$@"
		: "Updated stage4 VM state: $@"
	else
		: "Stage4 VM path missing unexpectedly: $(.tart.stage4.vm.path)"
		exit 1
	fi

$(.tart.final.vm.state): $(.tart.vm.path) ## Track final VM artifact readiness state
	if [[ -d "$(.tart.vm.path)" ]]; then
		printf '%s\n' "final_vm_name=$(.tart.vm-name)" "final_vm_path=$(.tart.vm.path)" "final_profile=super-token-refresh" "generated_at=$$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$@"
		: "Updated final VM state: $@"
	else
		: "Final VM path missing unexpectedly: $(.tart.vm.path)"
		exit 1
	fi

build: stage5 ensure-root-disk-size ## Canonical 5-stage flow: grow -> nix-store-volume -> nix-darwin -> nxmatic -> super-token-refresh

build-system-only: .template=$(.template.grow)
build-system-only: .attach-data-disk-during-build=0
build-system-only: .recovery.partition.mode=relocate
build-system-only: .packer.vars.override=$(.packer.vars.grow)
build-system-only: build-image ## Build with vanilla grow-only template (recommended first bootstrap step)

stage1: override .tart.vm-name:=$(.tart.stage1-vm-name)
stage1: build-system-only ## Stage 1 canonical flow: root-only bootstrap build

stage-grow: stage1 ## Alias: stage 1 grow-only artifact

build-nix-store-volume: .template=$(.template.customize)
build-nix-store-volume: override .tart.vm-name:=$(.tart.stage2-vm-name)
build-nix-store-volume: override .tart.base.ref:=$(.tart.stage1-vm-name)
build-nix-store-volume: .attach-data-disk-during-build=1
build-nix-store-volume: .recovery.partition.mode=keep
build-nix-store-volume: .provision.profile=nix-store-volume
build-nix-store-volume: build-image ## Build stage2 artifact: initialize role volumes (incl Nix store volume)

stage-nix-store-volume: $(.tart.stage2.vm.state) ## Stage 2 artifact: nix-store-volume

build-nix-install: .template=$(.template.customize)
build-nix-install: override .tart.vm-name:=$(.tart.stage3-vm-name)
build-nix-install: override .tart.base.ref:=$(.tart.stage2-vm-name)
build-nix-install: .attach-data-disk-during-build=1
build-nix-install: .recovery.partition.mode=keep
build-nix-install: .provision.profile=nix-install
build-nix-install: build-image ## Build stage3 artifact: nix installer/bootstrap execution

stage-nix-install: $(.tart.stage3.vm.state) ## Stage 3 artifact: nix-install

build-nxmatic: .template=$(.template.customize)
build-nxmatic: override .tart.vm-name:=$(.tart.stage4-vm-name)
build-nxmatic: override .tart.base.ref:=$(.tart.stage3-vm-name)
build-nxmatic: .attach-data-disk-during-build=1
build-nxmatic: .recovery.partition.mode=keep
build-nxmatic: .provision.profile=nxmatic
build-nxmatic: build-image ## Build stage4 artifact: nxmatic customization

stage-nxmatic: $(.tart.stage4.vm.state) ## Stage 4 artifact: nxmatic customization

build-super-token-refresh: .template=$(.template.customize)
build-super-token-refresh: override .tart.base.ref:=$(.tart.stage4-vm-name)
build-super-token-refresh: .attach-data-disk-during-build=1
build-super-token-refresh: .recovery.partition.mode=keep
build-super-token-refresh: .provision.profile=super-token-refresh
build-super-token-refresh: .auto-login.user=$(.account.secondary-name)
build-super-token-refresh: .bootstrap.ssh.user=$(.account.secondary-name)
build-super-token-refresh: .bootstrap.ssh.password=$(.account.secondary-password)
build-super-token-refresh: build-image ## Build stage5 artifact: super autologin + primary token refresh

stage-super-token-refresh: $(.tart.stage4.vm.state) build-super-token-refresh $(.tart.final.vm.state) ## Stage 5 artifact: final VM

stage2: stage-nix-store-volume ## Stage 2 canonical flow: nix store volume stage
stage3: stage-nix-install ## Stage 3 canonical flow: nix-darwin stage
stage4: stage-nxmatic ## Stage 4 canonical flow: nxmatic customization stage
stage5: stage-super-token-refresh ## Stage 5 canonical flow: super token refresh + final login policy

build-with-role-disks: .template=$(.template.customize)
build-with-role-disks: .tart.base.ref=$(.tart.stage1-vm-name)
build-with-role-disks: .attach-data-disk-during-build=1
build-with-role-disks: .recovery.partition.mode=keep
build-with-role-disks: .provision.profile=full
build-with-role-disks: build-image ## Full rebuild with role disks attached (base=stage1 artifact)

run: prepare-disks ensure-root-disk-size $(.env.file) ## Run the built VM with all role disks attached
	$(call .tart.run,run $(.tart.vm-name) $(strip $(.tart.run.disk.args)))

run-console: prepare-disks ensure-root-disk-size $(.env.file) ## Run VM with console troubleshooting defaults (Screen Sharing VNC + optional bridge/recovery)
	$(call .tart.run,run $(.tart.vm-name) $(strip $(.tart.run.console.args) $(.tart.run.disk.args) $(.tart.run.extra-args)))

run-recovery-console: .tart.run.recovery=1
run-recovery-console: run-console ## Run VM in recovery mode with console troubleshooting defaults

info: $(.env.file) ## Show Tart VM details
	$(call .tart.run,list)
	$(call .tart.run,get $(.tart.vm-name))

disks-info: ## Show role disk files and sizes
	$(call .tart.disk.cmd.show-info,Data-Home-$(.data.home-user),$(.tart.disk.user.image-path.effective))
	$(call .tart.disk.cmd.show-info,Data Library Cache $(.data.home-user),$(.tart.disk.user-library.image-path.effective))
	$(call .tart.disk.cmd.show-info,Git Bare Store,$(.tart.disk.git-bare-store.image-path.effective))
	$(call .tart.disk.cmd.show-info,Git Store,$(.tart.disk.git-store.image-path.effective))
	$(call .tart.disk.cmd.show-info,Nix Store,$(.tart.disk.nix-store.image-path.effective))
	$(call .tart.disk.cmd.show-info,Data Build Chains Cache $(.data.home-user),$(.tart.disk.user-build-chains-cache.image-path.effective))
	$(call .tart.disk.cmd.show-info,Data VM Images $(.data.home-user),$(.tart.disk.vm-images.image-path.effective))

rm-runtime: validate-tart $(.env.file) ## Stop runtime and remove VM artifact/state for each name in .tart.vm-names
	$(foreach vm,$(.tart.vm-names),$(MAKE) --no-print-directory rm-runtime-one .tart.vm-name="$(vm)";)

rm-runtime-one: validate-tart $(.env.file) ## Internal: stop runtime and remove VM artifact/state for .tart.vm-name
	$(call .tart.run,stop "$(.tart.vm-name)") >/dev/null 2>&1 || true
	if $(call .tart.run,get "$(.tart.vm-name)") >/dev/null 2>&1; then
		: "Deleting VM $(.tart.vm-name)"
		$(call .tart.run,delete "$(.tart.vm-name)")
	else
		: "VM $(.tart.vm-name) not found; skipping VM delete."
	fi
	if [[ -d "$(.tart.vm.path)" ]]; then
		: "Removing VM path $(.tart.vm.path)"
		rm -rf "$(.tart.vm.path)"
	fi
	if [[ "$(.tart.vm-name)" == "$(.tart.stage1-vm-name)" ]]; then
		rm -f "$(.tart.stage1.vm.state)"
		: "Removed stage1 state file $(.tart.stage1.vm.state)"
	fi
	if [[ "$(.tart.vm-name)" == "$(.tart.stage2-vm-name)" ]]; then
		rm -f "$(.tart.stage2.vm.state)"
		: "Removed stage2 state file $(.tart.stage2.vm.state)"
	fi
	if [[ "$(.tart.vm-name)" == "$(.tart.stage3-vm-name)" ]]; then
		rm -f "$(.tart.stage3.vm.state)"
		: "Removed stage3 state file $(.tart.stage3.vm.state)"
	fi
	if [[ "$(.tart.vm-name)" == "$(.tart.stage4-vm-name)" ]]; then
		rm -f "$(.tart.stage4.vm.state)"
		: "Removed stage4 state file $(.tart.stage4.vm.state)"
	fi
	rm -f "$(.tart.final.vm.state)"
	: "Removed final VM state file $(.tart.final.vm.state)"

rm-role-disks: ## Remove role disks for each name in .tart.vm-names (non-interactive)
	$(foreach vm,$(.tart.vm-names),$(MAKE) --no-print-directory rm-role-disks-one .tart.vm-name="$(vm)";)

rm-role-disks-one: ## Internal: remove role disks for .tart.vm-name (non-interactive)
	rm -f $(.tart.disk.user.image-path.effective) $(.tart.disk.user-library.image-path.effective) $(.tart.disk.git-bare-store.image-path.effective) $(.tart.disk.git-store.image-path.effective) $(.tart.disk.nix-store.image-path.effective) $(.tart.disk.user-build-chains-cache.image-path.effective) $(.tart.disk.vm-images.image-path.effective)
	rm -rf "$(.tart.home)/disks/$(.tart.vm-name)"
	: "Removed role disks for $(.tart.vm-name)."

rm: rm-runtime ## Remove VM runtime/artifact for .tart.vm-names; remove role disks unless .skip includes 'disks'
	if [[ " $(.skip) " == *" disks "* ]]; then
		: "Skipping role disk removal because .skip includes 'disks'."
		: "Removed VM runtime/artifact for: $(.tart.vm-names)."
	else
		$(MAKE) --no-print-directory rm-role-disks .tart.vm-names="$(.tart.vm-names)"
		: "Removed VM runtime/artifact and role disks for: $(.tart.vm-names)."
	fi

refresh-console: rm build run-console ## Fresh credential-debug flow: wipe VM+disks, rebuild, launch with console

shell-fmt: ## Format shell scripts if shfmt is available
	if command -v shfmt >/dev/null 2>&1; then
		shfmt -w scripts/*.sh
	else
		: "shfmt not found, skipping."
	fi

shell-check: ## Lint shell scripts if shellcheck is available
	if command -v shellcheck >/dev/null 2>&1; then
		shellcheck scripts/*.sh
	else
		: "shellcheck not found, skipping."
	fi

fmt: ## Alias for shell-fmt
	$(MAKE) shell-fmt
