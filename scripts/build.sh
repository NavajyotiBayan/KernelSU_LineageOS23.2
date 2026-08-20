#!/usr/bin/env bash

# Prepare the defconfig, merge LineageOS/Dubai config fragments,
# and compile the kernel.

set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=scripts/kernelsu.sh
. "$(dirname "${BASH_SOURCE[0]}")/kernelsu.sh"

# shellcheck source=scripts/patches.sh
. "$(dirname "${BASH_SOURCE[0]}")/patches.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}

WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}

ARCH=${ARCH:-arm64}

OUT="${KERNEL_DIR}/out"

DEFCONFIG_PATH="${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}"

# ------------------------------------------------------------- defconfig ---

prepare_defconfig() {

	group "Preparing defconfig"

	[ -f "$DEFCONFIG_PATH" ] \
		|| die "defconfig not found: arch/${ARCH}/configs/${KERNEL_CONFIG}

Available: $(ls "${KERNEL_DIR}/arch/${ARCH}/configs/" | head -20 | tr '\n' ' ')"

	cp "$DEFCONFIG_PATH" "${WORKSPACE}/defconfig.orig"

	local kver
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")

	# ---------------------------------------------------------
	# KernelSU configuration
	# ---------------------------------------------------------

	if [ "${KSU_VARIANT:-none}" != "none" ]; then

		kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU

		ksu_hook_configs \
			"${KSU_VARIANT}" \
			"${KSU_HOOK_MODE:-auto}" \
			"$DEFCONFIG_PATH" \
			"$kver"

		if is_true "${ENABLE_SUSFS:-false}"; then
			susfs_defconfig "$DEFCONFIG_PATH"
		fi

		if is_true "${ENABLE_KPM:-false}"; then

			kconf_set_many "$DEFCONFIG_PATH" \
				CONFIG_KPM=y \
				CONFIG_KALLSYMS=y \
				CONFIG_KALLSYMS_ALL=y

		fi

	fi

	# ---------------------------------------------------------
	# OverlayFS
	# ---------------------------------------------------------

	if is_true "${ADD_OVERLAYFS_CONFIG:-false}"; then
		kconf_enable "$DEFCONFIG_PATH" CONFIG_OVERLAY_FS
	fi

	# ---------------------------------------------------------
	# Optional Kprobe configuration
	#
	# Disabled in our Dubai profile because the kernel already
	# has KPROBES and KernelSU Next auto-selects manual hooks
	# for this 5.4 kernel.
	# ---------------------------------------------------------

	if is_true "${ADD_KPROBES_CONFIG:-false}"; then

		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_MODULES=y \
			CONFIG_KPROBES=y \
			CONFIG_HAVE_KPROBES=y \
			CONFIG_KPROBE_EVENTS=y

	fi

	# ---------------------------------------------------------
	# Optional LTO disable
	# ---------------------------------------------------------

	if is_true "${DISABLE_LTO:-false}"; then

		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_LTO=n \
			CONFIG_LTO_CLANG=n \
			CONFIG_LTO_CLANG_FULL=n \
			CONFIG_LTO_CLANG_THIN=n \
			CONFIG_THINLTO=n \
			CONFIG_LTO_NONE=y

	fi

	# ---------------------------------------------------------
	# Optional CC_WERROR disable
	# ---------------------------------------------------------

	if is_true "${DISABLE_CC_WERROR:-false}"; then
		kconf_disable "$DEFCONFIG_PATH" CONFIG_CC_WERROR
	fi

	# ---------------------------------------------------------
	# Extra defconfig options
	# ---------------------------------------------------------

	if [ -n "${EXTRA_DEFCONFIG:-}" ]; then

		local kv

		# shellcheck disable=SC2086
		for kv in $(printf '%s' "$EXTRA_DEFCONFIG" | tr '\n' ' '); do

			[ -n "$kv" ] || continue

			case "$kv" in

				*=*)
					kconf_set \
						"$DEFCONFIG_PATH" \
						"${kv%%=*}" \
						"${kv#*=}"
					;;

				*)
					warn "ignoring malformed EXTRA_DEFCONFIG entry '${kv}' (want CONFIG_X=y)"
					;;

			esac

		done

	fi

	# ---------------------------------------------------------
	# Stable LOCALVERSION
	# ---------------------------------------------------------

	if [ -n "${KERNEL_NAME:-}" ]; then

		kconf_set \
			"$DEFCONFIG_PATH" \
			CONFIG_LOCALVERSION \
			"\"-${KERNEL_NAME}\""

		if [ -f "${KERNEL_DIR}/scripts/setlocalversion" ]; then

			sed -i \
				's/echo "\$res"/echo "\$res"/; s/-dirty//g' \
				"${KERNEL_DIR}/scripts/setlocalversion"

		fi

	fi

	info "defconfig changes:"

	diff -u \
		"${WORKSPACE}/defconfig.orig" \
		"$DEFCONFIG_PATH" |
		sed -n '4,$p' |
		sed 's/^/ /' ||
		true

	endgroup
}

# ------------------------------------------------------ config fragments ---

merge_lineage_fragments() {

	group "Merging LineageOS Dubai kernel configuration"

	local merge_script="${KERNEL_DIR}/scripts/kconfig/merge_config.sh"

	[ -f "$merge_script" ] \
		|| die "merge_config.sh not found: ${merge_script}"

	[ -f "${OUT}/.config" ] \
		|| die "base .config was not generated"

	local fragments=()

	# Motorola SM7325 common configuration
	if [ -f "${KERNEL_DIR}/arch/${ARCH}/configs/vendor/lineage_moto-lahaina.config" ]; then

		fragments+=(
			"${KERNEL_DIR}/arch/${ARCH}/configs/vendor/lineage_moto-lahaina.config"
		)

	else

		die "missing Motorola fragment:
arch/${ARCH}/configs/vendor/lineage_moto-lahaina.config"

	fi

	# Motorola Edge 30 / Dubai configuration
	if [ -f "${KERNEL_DIR}/arch/${ARCH}/configs/vendor/lineage_dubai.config" ]; then

		fragments+=(
			"${KERNEL_DIR}/arch/${ARCH}/configs/vendor/lineage_dubai.config"
		)

	else

		die "missing Dubai fragment:
arch/${ARCH}/configs/vendor/lineage_dubai.config"

	fi

	info "Base configuration:"
	info "  ${KERNEL_CONFIG}"

	info "Applying configuration fragments:"

	local fragment

	for fragment in "${fragments[@]}"; do
		info "  $(basename "$fragment")"
	done

	# Merge the LineageOS fragments into the generated .config.
	#
	# -m = merge only; do not execute make yet.
	#
	# This preserves the KernelSU modifications already made to
	# the base defconfig.
	(
        cd "$KERNEL_DIR"

        "$merge_script" \
            -m \
            -O "$OUT" \
            "${OUT}/.config" \
            "${fragments[@]}"
    )

	  # Resolve dependencies and generate the final configuration.
  (
    cd "$KERNEL_DIR"

    # shellcheck disable=SC2046
    make \
      CC="clang" \
      $(make_args) \
      olddefconfig
  )

  # ---------------------------------------------------------
  # KernelSU final configuration enforcement
  # ---------------------------------------------------------

  info "Enforcing KernelSU configuration in final .config"

  kconf_set_many "${OUT}/.config" \
    CONFIG_KSU=y

  # Re-resolve dependencies after forcing KernelSU.
  (
    cd "$KERNEL_DIR"

    # shellcheck disable=SC2046
    make \
      CC="clang" \
      $(make_args) \
      olddefconfig
  )

  # ---------------------------------------------------------
  # Hard verification
  # ---------------------------------------------------------

  if ! grep -q '^CONFIG_KSU=y$' "${OUT}/.config"; then
    die "CONFIG_KSU=y is missing from final .config"
  fi

  ok "CONFIG_KSU=y confirmed in final .config"

  ok "LineageOS Dubai configuration merged"

	# ---------------------------------------------------------
	# Verify important configuration values
	# ---------------------------------------------------------

	info "Checking final kernel configuration..."

	local required_config

	for required_config in \
    CONFIG_KSU \
    CONFIG_KPROBES \
    CONFIG_HAVE_KPROBES \
    CONFIG_KPROBE_EVENTS \
    CONFIG_MODULES \
    CONFIG_MODVERSIONS \
    CONFIG_OVERLAY_FS
	do

		if grep -q "^${required_config}=y" "${OUT}/.config"; then

			ok "${required_config}=y"

		else

			if [ "$required_config" = "CONFIG_KSU" ]; then
    die "${required_config}=y is required but missing from final .config"
else
    warn "${required_config} is not enabled in final .config"
fi

		fi

	done

	# Verify Dubai-specific configuration survived the merge.
	if grep -q "^CONFIG_GTP_FOD=y" "${OUT}/.config"; then
		ok "Dubai touchscreen configuration present"
	else
		warn "CONFIG_GTP_FOD not present in final .config"
	fi

	endgroup
}

# ----------------------------------------------------------------- build ---

make_args() {

	printf '%s' "O=out ARCH=${ARCH}"

	[ -n "${CUSTOM_CMDS:-}" ] &&
		printf ' %s' "$CUSTOM_CMDS"

	[ -n "${EXTRA_CMDS:-}" ] &&
		printf ' %s' "$EXTRA_CMDS"

	[ -n "${GCC_64:-}" ] &&
		printf ' %s' "$GCC_64"

	[ -n "${GCC_32:-}" ] &&
		printf ' %s' "$GCC_32"

	if is_true "${USE_LLVM:-false}"; then

		printf ' LLVM=1 LLVM_IAS=1'

		[ -n "${GCC_64:-}" ] ||
			printf ' CROSS_COMPILE=aarch64-linux-gnu-'

	fi

}

build_kernel() {

	group "Building kernel"

	export PATH="${CLANG_PATH:-}:${PATH}"

	export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-Github-Action}

	export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-kernelsu-action}

	# DISABLE_LTO is an action setting, not a Kbuild compiler variable.
	unset DISABLE_LTO

	# Custom manager signature
	if [ -n "${KSU_EXPECTED_SIZE:-}" ] &&
	   [ -n "${KSU_EXPECTED_HASH:-}" ]; then

		export KSU_EXPECTED_SIZE
		export KSU_EXPECTED_HASH

		info "using custom manager signature (size=${KSU_EXPECTED_SIZE})"

	fi

	local cc="clang"
	local args

	args=$(make_args)

	if is_true "${ENABLE_CCACHE:-true}" &&
	   command -v ccache >/dev/null; then

		cc="ccache clang"

		export CCACHE_DIR="${CCACHE_DIR:-${WORKSPACE}/.ccache}"

		info "ccache enabled (dir: ${CCACHE_DIR})"

	fi

	cd "$KERNEL_DIR"

	# ---------------------------------------------------------
	# Step 1: Generate the base configuration
	# ---------------------------------------------------------

	info "Generating base defconfig: ${KERNEL_CONFIG}"

	# shellcheck disable=SC2086
	make \
		-j"$(nproc --all)" \
		CC=clang \
		$args \
		"${KERNEL_CONFIG}" ||
		die "defconfig generation failed"

	# ---------------------------------------------------------
	# Step 2: Merge Motorola + Dubai LineageOS fragments
	# ---------------------------------------------------------
	info "Copying config fragments from repository to kernel tree"
	# ${WORKSPACE}/.. is where your GitHub repository files are located
	cp "${WORKSPACE}/../lineage_moto-lahaina.config" "${KERNEL_DIR}/arch/${ARCH}/configs/vendor/"
	cp "${WORKSPACE}/../lineage_dubai.config" "${KERNEL_DIR}/arch/${ARCH}/configs/vendor/"
	merge_lineage_fragments
	echo "===== KernelSU symbol inspection ====="

echo "--- KSU hook mode ---"
echo "KSU_VARIANT=${KSU_VARIANT:-}"
echo "KSU_REF=${KSU_REF:-}"
echo "KSU_HOOK_MODE=${KSU_HOOK_MODE:-}"
echo "KSU_HOOK_MODE_RESOLVED=${KSU_HOOK_MODE_RESOLVED:-}"

echo "--- ksu_input_hook references ---"
grep -Rns \
    "ksu_input_hook" \
    "${KERNEL_DIR}/KernelSU" \
    "${KERNEL_DIR}/drivers/kernelsu" \
    2>/dev/null || true

echo "--- ksu_hide_init_thread references ---"
grep -Rns \
    "ksu_hide_init_thread" \
    "${KERNEL_DIR}/KernelSU" \
    "${KERNEL_DIR}/drivers/kernelsu" \
    2>/dev/null || true

echo "--- KernelSU/Kprobe configuration ---"
grep -E \
    '^(CONFIG_KSU|CONFIG_KSU_KPROBES_HOOK|CONFIG_KSU_MANUAL_HOOK|CONFIG_KPROBES|CONFIG_HAVE_KPROBES|CONFIG_KPROBE_EVENTS)=' \
    "${OUT}/.config" \
    2>/dev/null || true

echo "===== End KernelSU symbol inspection ====="

	# ---------------------------------------------------------
	# Step 3: Build kernel using the final .config
	# ---------------------------------------------------------

	info "Building kernel with final LineageOS Dubai configuration"

	# shellcheck disable=SC2086
	make \
		-j"$(nproc --all)" \
		CC="$cc" \
		$args ||
		die "kernel build failed"

	endgroup
}

# --------------------------------------------------------------- verify ---

check_output() {

	group "Checking build output"

	local boot="${OUT}/arch/${ARCH}/boot"

	local image="${boot}/${KERNEL_IMAGE_NAME}"

	[ -f "$image" ] ||
		die "expected kernel image not found: ${image}

Built files: $(ls "$boot" 2>/dev/null | tr '\n' ' ')"

	ok "kernel image: ${KERNEL_IMAGE_NAME} ($(du -h "$image" | cut -f1))"

	export_env CHECK_FILE_IS_OK true

	# ---------------------------------------------------------
	# DTBO
	# ---------------------------------------------------------

	if is_true "${NEED_DTBO:-false}"; then

		[ -f "${boot}/dtbo.img" ] ||
			die "NEED_DTBO=true but ${boot}/dtbo.img was not produced"

		export_env CHECK_DTBO_IS_OK true

		ok "dtbo.img present"

	fi

	# ---------------------------------------------------------
	# KPM
	# ---------------------------------------------------------

	if is_true "${ENABLE_KPM:-false}"; then
		kpm_patch_image "$image"
	fi

	# ---------------------------------------------------------
	# Kernel release
	# ---------------------------------------------------------

	if [ -f "${OUT}/include/generated/utsrelease.h" ]; then

		local rel

		rel=$(sed -nE \
			's/.*UTS_RELEASE[[:space:]]+"([^"]+)".*/\1/p' \
			"${OUT}/include/generated/utsrelease.h")

		export_env KERNEL_RELEASE "$rel"

		ok "kernel release: ${rel}"

		summary "| Kernel release | \`${rel}\` |"

	fi

	# ---------------------------------------------------------
	# Final configuration archive
	# ---------------------------------------------------------

	if [ -f "${OUT}/.config" ]; then

		cp \
			"${OUT}/.config" \
			"${WORKSPACE}/final-kernel-config"

		ok "final .config saved"

	fi

	endgroup
}

# ---------------------------------------------------------------- main ---

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then

	case "${1:-all}" in

		defconfig)
			prepare_defconfig
			;;

		compile)
			build_kernel
			;;

		check)
			check_output
			;;

		all)
			prepare_defconfig
			build_kernel
			check_output
			;;

		*)
			die "unknown build step '$1'"

			;;

	esac

fi
