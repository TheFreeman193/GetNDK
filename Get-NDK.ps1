#!/usr/bin/env pwsh
# Copyright (c) 2025 Nicholas Bissell (TheFreeman193) MIT License: https://spdx.org/licenses/MIT.html
# Get-NDK 1.0.9

using namespace System.IO
using namespace System.Management.Automation
using namespace System.Collections.Generic

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline)]
    [ValidateRange(1, 29)]
    [int[]]$Version = 28,

    [string]$NdkDir = $(Join-Path $PSScriptRoot 'ndk'),
    [string]$TempDir = $([Path]::GetTempPath()),

    [ValidateSet('Win64', 'Win32', 'Linux32', 'Linux64', 'macOS64', 'macOS32', 'macOSA64')]
    [string]$ForcePlatform,

    [switch]$KeepArchive,
    [switch]$AllPlatforms,
    [switch]$NoExtract,
    [switch]$NoVerify
)
begin {
    function Get-7Zip {
        param([switch]$Require)
        if ($IsWindows -or $PSVersionTable.PSVersion -lt '6.0') {
            $BinPaths = "$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
            $Commands = '7z.exe'
        } elseif ($IsLinux) {
            $BinPaths = '/usr/bin/7zz', '/usr/local/bin/7zz', '/bin/7zz', '/usr/bin/7z', '/usr/local/bin/7z', '/bin/7z'
            $Commands = '7zz', '7z'
        } elseif ($IsMacOS) {
            $Commands = '7z'
            $BinPaths = '/usr/bin/7z', '/usr/local/bin/7z', '/opt/homebrew/bin/7z'
        } else {
            return $false
        }
        $PossCommand = Get-Command -CommandType Application $Commands -ErrorAction Ignore | Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($PossCommand)) { return $PossCommand }
        foreach ($Bin in $BinPaths) {
            if (Test-Path $Bin -PathType Leaf) {
                $Command = (Get-Command $Bin).Source
                if (-not [string]::IsNullOrWhiteSpace($Command)) { return $Command }
            }
        }
        return ''
    }

    function 7zError {
        $Err = [ErrorRecord]::new([CommandNotFoundException]::new('7-Zip not found! Please install from https://www.7-zip.org/download.html'), 'CommandNotFound', 'ObjectNotFound', '7-Zip')
        $PSCmdlet.WriteError($Err)
    }

    function ExtractError {
        param ($Target = 'archive')
        $Err = [ErrorRecord]::new([FileNotFoundException]::new("Unable to identify/extract NDK from source '$Target'.", $Target), 'NDKNotFound', 'ObjectNotFound', $Target)
        $PSCmdlet.WriteError($Err)
    }

    function Get-NDKRoot {
        [CmdletBinding()]
        param([string]$Path, [int]$Depth = 5)
        $PSCmdlet.WriteVerbose("Searching for NDK root in '$Path'.")
        $TCDir = Get-ChildItem $Path -Directory -Recurse -Filter 'toolchains' -Depth $Depth -ErrorAction Stop | Where-Object {
            ($_.Parent.GetDirectories() -match 'sources|prebuilt|build').Count -eq 3
        } -ErrorAction Stop | Sort-Object { $_.FullName.Length } | Select-Object -First 1
        if ($?) {
            $TCDir.Parent
        }
    }

    $WebParams = @{UserAgent = 'curl/8.13.0' }
    $DelList = [List[string]]::new()
    $VerifiedArchives = [List[string]]::new()
    if ($PSVersionTable.PSVersion -lt '6.0') { $WebParams['UseBasicParsing'] = $true }
    $AllOses = 'Win64', 'Win32', 'Linux32', 'Linux64', 'macOS64', 'macOS32', 'macOSA64'

    if ([string]::IsNullOrWhiteSpace($ForcePlatform) -and -not $AllPlatforms) {
        # Coarse filtering
        $Platform = $PSVersionTable.Platform
        if ($IsWindows -or $PSVersionTable.PSVersion -lt '6.0') {
            $HostArch = $env:PROCESSOR_ARCHITECTURE
            $Supported = $HostArch -in 'AMD64', 'X86', 'ARM64'
            if ($HostArch -in 'AMD64', 'ARM64') { $HostOS = 'Win64' } else { $HostOS = 'Win32' }
            if ($Supported -and $HostArch -eq 'ARM64' -and [Environment]::OSVersion.Version -lt '10.0.22000') {
                # Win10 ARM doesn't support AMD64 emulation (grr)
                $PSCmdlet.WriteWarning("Windows 10 ARM doesn't support AMD64 emulation. Targeting x86.")
                $HostOS = 'Win32'
            }
        } elseif ($IsLinux) {
            $HostArch = uname -m
            $Supported = $HostArch -in 'x86_64', 'amd64', 'i386', 'i486', 'i586', 'i686', 'x32'
            if ($HostArch -in 'x86_64', 'amd64') { $BitSuffix = '64' } else { $BitSuffix = '32' }
            $HostOS = "Linux$BitSuffix"
        } elseif ($IsMacOS) {
            $HostArch = uname -m
            $Supported = $HostArch -in 'x86_64', 'amd64', 'arm64', 'aarch64_be', 'aarch64', 'i386', 'i486', 'i586', 'i686', 'x32'
            if ($HostArch -in 'x86_64', 'amd64', 'arm64', 'aarch64_be', 'aarch64') { $BitSuffix = '64' } else { $BitSuffix = '32' }
            if ($HostArch -like 'aarch64*' -or $HostArch -eq 'arm64') { $ArmSuffix = 'A' } else { $ArmSuffix = '' }
            $HostOS = "macOS$ArmSuffix$BitSuffix"
        } else {
            $Supported = $false
        }
        if (-not $Supported) {
            $HostOS = $AllOses
            $PSCmdlet.WriteWarning("The system platform '$Platform $HostArch' isn't supported by the NDK. Downloading for all OSes. Supported platforms are Windows/Linux/macOS. Newer versions are exclusively 64-bit.")
        }
    } else {
        $Supported = $true
        if ($AllPlatforms) {
            $HostOS = $AllOses
        } else {
            $HostOS = $ForcePlatform
        }
    }

    <# NDK/SDK compatibility matrices:
    SDK MinNDK MaxNDK   |  NDK MinSDK MaxSDK
    --- ------ ------   |  --- ------ ------
      3      1     11   |    1      3      4
      4      1     11   |    2      3      4
      5      3     11   |    3      3      5
      6      4     11   |    4      3      8
      7      4     11   |    5      3      9
      8      4     11   |    6      3      9
      9      5     14   |    7      3     14
     10      7     14   |    8      3     14
     11      7     14   |    9      3     19
     12      7     15   |   10      3     21
     13      7     15   |   11      3     24
     14      7     17   |   12      9     24
     15      9     17   |   13      9     24
     16      9     23   |   14      9     24
     17      9     23   |   15     12     26
     18      9     23   |   16     14     27
     19      9     25   |   17     14     28
     20     10     25   |   18     16     28
     21     10     29   |   19     16     28
     22     11     29   |   20     16     29
     23     11     29   |   21     16     30
     24     11     29   |   22     16     30
     25     15     29   |   23     16     31
     26     15     29   |   24     19     32
     27     16     29   |   25     19     33
     28     17     29   |   26     21     34
     29     20     29   |   27     21     35
     30     21     29   |   28     21     35
     31     23     29   |   29     21     35
     32     24     29   |
     33     25     29   |
     34     26     29   |
     35     27     29   |
    #>

    # NDK binary releases
    $B = 'https://dl.google.com/android/repository/android-ndk-'
    $A = 'https://dl.google.com/android/ndk/android-ndk-'
    $NDKSources = @{
        29 = @{
            Win64    = "${B}r29-windows.zip", 'ab3bb30fbb9e6903666d60c55d11e78b04e07472'
            Linux64  = "${B}r29-linux.zip", '87e2bb7e9be5d6a1c6cdf5ec40dd4e0c6d07c30b'
            macOS64  = "${B}r29-darwin.dmg", '0eecb29cfe791e039740e2a8bcf0af02b7132bd8'
            macOSA64 = "${B}r29-darwin.dmg", '0eecb29cfe791e039740e2a8bcf0af02b7132bd8'
        }
        28 = @{
            Win64    = "${B}r28c-windows.zip", '086bba43ff2f5eb0e387b15c8278bb4e0d89ba1d'
            Linux64  = "${B}r28c-linux.zip", 'a7b54a5de87fecd125a17d54f73c446199e72a64'
            macOS64  = "${B}r28c-darwin.dmg", '60e8efb121aa7ce9857afbffa17b2da4c37b515a'
            macOSA64 = "${B}r28c-darwin.dmg", '60e8efb121aa7ce9857afbffa17b2da4c37b515a'
        }
        27 = @{
            Win64    = "${B}r27d-windows.zip", '56607cbccd3642d4a1991f6bb3114a00f884f426'
            Linux64  = "${B}r27d-linux.zip", '22105e410cf29afcf163760cc95522b9fb981121'
            macOS64  = "${B}r27d-darwin.dmg", '80f11292080fab4e869799f1d23caa88dcf3c709'
            macOSA64 = "${B}r27d-darwin.dmg", '80f11292080fab4e869799f1d23caa88dcf3c709'
        }
        # macOS releases are exclusively DMG-ZLIB-HFS from r26. Thank fudge for 7-zip.
        26 = @{
            Win64    = "${B}r26d-windows.zip", 'c7ea35ffe916082876611da1a6d5618d15430c29'
            Linux64  = "${B}r26d-linux.zip", 'fcdad75a765a46a9cf6560353f480db251d14765'
            macOS64  = "${B}r26d-darwin.dmg", '703100c3d721b04e09f02f3fddc5f1f5ced28b10'
            macOSA64 = "${B}r26d-darwin.dmg", '703100c3d721b04e09f02f3fddc5f1f5ced28b10'
        }
        # Alternative macOS64 download for r25b (ZIP): https://dl.google.com/android/repository/android-ndk-r25b-darwin.zip
        25 = @{
            Win64    = "${B}r25c-windows.zip", '18c4a3cd108916f553b1bedad2672f2c6cd85a10'
            Linux64  = "${B}r25c-linux.zip", '53af80a1cce9144025b81c78c8cd556bff42bd0e'
            macOS64  = "${B}r25c-darwin.dmg", 'effebe35c4f32608c20460ca7bcc4278203ba1f1'
            macOSA64 = "${B}r25c-darwin.dmg", 'effebe35c4f32608c20460ca7bcc4278203ba1f1'
        }
        # Alternative macOS64 download (ZIP): https://dl.google.com/android/repository/android-ndk-r24-darwin.zip
        24 = @{
            Win64    = "${B}r24-windows.zip", '75f9c281c64762d18c84da465f486c60def47829'
            Linux64  = "${B}r24-linux.zip", 'eceb18f147282eb93615eff1ad84a9d3962fbb31'
            macOS64  = "${B}r24-darwin.dmg", 'a04581fe13173ea731168c6a1e73390ab628d1aa'
            macOSA64 = "${B}r24-darwin.dmg", 'a04581fe13173ea731168c6a1e73390ab628d1aa'
        }
        # It seems Google went back to only AMD64 binaries for macOS from r23, relying on Rosetta emulation on Apple Silicon.
        # macOS editions start using DMG images. Arch tagging also stops now everything is AMD64.
        # Alternative macOS64 download (ZIP): https://dl.google.com/android/repository/android-ndk-r23c-darwin.zip
        23 = @{
            Win64    = "${B}r23c-windows.zip", 'f2c5def76a9de371f27d028864fe301ab4fe0cf8'
            Linux64  = "${B}r23c-linux.zip", 'e5053c126a47e84726d9f7173a04686a71f9a67a'
            macOS64  = "${B}r23c-darwin.dmg", 'da6f63d3eef041e1cceca449461c6d9148e879b7'
            macOSA64 = "${B}r23c-darwin.dmg", 'da6f63d3eef041e1cceca449461c6d9148e879b7'
        }
        22 = @{
            Win64    = "${B}r22b-windows-x86_64.zip", '96ba1a049303cf6bf3ee84cfd64d6bcd43486a50'
            Linux64  = "${B}r22b-linux-x86_64.zip", '9ece64c7f19763dd67320d512794969930fce9dc'
            macOS64  = "${B}r22b-darwin-x86_64.zip", 'dc80e8a2cfcb28db74c1931d42c652e9d17ff2c3'
            macOSA64 = "${B}r22b-darwin-aarch64.zip", 'DC80E8A2CFCB28DB74C1931D42C652E9D17FF2C3'
        }
        # x86 support for Windows ended with r20. Bye-bye, 32-bit, you were the goodest boy.
        21 = @{
            Win64    = "${B}r21e-windows-x86_64.zip", 'fc44fea8bb3f5a6789821f40f41dce2d2cd5dc30'
            Linux64  = "${B}r21e-linux-x86_64.zip", 'c3ebc83c96a4d7f539bd72c241b2be9dcd29bda9'
            macOS64  = "${B}r21e-darwin-x86_64.zip", '3f15c23a1c247ad17c7c271806848dbd40434738'
            macOSA64 = "${B}r21e-darwin-aarch64.zip", '3F15C23A1C247AD17C7C271806848DBD40434738'
        }
        20 = @{
            Win64    = "${B}r20b-windows-x86_64.zip", 'ead0846608040b8344ad2bc9bc721b88cf13fb8d'
            Win32    = "${B}r20b-windows-x86.zip", '71a1ba20475da1d83b0f1a1826813008f628d59b'
            Linux64  = "${B}r20b-linux-x86_64.zip", 'd903fdf077039ad9331fb6c3bee78aa46d45527b'
            macOS64  = "${B}r20b-darwin-x86_64.zip", 'b51290ab69cb89de1f0ba108702277bc333b38be'
            macOSA64 = "${B}r20b-darwin-aarch64.zip", 'B51290AB69CB89DE1F0BA108702277BC333B38BE'
        }
        19 = @{
            Win64    = "${B}r19c-windows-x86_64.zip", 'c4cd8c0b6e7618ca0a871a5f24102e40c239f6a3'
            Win32    = "${B}r19c-windows-x86.zip", '132cc0c9e31b9e58ad6505b0816ff9e524422ed2'
            Linux64  = "${B}r19c-linux-x86_64.zip", 'fd94d0be6017c6acbd193eb95e09cf4b6f61b834'
            macOS64  = "${B}r19c-darwin-x86_64.zip", 'f46b8193109bba8a58e0461c1a48f4534051fb25'
            macOSA64 = "${B}r19c-darwin-aarch64.zip", 'F46B8193109BBA8A58E0461C1A48F4534051FB25'
        }
        18 = @{
            Win64    = "${B}r18b-windows-x86_64.zip", '6b6d4138aaaad7166679fdfa4780e177f95cee6f'
            Win32    = "${B}r18b-windows-x86.zip", '4b8b6a4edc0fa967b429c1d6d25adf69acc28803'
            Linux64  = "${B}r18b-linux-x86_64.zip", '500679655da3a86aecf67007e8ab230ea9b4dd7b'
            macOS64  = "${B}r18b-darwin-x86_64.zip", '98cb9909aa8c2dab32db188bbdc3ac6207e09440'
            macOSA64 = "${B}r18b-darwin-aarch64.zip", '98CB9909AA8C2DAB32DB188BBDC3AC6207E09440'
        }
        17 = @{
            Win64    = "${B}r17c-windows-x86_64.zip", '3e3b8d1650f9d297d130be2b342db956003f5992'
            Win32    = "${B}r17c-windows-x86.zip", '5bb25bf13fa494ee6c3433474c7aa90009f9f6a9'
            Linux64  = "${B}r17c-linux-x86_64.zip", '12cacc70c3fd2f40574015631c00f41fb8a39048'
            macOS64  = "${B}r17c-darwin-x86_64.zip", 'f97e3d7711497e3b4faf9e7b3fa0f0da90bb649c'
            macOSA64 = "${B}r17c-darwin-aarch64.zip", 'F97E3D7711497E3B4FAF9E7B3FA0F0DA90BB649C'
        }
        # ARM64 binaries for macOS appear with r16
        16 = @{
            Win64    = "${B}r16b-windows-x86_64.zip", 'f3f1909ed1052e98dda2c79d11c22f3da28daf25'
            Win32    = "${B}r16b-windows-x86.zip", 'becaf3d445a4877ca1a9300a62f0934a4838c7fa'
            Linux64  = "${B}r16b-linux-x86_64.zip", '42aa43aae89a50d1c66c3f9fdecd676936da6128'
            macOS64  = "${B}r16b-darwin-x86_64.zip", 'e51e615449b98c716cf912057e2682e75d55e2de'
            macOSA64 = "${B}r16b-darwin-aarch64.zip", 'E51E615449B98C716CF912057E2682E75D55E2DE'
        }
        15 = @{
            Win64   = "${B}r15c-windows-x86_64.zip", '970BB2496DE0EADA74674BB1B06D79165F725696'
            Win32   = "${B}r15c-windows-x86.zip", 'F2E47121FEB73EC34CED5E947CBF1ADC6B56246E'
            Linux64 = "${B}r15c-linux-x86_64.zip", '0BF02D4E8B85FD770FD7B9B2CDEC57F9441F27A2'
            macOS64 = "${B}r15c-darwin-x86_64.zip", 'EA4B5D76475DB84745AA8828000D009625FC1F98'
        }
        14 = @{
            Win64   = "${B}r14b-windows-x86_64.zip", 'a625e8c599bccdb9061b61dcf3d1f1a01071613f'
            Win32   = "${B}r14b-windows-x86.zip", '070443EAA7FA37ED337F91C655E02CA708D37C92'
            Linux64 = "${B}r14b-linux-x86_64.zip", 'BECD161DA6ED9A823E25BE5C02955D9CBCA1DBEB'
            macOS64 = "${B}r14b-darwin-x86_64.zip", '2BF582C43F6DA16416E66203D158A6DFABA4277C'
        }
        13 = @{
            Win64   = "${B}r13b-windows-x86_64.zip", '649D306559435C244CEC5881B880318BB3DEE53A'
            Win32   = "${B}r13b-windows-x86.zip", '4EB1288B1D4134A9D6474EB247F0448808D52408'
            Linux64 = "${B}r13b-linux-x86_64.zip", '0600157C4DDF50EC15B8A037CFC474143F718FD0'
            macOS64 = "${B}r13b-darwin-x86_64.zip", '71FE653A7BF5DB08C3AF154735B6CCBC12F0ADD5'
        }
        12 = @{
            Win64   = "${B}r12b-windows-x86_64.zip", '337746D8579A1C65E8A69BF9CBDC9849BCACF7F5'
            Win32   = "${B}r12b-windows-x86.zip", '8E6EEF0091DAC2F3C7A1ECBB7070D4FA22212C04'
            Linux64 = "${B}r12b-linux-x86_64.zip", '170A119BFA0F0CE5DC932405EAA3A7CC61B27694'
            macOS64 = "${B}r12b-darwin-x86_64.zip", 'E257FE12F8947BE9F79C10C3FFFE87FB9406118A'
        }
        # x86 support for macOS and Linux ended with r10, and download path changed ndk -> repository
        11 = @{
            Win64   = "${B}r11c-windows-x86_64.zip", '3D89DEB97B3191C7E5555F1313AD35059479F071'
            Win32   = "${B}r11c-windows-x86.zip", 'FF939BDE6CD374EECBD2C3B2AD218697F9A5038C'
            Linux64 = "${B}r11c-linux-x86_64.zip", 'DE5CE9BDDEEE16FB6AF2B9117E9566352AA7E279'
            macOS64 = "${B}r11c-darwin-x86_64.zip", '4CE8E7ED8DFE08C5FE58AEDF7F46BE2A97564696'
        }
        # Archive format for macOS/Linux now ZIP from r10. Sorry Mr Seward.
        <# Alternative r10e downloads (7z self-extracting archives):
        macOS64  http://dl.google.com/android/ndk/android-ndk-r10e-darwin-x86_64.bin (B57C2B9213251180DCAB794352BFC9A241BF2557)
        Linux64: http://dl.google.com/android/ndk/android-ndk-r10e-linux-x86_64.bin (C685E5F106F8DAA9B5449D0A4F21EE8C0AFCB2F6)
        Win32:   http://dl.google.com/android/ndk/android-ndk-r10e-windows-x86.exe (EB6BD8FE26F5E6DDB145FEF2602DCE518BF4E7B6)
        Win64:   http://dl.google.com/android/ndk/android-ndk-r10e-windows-x86_64.exe (6735993DBF94F201E789550718B64212190D617A)
        #>
        10 = @{
            Win64   = "${B}r10e-windows-x86_64.zip", 'A29F3AE41FB02B64CA8AD2B0903F74356F953D9F'
            Win32   = "${B}r10e-windows-x86.zip", '1D0B8F2835BE741F3048FB03C0A3E9F71AB7F357'
            Linux64 = "${B}r10e-linux-x86_64.zip", 'F692681B007071103277F6EDC6F91CB5C5494A32'
            Linux32 = "${A}r10e-linux-x86.bin", 'B970D086D5C91C320C006EA14E58BD1A50E1FE52'
            macOS64 = "${B}r10e-darwin-x86_64.zip", '6BE8598E4ED3D9DD42998C8CB666F0EE502B1294'
            macOS32 = "${A}r10d-darwin-x86.bin", 'FC1F9593EB9669076C25381322A1386869AC02F0'
        }
        9  = @{
            Win64   = "${A}r9d-windows-x86_64.zip", '3dcb4a13ff2d843669fb51d2e016dd41a600942a'
            Win32   = "${A}r9d-windows-x86.zip", '8401b5f22130825bf944310adf8c0bd30abbdd7b'
            Linux64 = "${A}r9d-linux-x86_64.tar.bz2", '6d0cdb0b06eeafaa89890d05627aee89122b143f'
            Linux32 = "${A}r9d-linux-x86.tar.bz2", '10feefd8c1ba950a177ce7a165a12d3b89d9822f'
            macOS64 = "${A}r9d-darwin-x86_64.tar.bz2", 'd0a8471555be57899c67aa6b61db5bca9db2e8ea'
            macOS32 = "${A}r9d-darwin-x86.tar.bz2", '91ac410a24ad6d1fc67b5161294a4a5cb78b2975'
        }
        # AMD64 binaries appear with r8
        8  = @{
            Win64   = "${A}r8e-windows-x86_64.zip", '2534B74B96BC1BE49E4A60BF38115DDF0E69383D'
            Win32   = "${A}r8e-windows-x86.zip", 'ad7926991311384c72cc52bc6fdc317f196f6cca'
            Linux64 = "${A}r8e-linux-x86_64.tar.bz2", '5A2F85AC665E34E3D27199ED25B7585F3F2F488B'
            Linux32 = "${A}r8e-linux-x86.tar.bz2", '4f7c46bf5c41273627be41e19b145b372659ff45'
            macOS64 = "${A}r8e-darwin-x86_64.tar.bz2", '8c8f0d7df5f160c3ef82f2f4836cbcaf18aabf68'
            macOS32 = "${A}r8e-darwin-x86.tar.bz2", '60536b22b3c09015a4c7072097404a9a1316b242'
        }
        7  = @{
            Win64   = "${A}r7c-windows.zip", '26BF7D5E025B119D8E71A80FD3EDA93B5DCE33BF'
            Win32   = "${A}r7c-windows.zip", '26BF7D5E025B119D8E71A80FD3EDA93B5DCE33BF'
            Linux64 = "${A}r7-linux-x86.tar.bz2", '64020a87f17d5a6d99da1b0438e88c06222321de'
            Linux32 = "${A}r7-linux-x86.tar.bz2", '64020a87f17d5a6d99da1b0438e88c06222321de'
            macOS64 = "${A}r7-darwin-x86.tar.bz2", 'f1eceda1dbe4726841b5f70e41eff150e1a0dde9'
            macOS32 = "${A}r7-darwin-x86.tar.bz2", 'f1eceda1dbe4726841b5f70e41eff150e1a0dde9'
        }
        6  = @{
            Win64   = "${A}r6b-windows.zip", '786E49BBB11319CB0F5EA12D9C41E90CBEB4E942'
            Win32   = "${A}r6b-windows.zip", '786E49BBB11319CB0F5EA12D9C41E90CBEB4E942'
            Linux64 = "${A}r6b-linux-x86.tar.bz2", 'AFBA5FE6A7B2B6349BC49978A229A0319DAE8890'
            Linux32 = "${A}r6b-linux-x86.tar.bz2", 'AFBA5FE6A7B2B6349BC49978A229A0319DAE8890'
            macOS64 = "${A}r6b-darwin-x86.tar.bz2", '08C1664885BB7E6A06A199BB20E1F28FFCD7AECF'
            macOS32 = "${A}r6b-darwin-x86.tar.bz2", '08C1664885BB7E6A06A199BB20E1F28FFCD7AECF'
        }
        5  = @{
            Win64   = "${A}r5c-windows.zip", '95F56646EACF52EBAF1430EAC937D03D5EF0FA63'
            Win32   = "${A}r5c-windows.zip", '95F56646EACF52EBAF1430EAC937D03D5EF0FA63'
            Linux64 = "${A}r5c-linux-x86.tar.bz2", '0B1FDFAB6B1402852E2F31327664AC1D6D70A27F'
            Linux32 = "${A}r5c-linux-x86.tar.bz2", '0B1FDFAB6B1402852E2F31327664AC1D6D70A27F'
            macOS64 = "${A}r5c-darwin-x86.tar.bz2", 'E4205D68CBD55B250C80BA0B4656B31CEAD21674'
            macOS32 = "${A}r5c-darwin-x86.tar.bz2", 'E4205D68CBD55B250C80BA0B4656B31CEAD21674'
        }
        4  = @{
            Win64   = "${A}r4b-windows.zip", '0E857993C8C3FF08BCC4A38BECE7FA23FCD1DD1C'
            Win32   = "${A}r4b-windows.zip", '0E857993C8C3FF08BCC4A38BECE7FA23FCD1DD1C'
            Linux64 = "${A}r4b-linux-x86.zip", '581781366E38D41C8699A2C822CD9A4DE95DA5B2'
            Linux32 = "${A}r4b-linux-x86.zip", '581781366E38D41C8699A2C822CD9A4DE95DA5B2'
            macOS64 = "${A}r4b-darwin-x86.zip", 'D35F114F7DC74F97BD2F3C57B3AE6E659A8B4DDE'
            macOS32 = "${A}r4b-darwin-x86.zip", 'D35F114F7DC74F97BD2F3C57B3AE6E659A8B4DDE'
        }
        3  = @{
            Win64   = "${A}r3-windows.zip", 'E4C819D99A73B1FC8F5C5A14F01887B772F0D770'
            Win32   = "${A}r3-windows.zip", 'E4C819D99A73B1FC8F5C5A14F01887B772F0D770'
            macOS64 = "${A}r3-darwin-x86.zip", 'E3A1E841C89F4B19E9E1B9CA21F93F5F9335B24C'
            macOS32 = "${A}r3-darwin-x86.zip", 'E3A1E841C89F4B19E9E1B9CA21F93F5F9335B24C'
            # Linux32 = "${A}r3-linux.zip", 'f3b1700a195aae3a6e9b5637e5c49359' # 37403241 B
        }
        2  = @{ # September 2009, NDK 1.6 became r2
            Win64   = "${A}1.6_r1-windows.zip", '4FA6A99D05D20AAA2C50F6D418AF08DF422AD0C3'
            Win32   = "${A}1.6_r1-windows.zip", '4FA6A99D05D20AAA2C50F6D418AF08DF422AD0C3'
            Linux64 = "${A}1.6_r1-linux-x86.zip", '3F395F6769302055B41C0DB8A32EA678C032D2B1'
            Linux32 = "${A}1.6_r1-linux-x86.zip", '3F395F6769302055B41C0DB8A32EA678C032D2B1'
            macOS64 = "${A}1.6_r1-darwin-x86.zip", '9EC2DA85A2D9338346089A9D672E6472103DC0F6'
            macOS32 = "${A}1.6_r1-darwin-x86.zip", '9EC2DA85A2D9338346089A9D672E6472103DC0F6'
        }
        # 1  = @{ # May/June 2009 - unable to find these
        #     Win32   = "${A}1.5_r1-windows.zip", 'e5c53915903d8b81f3e2ea422e2e2717' # 22500667 B, earlier 7b7836f705ec7e66225794edda34000f
        #     Linux32 = "${A}1.5_r1-linux-x86.zip", '80a4e14704ca84c21bf1824cb25fbd8b' # 16025885 B, earlier 808fd4d6a7e45f76d546ba04ab9ef060
        #     Linux64 = "${A}1.5_r1-linux-x86_64.zip", 'f8664c187b3ae077bcfe2b44294d0758' # 18112300 B
        #     macOS32 = "${A}1.5_r1-darwin-x86.zip", '1931f0e182798a4c98924fd87380b5b8' # 16025885 B, earlier 214ccfd704c0307609fbabeb7bf86acc
        # }
    }
    $NDKSources[1] = $NDKSources[2]
    Remove-Variable A, B
}
process {
    if (-not (Test-Path $NdkDir -PathType Container)) {
        $null = New-Item -ItemType Directory $NdkDir
        if (-not $?) { return }
    }
    if (-not (Test-Path $TempDir -PathType Container)) {
        $null = New-Item -ItemType Directory $TempDir
        if (-not $?) { return }
    }
    $PSCmdlet.WriteVerbose("Hosts: $($HostOS -join ', ')`nNDKs: $($Version -join ', ')")
    :VersionLoop foreach ($Ver in $Version) {
        :PlatformLoop foreach ($Plat in $HostOS) {
            $PSCmdlet.WriteDebug("Processing target '$Plat NDK r$Ver'...")
            if (-not $NDKSources.Contains($Ver)) {
                $PSCmdlet.WriteWarning("NDK r$Ver not found. Skipping.")
                continue PlatformLoop
            }
            if (-not $NDKSources[$Ver].Contains($Plat)) {
                if (-not $AllPlatforms) { $PSCmdlet.WriteWarning("NDK r$Ver doesn't support platform '$Plat'. Skipping.") }
                continue PlatformLoop
            }
            if ([string]::IsNullOrWhiteSpace($NDKSources[$Ver][$Plat][0])) {
                $PSCmdlet.WriteWarning("Target filename for '$Plat NDK r$Ver' unknown. Skipping.")
                continue PlatformLoop
            }
            Write-Host -fo White "Processing target '" -NoNewline
            Write-Host -fo Cyan $Plat -NoNewline
            Write-Host -fo White ' NDK ' -NoNewline
            Write-Host -fo Magenta "r$Ver" -NoNewline
            Write-Host -fo White "'..."
            $NDKSubPath = Join-Path (Join-Path $NdkDir $Plat) $Ver
            if (-not $NoExtract) {
                if (Test-Path $NDKSubPath) {
                    $FoundRoot = Get-NDKRoot $NDKSubPath
                    if ([string]::IsNullOrWhiteSpace($FoundRoot)) {
                        Remove-Item "$NDKSubPath\*" -Force -Recurse
                    } else {
                        $PSCmdlet.WriteVerbose("NDK root already exists at '$NDKSubPath'. Not redownloading.")
                        continue PlatformLoop
                    }
                } else {
                    $null = New-Item -ItemType Directory $NDKSubPath
                }
            }
            if (-not $NDKSources.Contains($Ver)) {
                $PSCmdlet.WriteVerbose("No download for NDK r$Ver is available.")
                continue PlatformLoop
            }
            if (-not $NDKSources[$Ver].Contains($Plat)) {
                $PSCmdlet.WriteVerbose("NDK r$Ver is not available for platform '$Plat'.")
                continue PlatformLoop
            }
            $DownloadUrl = $NDKSources[$Ver][$Plat][0]
            $DownloadTarget = Join-Path $TempDir ($DownloadUrl -replace '^.+/')
            $WasDownloaded = $false
            if (-not (Test-Path $DownloadTarget -PathType Leaf)) {
                Write-Host -fo Gray '    Downloading...  ' -NoNewline
                $PSCmdlet.WriteVerbose("Downloading '$DownloadUrl' to '$DownloadTarget'.")
                if (-not $KeepArchive -and -not $NoExtract) { $DelList.Add($DownloadTarget) }
                Invoke-WebRequest $DownloadUrl -OutFile $DownloadTarget @WebParams
                if (-not $?) { continue PlatformLoop }
                $WasDownloaded = $true
                Write-Host -fo Green '    OK.'
            } else {
                $PSCmdlet.WriteVerbose("Already have '$DownloadTarget'. The archive won't be deleted.")
            }
            if (-not $NoVerify) {
                $ExpectedHash = $NDKSources[$Ver][$Plat][1]
                $Alg = switch ($ExpectedHash.Length) {
                    40 { 'SHA-1'; break }
                    32 { 'MD5'; break }
                    64 { 'SHA-256'; break }
                    98 { 'SHA-384'; break }
                    128 { 'SHA-512'; break }
                    default {
                        $ExpectedHash = ''
                        $PSCmdlet.WriteWarning("Expected hash '$ExpectedHash' for file '$DownloadTarget' is of unknown algorithm. Not verifying.")
                    }
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedHash)) {
                if ($VerifiedArchives.Contains($DownloadTarget)) {
                    Write-Host -fo Green '    Already verified.'
                } else {
                    Write-Host -fo Gray '    Verifying...    ' -NoNewline

                    $PSCmdlet.WriteVerbose("Checking $Alg hash of '$DownloadTarget'.")
                    $ActualHash = Get-FileHash -Algorithm ($Alg -ireplace '[^a-z0-9]') -Path $DownloadTarget | Select-Object -ExpandProperty Hash
                    if ($ExpectedHash -ine $ActualHash) {
                        $PSCmdlet.WriteWarning("$Alg hash for '$DownloadTarget' was '$ActualHash' but expected '$ExpectedHash'.")
                        continue PlatformLoop
                    }
                    $VerifiedArchives.Add($DownloadTarget)
                    Write-Host -fo Green '    OK.'
                    $PSCmdlet.WriteDebug("Verified $Alg hash of '$DownloadTarget' == $ExpectedHash.")
                }
            }
            if ($NoExtract) {
                if ($WasDownloaded) { $PSCmdlet.WriteVerbose("Downloaded to '$DownloadTarget' successfully.") }
                continue PlatformLoop
            }
            Write-Host -fo Gray '    Extracting...   ' -NoNewline
            $StageDir = Join-Path $TempDir (New-Guid).Guid
            $null = New-Item -ItemType Directory $StageDir
            if (-not $?) { continue PlatformLoop }
            $DelList.Add($StageDir)
            switch -Regex ($DownloadTarget) {
                '\.(?:dmg|bin|exe)$' {
                    # Requires 7z
                    $7z = Get-7Zip
                    if ([string]::IsNullOrWhiteSpace($7z)) { 7zError; return }
                    & $7z x -aoa -snld -o"$StageDir" $DownloadTarget
                    if (-not $?) { continue PlatformLoop }
                    $Depth = 5
                }
                '\.zip$' {
                    # Use 7z if available
                    $7z = Get-7Zip
                    if ([string]::IsNullOrWhiteSpace($7z)) {
                        Expand-Archive $DownloadTarget -DestinationPath $StageDir -Force
                    } else {
                        & $7z x -aoa -snld -o"$StageDir" $DownloadTarget
                    }
                    if (-not $?) { continue PlatformLoop }
                    $Depth = 3
                }
                '\.tar\.(?:gz|xz|bz2)' {
                    # Requires 2-step 7z
                    $7z = Get-7Zip
                    if ([string]::IsNullOrWhiteSpace($7z)) { 7zError; return }
                    $TarArc = $DownloadUrl -replace '^.+/' -replace '\.(?:gz|xz|bz2)$'
                    $DelList.Add("$StageDir.1")
                    & $7z x -aoa -snld -o"$StageDir.1" $DownloadTarget
                    if (-not $?) { continue PlatformLoop }
                    & $7z x -aoa -snld -o"$StageDir" (Join-Path "$StageDir.1" $TarArc)
                    if (-not $?) { continue PlatformLoop }
                    $Depth = 3
                }
            }
            Write-Host -fo Green '    OK.'
            Write-Host -fo Gray '    Check NDK...     ' -NoNewline
            $NDKRootDir = Get-NDKRoot $StageDir -Depth $Depth
            if ([string]::IsNullOrWhiteSpace($NDKRootDir)) { ExtractError $StageDir; continue PlatformLoop }
            Get-ChildItem $NDKRootDir | Move-Item -Destination $NDKSubPath -Force
            if ($?) {
                Write-Host -fo Green '    OK.'
                $PSCmdlet.WriteDebug("Succeeded setting up NDK r$Ver at '$NDKSubPath'.")
            } else {
                $PSCmdlet.WriteWarning("Failed setting up NDK r$Ver at '$NDKSubPath' from '$DownloadUrl'.")
            }
        }
    }
}
end {
    foreach ($Path in $DelList) {
        if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path $Path)) {
            Remove-Item $Path -Force -Recurse
        }
    }
}

<#
.SYNOPSIS
    Downloads and extracts Android NDKs
.DESCRIPTION
    A PowerShell wrapper for downloading and extracting Android Native Development Kits (NDKs) across all supported platforms and revisions.
.PARAMETER Version
    Specifies one or more NDK versions to download. Defaults to the latest release (excluding betas).
.PARAMETER NdkDir
    Specifies where to extract the NDK files. Defaults to *./NDK* relative to the script.
.PARAMETER TempDir
    Specifies the staging directory for the downloaded archive/extracting the NDK files. Defaults to the user's temp path.
.PARAMETER KeepArchive
    Retains the downloaded NDK archive file in the temp path. It is usually deleted after extraction.
.PARAMETER ForcePlatform
    Downloads the NDK for a specific platform. Disables automatic detection.
.PARAMETER AllPlatforms
    Downloads all supported editions of the NDK (currently 64-bit Windows, Linux, or macOS). Overrides -ForcePlatform.
.PARAMETER NoExtract
    Downloads the NDK archive but doesn't attempt to extract it. Implies -KeepArchive.
.PARAMETER NoVerify
    Skips checking the archive against the stored file hash before extracting. Not recommended unless you have already
    downloaded the archive and know it's safe.
.NOTES
    The script attempts to identify the platform and download the correct NDK if -ForcePlatform and -AllPlatforms are not specified.
    In some edge cases, you may have to override this behaviour if the script cannot find an appropriate NDK edition or reports your platform
    as unsupported when it is.

    Windows 11 ARM64 and macOS on Apple Silicon both support AMD64 (x86-64) emulation and Google no longer provides any ARM64 builds for the NDK.
    The script therefore downloads the AMD64 editions for these platforms. Windows 10 ARM64 doesn't support AMD64 emulation, only x86. This script
    targets x86 editions in this case; the last NDK supporting x86 was r20 for SDK 16–29 (Android 4.1–10).

    For NDKs r5 to r9 on macOS and Linux, and r23 or later on macOS, you need [7-Zip](https://7-zip.org/) installed in order to extract the archives.
    If you have 7-Zip installed, the script will preferentially use it for ZIP archives too as it's quicker than PowerShell's own archive cmdlets.
.LINK
    https://github.com/TheFreeman193/GetNDK/blob/main/README.md
.EXAMPLE
    ./Get-NDK.ps1

    Downloads and extracts the latest stable NDK release to the ndk/ subdirectory relative to the script.
.EXAMPLE
    ./Get-NDK.ps1 -NdkDir $Home/Documents/ndk -Version 20 -ForcePlatform Win32 -KeepArchive

    Downloads and extracts NDK r20 for Windows x86 to the user's documents directory relative to the script, and keeping the downloaded archive
    in the temporary directory (%TEMP% or /tmp).
.EXAMPLE
    ./Get-NDK.ps1 -Version 11, 28 -AllPlatforms -NoExtract -TempPath $PWD

    Downloads the archives for all editions of NDKs r11 and r28 to the same directory as the script, without extracting them.
    r11 and r28 support SDKs 3-24 and 21-35 respectively, effectively all versions of Android between them.
    r11 has 32/64-bit Windows and 64-bit Linux/macOS editions, while r28 only supports building on 64-bit OSes.
#>
