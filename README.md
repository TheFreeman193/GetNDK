# Get-NDK

Get-NDK is a PowerShell wrapper for downloading and extracting Android Native Development Kits (NDKs) across all supported platforms and revisions.

The script works in all editions of PowerShell (Windows PowerShell and PowerShell 7 on Linux, macOS, and Windows).
By default it will detect the host operating system and download the correct NDK edition for your platform.

```powershell
./Get-NDK.ps1 [[-Version] <int[]>] [[-NdkDir] <string>] [[-TempDir] <string>] [[-ForcePlatform] <string>] [-KeepArchive] [-AllPlatforms] [-NoExtract] [-NoVerify] [<CommonParameters>]
```

- `-Version <ver>` specifies the NDK version to download. Defaults to the latest release (excluding betas).
- `-NdkDir <path>` specifies where to extract the NDK files. Defaults to *./NDK* relative to the script.
- `-TempDir <path>` specifies the staging directory for downloading/extracting the NDK files. Defaults to the user's temp path.
- `-KeepArchive` retains the downloaded NDK archive files in the temp path.
- `-ForcePlatform` downloads the NDK for a specific platform.
- `-AllPlatforms` downloads all supported editions of the NDK (currently 64-bit Windows, Linux, or macOS). This overrides `-ForcePlatform`.
- `-NoExtract` downloads the NDK archive but doesn't attempt to extract it.
- `-NoVerify` skips checking archives against stored file hashes before extracting.

Run `Get-Help ./Get-NDK.ps1` for more detailed help.

## 7-Zip

Where the archive is in ZIP format, the script is standalone and requires only PowerShell.
For NDKs r5 to r9 on macOS and Linux, and r23 or later on macOS, you need [7-Zip](https://7-zip.org/) installed in order to extract the archives.
If you have 7-Zip installed, the script will preferentially use it for ZIP archives too as it's quicker than PowerShell's own archive cmdlets.

## NDK Compatibility Matrices

You can also find NDK compatibility data in [PSD1](./NDKData.psd1), [JSON](./NDKData.json), and [YAML](./NDKData.yml) formats in this repo.

|  API | MinNDK | MaxNDK | &nbsp; |  NDK | MinAPI | MaxAPI |
| ---: | :----: | :----: | ------ | ---: | :----: | :----: |
|    3 |   1    |   11   | &nbsp; |    1 |   3    |   4    |
|    4 |   1    |   11   | &nbsp; |    2 |   3    |   4    |
|    5 |   3    |   11   | &nbsp; |    3 |   3    |   5    |
|    6 |   4    |   11   | &nbsp; |    4 |   3    |   8    |
|    7 |   4    |   11   | &nbsp; |    5 |   3    |   9    |
|    8 |   4    |   11   | &nbsp; |    6 |   3    |   9    |
|    9 |   5    |   14   | &nbsp; |    7 |   3    |   14   |
|   10 |   7    |   14   | &nbsp; |    8 |   3    |   14   |
|   11 |   7    |   14   | &nbsp; |    9 |   3    |   19   |
|   12 |   7    |   15   | &nbsp; |   10 |   3    |   21   |
|   13 |   7    |   15   | &nbsp; |   11 |   3    |   24   |
|   14 |   7    |   17   | &nbsp; |   12 |   9    |   24   |
|   15 |   9    |   17   | &nbsp; |   13 |   9    |   24   |
|   16 |   9    |   23   | &nbsp; |   14 |   9    |   24   |
|   17 |   9    |   23   | &nbsp; |   15 |   12   |   26   |
|   18 |   9    |   23   | &nbsp; |   16 |   14   |   27   |
|   19 |   9    |   25   | &nbsp; |   17 |   14   |   28   |
|   20 |   10   |   25   | &nbsp; |   18 |   16   |   28   |
|   21 |   10   |   29   | &nbsp; |   19 |   16   |   28   |
|   22 |   11   |   29   | &nbsp; |   20 |   16   |   29   |
|   23 |   11   |   29   | &nbsp; |   21 |   16   |   30   |
|   24 |   11   |   29   | &nbsp; |   22 |   16   |   30   |
|   25 |   15   |   29   | &nbsp; |   23 |   16   |   31   |
|   26 |   15   |   29   | &nbsp; |   24 |   19   |   32   |
|   27 |   16   |   29   | &nbsp; |   25 |   19   |   33   |
|   28 |   17   |   29   | &nbsp; |   26 |   21   |   34   |
|   29 |   20   |   29   | &nbsp; |   27 |   21   |   35   |
|   30 |   21   |   29   | &nbsp; |   28 |   21   |   35   |
|   31 |   23   |   29   | &nbsp; |   29 |   21   |   35   |
|   32 |   24   |   29   | &nbsp; |      |        |        |
|   33 |   25   |   29   | &nbsp; |      |        |        |
|   34 |   26   |   29   | &nbsp; |      |        |        |
|   35 |   27   |   29   | &nbsp; |      |        |        |

## License

The source code in this repository is released under the [MIT License](./LICENSE).
