<#

.SYNOPSIS
Runs and zips builds in preparation for release. The builds are made from the examples directory

.PARAMETER  TouchscreenRepositoryPath
Path to the CR-6 touch screen repository

#>
[CmdletBinding()]
Param(
    [Parameter(Mandatory=$true)]
    $TouchscreenRepositoryPath,

    [Parameter(Mandatory=$true)]
    $ReleaseName
)

# Include common scripts
#Requires -Version 6.0
. $PSScriptRoot/Common.ps1

# Ensure platform.io is available
if (!(Get-Command pio -ErrorAction SilentlyContinue)) {
    Write-FatalError "pio command is not in path - try executing this script from the VSCode console"
}

# Build touch screen
Write-Host "Building touch screen..."

$TouchscreenRepositoryPath = Resolve-Path -Path $TouchscreenRepositoryPath

if (!(Test-Path -Path $TouchscreenRepositoryPath)) {
    Write-FatalError "Unable to find path of CR-6 touch screen repository"
}

Push-Location $TouchscreenRepositoryPath

$ScriptPath = "$TouchscreenRepositoryPath\build.ps1"
try {
    & $ScriptPath

    if ($LASTEXITCODE -ne 0) {
        Throw "Unable to build touch screen: Exit code $LASTEXITCODE"
    }
} catch {
    Write-Error $_
    Write-FatalError "Unable to build touch screen"
} finally {
    Pop-Location
}

## Take the zip file
$TouchscreenBuildDir = Join-Path $TouchscreenRepositoryPath -ChildPath "build" 
[string]$TouchscreenZipFile = Get-ChildItem -Path $TouchscreenBuildDir -Filter "*.zip" | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First 1 -ExpandProperty FullName

if (!(Test-Path $TouchscreenZipFile)) {
    Write-FatalError "Unable to find touch screen build result: $TouchscreenZipFile"
}

# Now build every combination of examples
## Env
$OutputDirectory = Join-Path ".pio" "build-output"

if (Test-Path $OutputDirectory) {
    try {
        Remove-Item $OutputDirectory -Recurse -Force
    } catch {
        Write-FatalError "Unable to clean up for builds"
    }
}

New-Item $OutputDirectory -ItemType Directory | Out-Null

## Build each example
Write-Host "Collecting example configurations..."
$Configs = Get-ExampleNames

foreach ($ConfigName in $Configs) {
    $Percent = $([double] $Configs.IndexOf($ConfigName) + 1) / $Configs.Length

    Write-Progress -Activity "Building CR-6 community firmwares" `
                   -PercentComplete $Percent `
                   -CurrentOperation "Building '$ConfigName'" `
                   -Id 1337

    $ConfigDirName = Join-Path $ExamplesDirectory -ChildPath $ConfigName
    if (!(Test-Path $ConfigDirName)) {
        Write-FatalError "Unable to find configuration example directory: $ConfigDirName"
    }

    $HasTouchscreen = $(Test-Path -Path $(Join-Path -Path $ConfigDirName -ChildPath "no-touchscreen.txt")) -eq $false
    $PlatformIOEnvironment = Get-Content -Raw -Path $(Join-Path -Path $ConfigDirName -ChildPath "platformio-environment.txt")

    if ($null -eq $PlatformIOEnvironment) {
        Write-FatalError "Unable to find platform.io environment name for $ConfigName"
    }

    $ConfigBuildOutputDirectory = Join-Path -Path ".pio" "build\$PlatformIOEnvironment"

    $DatedBuildName = "$ReleaseName-$ConfigName-$(Get-Date -Format 'yyyy-MM-dd-HH-mm')"
    $DatedBuildZipFilePath = Join-Path -Path $OutputDirectory -ChildPath $($DatedBuildName + ".zip")
    $TmpBuildDirectory = Join-Path -Path $OutputDirectory -ChildPath $DatedBuildName

    New-Item -Path $TmpBuildDirectory -ItemType Directory -Verbose | Out-Null

    # Now execute the actual build
    function Invoke-PlatformIO($Target) {
        $Cmd = "pio"
        $CmdArgs = @("run", "-e", $PlatformIOEnvironment)

        if ($null -ne $Target) {
            $CmdArgs += @("-t", $Target)
        }

        Write-Host "Executing $Cmd $CmdArgs"
        & $Cmd $CmdArgs

        if ($LASTEXITCODE -ne 0) {
            Write-FatalError "Unable to execute platform.io for $ConfigName due to error"
        }
    }

    ## Clean directory
    foreach ($FilePath in $FilesPathsToDiff) {
        Write-Host "Resetting $FilePath"
        git checkout HEAD -- $FilePath
    }

    ## Clean
    Write-Progress -Activity "Building '$ConfigName'" `
                   -ParentId 1337 `
                   -PercentComplete 0 `
                   -CurrentOperation "Cleaning platform.io output"`
                   -Id 33

    Invoke-PlatformIO -Target "clean"

    ## Apply configs
    Write-Progress -Activity "Building '$ConfigName'" `
                   -ParentId 1337 `
                   -PercentComplete 33 `
                   -CurrentOperation "Applying configurations"`
                   -Id 33

    .\scripts\Apply-ConfigExample.ps1 -Name $ConfigName

    if ($LASTEXITCODE -ne 0) {
        Write-FatalError "Unable to apply configuration example for $ConfigName"
    }

    ## Build
    Write-Progress -Activity "Building '$ConfigName'" `
                   -ParentId 1337 `
                   -PercentComplete 66 `
                   -CurrentOperation "Building platform.io"`
                   -Id 33

    Invoke-PlatformIO

    ## Copy output artifacts
    Write-Progress -Activity "Building '$ConfigName'" `
                   -ParentId 1337 `
                   -PercentComplete 99 `
                   -CurrentOperation "Consolidating artifacts..."`
                   -Id 33

    [array] $FirmwareBinFiles = Get-ChildItem -Path $ConfigBuildOutputDirectory -Filter "firmware*.bin"
    if ($FirmwareBinFiles.Count -eq 0) {
        Write-FatalError "Unable to find firmware output files in $ConfigBuildOutputDirectory"
    }

    if ($FirmwareBinFiles.Count -ne 1) {
        Write-FatalError "Found multiple firmware bin files in $($ConfigBuildOutputDirectory): $FirmwareBinFiles"
    }

    try {
        $FirmwareBinFiles | Copy-Item -Destination $TmpBuildDirectory -Verbose
    } catch {
        Write-Error $_
        Write-FatalError "Unable to consolide files of build: $ConfigName"
    }

    ### Copy touch screen files
    if ($HasTouchscreen) {
        Copy-Item -Path $TouchscreenZipFile -Destination $TmpBuildDirectory -Verbose
    }

    ### Copy configuration files
    $ConfigArtifactDirPath = Join-Path -Path $TmpBuildDirectory -ChildPath "configs"
    New-Item -Path $ConfigArtifactDirPath -ItemType Directory -Verbose | Out-Null
    
    $FilesPathsToDiff | Copy-Item -Destination $ConfigArtifactDirPath

    ### Copy build include files
    Get-ChildItem -Path $(Join-Path $PSScriptRoot "build-incl") | Copy-Item -Destination $TmpBuildDirectory -Verbose

    ### Zip it!
    Get-ChildItem -Path $TmpBuildDirectory | Compress-Archive -CompressionLevel Optimal -DestinationPath $DatedBuildZipFilePath -Verbose

    ## Done
    Write-Progress -Activity "Building '$ConfigName'" `
                   -ParentId 1337 `
                   -Completed `
                   -Id 33

    Write-Host "Build $ConfigName completed - find the build in: $DatedBuildZipFilePath"
}

## Clean directory
foreach ($FilePath in $FilesPathsToDiff) {
    Write-Host "Resetting $FilePath"
    git checkout HEAD -- $FilePath
}

Write-Progress -Activity "Building CR-6 community firmwares" `
               -Completed `
               -Id 1337

Write-Host "All done!"
Write-Host ""

Get-ChildItem -Path $OutputDirectory -Filter "*.zip" | `
    Get-FileHash -Algorithm SHA256 | `
    Select-Object -Property `
        @{Expression={Split-Path $_.Path -Leaf};Name="File name"},`
        @{Expression={$_.Hash};Name="SHA256 hash"}
