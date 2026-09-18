# SDMapper V1 driver for Nextor 3

This repository contains a [Nextor](https://github.com/Konamiman/Nextor) 3 driver for the [SDMapper V1](https://github.com/fbelavenuto/msxsdmapper) cartridge (ASCII16 MegaROM, two SD slots, optional 512K Mapper/MegaRAM). It produces a Nextor ROM image that combines a Nextor kernel (v3.0 or newer) base file with this driver, ready to be flashed to the cartridge.

The Nextor 3 driver structure is based on Manuel Pazos' [MegaFlashROM SCC+ SD](https://www.msxcartridgeshop.com/) driver. Hardware access follows the Nextor 2 SDMapper driver by Fabio Belavenuto and FRS.

The driver uses **no page-3 work area** (`WORK_AREA_SIZE = 0`). Per-slot state lives in the cartridge's **8-byte SLTWRK** window (the expanded-slot budget: turning the mapper switch off disables the on-cartridge expander so the ROM can sit in a host expanded slot, and even with the mapper on the ROM is still one subslot). There is **no ROM disk**: SDMapper V1's flash has no usable spare space for one.

The 4-byte transfer trampoline is installed at the first I/O that needs it: device query 8 (`READ_BEFORE_INIT`, so Nextor can read `_NEXTOR.PSF` before the driver is initialized) and again at `DRV_INIT`. Putting it only in `DRV_INIT` is too late — `SLTWRK` is uninitialized when that query runs, and `jp (ix)` would walk off the trampoline. STATUS is written at the same time (`ld (ix+STATUS),c`, same as `DRV_INIT`); it is not read first. The remaining bytes are two STATUS flags (one per SD slot):

| Offset | Contents |
| ------ | -------- |
| `+0` | `NOP` (so `jp (ix)` from SD slot 0 lands on the trampoline) |
| `+1..+3` | Turbo R (`MSXVER >= 3`): `LDIR` + `RET`. Otherwise: `JP transfer_z80` (512 unrolled `LDI` in ROM). Z80 mode on a Turbo R still uses `LDIR`. |
| `+4` / `+5` | `STATUS0` / `STATUS1`. Bit 0 = this byte is SD slot 1 (`BIT_SLOT1`); bit 1 = SDHC/SDXC block addressing; bit 2 = `InitSD` succeeded since `GET_STATUS` last consumed the flag. |
| `+6..+7` | Unused. |

512-byte SPI transfers go through `jp (ix)` into that trampoline. `GETWRK` returns `IX = window + SD-slot`, so STATUS is always `(ix+4)` and the currently selected card is the `BIT_SLOT1` flag rather than a separate current-slot byte.

Two variants are built by default:

| Output                                      | Notes                                              |
| ------------------------------------------- | -------------------------------------------------- |
| `Nextor-<ver>.SDMapperV1.1-slot.ROM`        | Exposes only SD slot 1.                            |
| `Nextor-<ver>.SDMapperV1.2-slots.ROM`       | Both SD slots (the hardware default).              |

`<ver>` is the kernel version reported by the Nextor SDK (`nextor-kernel-version.txt`), and any kernel-base variant suffix (e.g. `.NO_UNDOC`) is picked up automatically from the `NEXTOR_BASE` filename, see [Building](#building) below.

The cartridge mapper is ASCII16 (implemented by the SDMapper V1 CPLD). Bank-switching code comes from the Nextor SDK (`asm/chgbnk/ascii16.asm`).

## Hardware notes

SDMapper V1 SPI window (see the [original driver](https://github.com/fbelavenuto/msxsdmapper/tree/master/driver)):

| Address       | Role |
| ------------- | ---- |
| `4000h–47FFh` | SPI data transfer window |
| `4800h`       | Status / chip-select. Read: card present (b0/b1, 0 = present), write-protect (b2/b3), SW0/SW1 (b4/b5), SPI busy (b7). Write: slot chip-select (0 = selected). |
| `6000h`       | ASCII16 bank select (Nextor kernel) |
| `6001h`       | Mode config (write): 0 = ROM, 1 = SPI enabled |

Driver code that runs with SPI enabled is placed at `4900h` and above, so it is not overlaid by the SPI window.

A switch selects Mapper vs MegaRAM; another switch disables both (and the slot expander), which is useful when the host MSX already has a mapper.

## Repository contents

| File              | Purpose                                                                                  |
| ----------------- | ---------------------------------------------------------------------------------------- |
| `driver.asm`      | The SDMapper V1 driver.                                                                  |
| `Makefile`        | Build rules; see below.                                                                  |
| `docker-build.sh` | Wrapper that builds the ROMs in the Nextor dev Docker image (no local toolchain needed). |
| `build-all.sh`    | Builds the ROMs against every kernel base-file variant found in a directory.             |
| `external/Nextor` | Git submodule pointing at the Nextor repo, sparse-checkout to the `sdk/` directory only. |

## Development environment

The quickest path needs **nothing but Docker**: see [Building with the Nextor dev Docker image](#building-with-the-nextor-dev-docker-image) below, which supplies the toolchain, the SDK and the kernel base files for you (no submodule or base file to fetch). To build with a local toolchain instead, you need:

- [**Nestor80**](https://github.com/Konamiman/Nestor80) (`N80`) on your `PATH`, or pointed at via the `N80` make variable.
- **`mknexrom`** on your `PATH`, or pointed at via the `MKNEXROM` make variable. The source lives in the Nextor repository under `buildtools/sources/mknexrom.c`.
- A POSIX **`make`** and `cat`.
- A Nextor kernel base file and the Nextor SDK (the `external/Nextor` submodule, set up with `make setup`).

## Cloning the repository

This repository uses a git submodule to pull in the Nextor SDK; clone with `--recurse-submodules` and then configure the submodule for a sparse checkout of the `sdk/` directory (the only thing this driver consumes from Nextor):

```sh
git clone --recurse-submodules <this-repo-url> [<target-dir>]
cd <target-dir>/external/Nextor
git sparse-checkout init --cone
git sparse-checkout set sdk
cd ../..
```

If you already cloned without `--recurse-submodules`, run `git submodule update --init` first.

If you have a local clone of Nextor and want the submodule to point at it (e.g. while developing the SDK locally), override the URL once:

```sh
git config submodule.external/Nextor.url /path/to/your/local/Nextor
git submodule sync
git submodule update --init
```

### If you'd rather not fetch the full Nextor repository

The sequence above clones the entire Nextor repository before the sparse-checkout limits the working tree. If you'd rather only fetch the SDK files (typically <100 KB instead of tens of MB), clone the driver *without* `--recurse-submodules` and then set up the submodule as a blobless partial clone with sparse-checkout from the start:

```sh
git clone <this-repo-url> [<target-dir>]
cd <target-dir>
git submodule init external/Nextor
git submodule update --init --filter=blob:none external/Nextor
git -C external/Nextor sparse-checkout init --cone
git -C external/Nextor sparse-checkout set sdk
git -C external/Nextor checkout
```

...or, equivalently, just `make setup`:

```sh
git clone <this-repo-url> [<target-dir>]
cd <target-dir>
make setup
```

## Building

There are two ways to build: with the **Nextor dev Docker image** (no local toolchain, SDK or kernel base file needed) or with a **local toolchain**.

### Building with the Nextor dev Docker image

The [`nextor-dev`](https://github.com/Konamiman/Nextor/pkgs/container/nextor-dev) image bundles `N80`, `mknexrom`, the Nextor SDK and both kernel base-file variants, and presets `NEXTOR_BASE` / `NEXTOR_SDK`, so a build needs nothing else on your machine - not even the `external/Nextor` submodule. The `docker-build.sh` wrapper runs the build in a container, mounting this repository and writing the ROMs into `bin/` owned by you (not root):

```sh
./docker-build.sh                       # both ROMs, default kernel base
./docker-build.sh --variant NO_UNDOC    # build against the NO_UNDOC kernel base
./docker-build.sh --variant all         # build against every base variant
./docker-build.sh --nextor-base /opt/nextor/kernel_base/kernel_base.dat
./docker-build.sh clean                 # any extra args are passed to make
```

`--variant <suffix>` selects one of the image's kernel base files (`kernel_base<suffix>.dat`). The image ships two: the default, suffix-less base (omit `--variant`) and `NO_UNDOC` (no undocumented Z80 opcodes, for Z180-based machines). For the `NO_UNDOC` variant the Makefile assembles the driver undoc-free to match, and the variant suffix is reflected in the output ROM names, exactly as with a local build. This repo builds two ROMs per base variant, so `--variant all` builds against every base file the image ships in a single container (4 ROMs in all; this runs `build-all.sh`, described below, inside the image).

`--nextor-base <path>` passes `<path>` through as `NEXTOR_BASE`. The path is inside the container. If `--variant` is also given, `--nextor-base` wins. Run `./docker-build.sh --help` for the full list.

The image tag used by default is the kernel version this driver is built for (`3.0.0-beta2`); override it with `--image <ref>` or the `NEXTOR_IMAGE` environment variable. Note that the image's `latest` tag tracks stable kernel releases only, so it is not what you want while the driver targets a prerelease.

### Building with a local toolchain

The build needs a Nextor kernel base file, supplied via `NEXTOR_BASE`:

```sh
NEXTOR_BASE=/path/to/Nextor-3.0.0.base.dat make
```

That produces both ROM variants in the `bin/` directory.

For an undoc-instruction-free build (compatible with Z180-based MSX machines), just point `NEXTOR_BASE` at an undoc-free kernel base:

```sh
NEXTOR_BASE=/path/to/Nextor-3.0.0.base.NO_UNDOC.dat make
```

The Nextor base filename's variant suffix (`.NO_UNDOC`, or none for the default base) is mirrored in the output ROM filenames (the version in them comes from the SDK, not from the base filename), and a `NO_UNDOC` in it makes the Makefile assemble the driver without undocumented opcodes (`NO_UNDOC_CPU_INSTRUCTIONS=1`) so that it matches the kernel. The inference only works when the base file follows one of the two naming conventions (`Nextor-<ver>.base[<suffix>].dat` or `kernel_base[<suffix>].dat`); with a base file named otherwise, set `NO_UNDOC_CPU_INSTRUCTIONS` by hand. An explicit value on the command line or in the environment always wins over the inference.

#### Building against every kernel base variant

To build the ROMs for all the kernel base-file variants at once (the local counterpart of `docker-build.sh --variant all`), point `NEXTOR_KERNEL_BASE_DIR` at the directory holding the base files and run `build-all.sh`:

```sh
NEXTOR_KERNEL_BASE_DIR=/path/to/Nextor/bin/kernel-base ./build-all.sh
NEXTOR_KERNEL_BASE_DIR=/path/to/Nextor/bin/kernel-base ./build-all.sh clean-bin all   # extra args go to make
```

There is no list of variants to maintain: the script scans the directory and builds against every `.dat` file there named by either convention the Makefile understands (`Nextor-<ver>.base[<suffix>].dat`, as built by the Nextor repository, or `kernel_base[<suffix>].dat`, as shipped in the Docker image), ordering the builds so the driver is reassembled only once when crossing into the undoc-free (`NO_UNDOC`) base. Nextor 3 ships two kernel bases, so that is 4 ROMs. If the directory mixes base files from several kernel versions, the ones matching the SDK's version are used (and the script stops if none do). Run `./build-all.sh --help` for the details.

### Building without `make`

The Makefile is the recommended way, but each ROM is produced by just three tool invocations: two `N80` calls (one for the driver, one for the ASCII16 bank-switching routine) and one `mknexrom` call that combines them with the kernel base. Here's the sequence for the 1-slot variant:

```sh
mkdir -p tmp

# Assemble the driver for 1 SD slot  ->  tmp/driver.1slot.bin
N80 driver.asm tmp/driver.1slot.bin \
    --no-string-escapes --build-type abs --output-file-extension bin \
    --include-directory external/Nextor/sdk \
    --define-symbols NUM_SLOTS=1

# Assemble the ASCII16 bank-switching routine from the SDK  ->  tmp/chgbnk.bin
N80 external/Nextor/sdk/asm/chgbnk/ascii16.asm tmp/chgbnk.bin \
    --no-string-escapes --build-type abs --output-file-extension bin \
    --include-directory external/Nextor/sdk

# Combine kernel base + driver + chgbnk  ->  Nextor-<ver>.SDMapperV1.1-slot.ROM
mknexrom /path/to/Nextor-<ver>.base.dat Nextor-<ver>.SDMapperV1.1-slot.ROM \
    /d:tmp/driver.1slot.bin /m:tmp/chgbnk.bin
```

The 2-slots variant is the same recipe with `--define-symbols NUM_SLOTS=2` and the matching output name `Nextor-<ver>.SDMapperV1.2-slots.ROM`.

For a `NO_UNDOC` build, add `--define-symbols NO_UNDOC_CPU_INSTRUCTIONS` to *every* `N80` call and use a `Nextor-<ver>.base.NO_UNDOC.dat` kernel base. The driver-side and base-side undoc settings must match.

## Make variables

| Variable                    | Purpose                                                              | Default                  |
| --------------------------- | -------------------------------------------------------------------- | ------------------------ |
| `NEXTOR_BASE`               | Path to the Nextor kernel base `.dat` file (mandatory).              | _(unset; error)_         |
| `NEXTOR_SDK`                | Path to the Nextor SDK directory (the one containing `asm/`).        | `external/Nextor/sdk`    |
| `N80`                       | Path to the Nestor80 assembler.                                      | `N80` (from `PATH`)      |
| `MKNEXROM`                  | Path to the `mknexrom` tool.                                         | `mknexrom` (from `PATH`) |
| `NO_UNDOC_CPU_INSTRUCTIONS` | If non-empty (e.g. `=1`), assemble the driver without undocumented opcodes. | _inferred: `1` if the `NEXTOR_BASE` filename's variant suffix contains `NO_UNDOC`, unset otherwise_ |

Cleanup targets:

| Target           | Effect                                                                                                          |
| ---------------- | --------------------------------------------------------------------------------------------------------------- |
| `make clean`     | Removes `tmp/` (intermediate `.bin` files and helper artifacts). `bin/` and the shippable ROMs in it are kept.  |
| `make clean-bin` | Removes `bin/` (the shippable ROMs).                                                                            |
| `make distclean` | Removes both `tmp/` and `bin/`.                                                                                 |

## License

MIT - see [LICENSE](LICENSE). Hardware I/O is derived from the SDMapper V1 Nextor 2 driver by Fabio Belavenuto and FRS ([CERN OHL v1.1](https://github.com/fbelavenuto/msxsdmapper) for the hardware project). Note that [Nextor itself has a different license](https://github.com/Konamiman/Nextor/blob/master/LICENSE.md).
