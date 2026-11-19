# Nintendo Switch reverse-engineering tools

These are kept as **Git submodules**, not copied into nxnative's iOS app target. They are standalone desktop/development tools and do not become part of the iOS build.

## Included tools

- **NSTool** — pinned to `v1.9.2` (`jakcron/nstool`). Reads and extracts XCI, NSP, NCA, RomFS, ExeFS, NSO, NRO and related Switch formats. Encrypted content requires legally obtained keys supplied by the user. NSTool's own dependencies are Git submodules.
- **Ghidra** — pinned to `Ghidra_12.2_build` (`NationalSecurityAgency/ghidra`). Disassembles and decompiles extracted executable binaries into assembly and C-like pseudocode. It does not recover original source code.

## Clone / initialize

Clone nxnative with submodules:

```sh
git clone --recurse-submodules https://github.com/SlyDevil6858/nxnative.git
```

If nxnative is already cloned:

```sh
git submodule update --init --recursive
```

The recursive option is important for NSTool's dependencies.

## Typical workflow

1. Use NSTool to inspect an XCI and extract its filesystem / content archives.
2. Identify the game's executable content (typically the Program NCA, then its ExeFS and executable modules).
3. Import the extracted executable into Ghidra and select the appropriate processor/language settings for analysis.
4. Analyze the disassembly and decompiler output. Results depend on symbols, compiler settings, and binary format; expect pseudocode, not the original project/source.

## Build / runtime notes

- NSTool is a native C++ project. Follow its upstream [BUILDING.md](https://github.com/jakcron/nstool/blob/v1.9.2/BUILDING.md) and initialize its nested submodules.
- Ghidra is a separate desktop application. The pinned source checkout is not a ready-to-run application bundle; follow the [official installation/build instructions](https://github.com/NationalSecurityAgency/ghidra#install). The official prebuilt release is available from [Ghidra 12.2](https://github.com/NationalSecurityAgency/ghidra/releases/tag/Ghidra_12.2_build).

## Upstream projects and licenses

- [NSTool](https://github.com/jakcron/nstool) — MIT License; see the upstream repository for its license and dependency notices.
- [Ghidra](https://github.com/NationalSecurityAgency/ghidra) — Apache License 2.0; see the upstream repository for its license and third-party notices.

These tools are provided for analyzing files you are authorized to access. This addition does not add XCI decryption keys, copyrighted game content, or an automatic decompilation feature to nxnative.
