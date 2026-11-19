# Nintendo Switch reverse-engineering tools

These tools are kept outside nxnative's iOS app target. They are desktop utilities for files you are authorized to analyze and do not become part of the iOS build.

## Included projects

- **NSTool** — pinned to v1.9.2 (jakcron/nstool). Reads and extracts XCI, NSP, NCA, RomFS, ExeFS, NSO, NRO and related Switch formats. Its third-party libraries are nested Git submodules.
- **Ghidra source** — pinned to Ghidra_12.2_build (NationalSecurityAgency/ghidra). Disassembles and decompiles compiled binaries into assembly and C-like pseudocode; it does not restore original source code.
- **Ghidra desktop distribution** — downloaded by the Windows setup script into the ignored Tools/Ghidra-Distribution/ folder. The large official application ZIP is deliberately not committed to Git.

## Windows quick setup

Requirements:
- Git for Windows.
- 64-bit JDK 25 or newer for Ghidra 12.2.
- To compile NSTool: Visual Studio 2019/2022 or Build Tools with the C++ workload, MSVC, and a Windows SDK.

From the repository root, initialize the projects and NSTool's nested dependencies, then download the official Ghidra release:

~~~powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Tools\setup-windows.ps1
~~~

If JDK 25 is missing and Windows Package Manager (winget) is available, the script can install Eclipse Temurin JDK 25:

~~~powershell
.\Tools\setup-windows.ps1 -InstallJdk
~~~

After Java installation, open a new PowerShell window and run the setup script again.

You can also ask winget to install Visual Studio 2022 C++ Build Tools (a large download):

~~~powershell
.\Tools\setup-windows.ps1 -InstallBuildTools
~~~

After the installer finishes, rerun setup. This installs the C++ toolchain used to build NSTool; it does not build Ghidra from source because setup downloads Ghidra's ready-to-run official release.

Build NSTool after installing the Visual Studio C++ workload:

~~~powershell
.\Tools\build-nstool-windows.ps1
~~~

The build script uses the upstream Visual Studio solution and builds Release | x64 by default. Use -Configuration Debug or -Platform Win32 to change that.

Launch Ghidra using the ghidraRun.bat found inside Tools/Ghidra-Distribution. The setup script prints the exact launcher path.

## Manual / cross-platform initialization

Clone with all nested submodules:

~~~sh
git clone --recurse-submodules https://github.com/SlyDevil6858/nxnative.git
~~~

Or, in an existing clone:

~~~sh
git submodule update --init --recursive
~~~

NSTool's Windows build instructions are in [BUILDING.md](https://github.com/jakcron/nstool/blob/v1.9.2/BUILDING.md). Ghidra's official installation/build instructions are in its [README](https://github.com/NationalSecurityAgency/ghidra/blob/Ghidra_12.2_build/README.md).

## Typical XCI-to-analysis workflow

1. Use NSTool to inspect an XCI and extract its filesystem/content archives.
2. Identify the Program NCA, then extract its ExeFS and executable modules.
3. Import an extracted executable into Ghidra and select the correct processor/language.
4. Analyze the disassembly and decompiler output. Results are pseudocode, not the game's original project or source.

Encrypted content may require keys that are not included here. This repository does not include game files, title keys, or firmware.

## Upstream licenses

- [NSTool](https://github.com/jakcron/nstool) — MIT.
- [Ghidra](https://github.com/NationalSecurityAgency/ghidra) — Apache-2.0.

See each upstream project for full licenses and third-party notices.
