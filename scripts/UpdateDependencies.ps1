#!/usr/bin/env pwsh -c
<#
.PARAMETER BuildXml
    The URL or file path to a build.xml file that defines package versions to be used
#>
[CmdletBinding()]
param(
    [string]
    $BuildXml,
    [switch]$UseCoreFx,
    [string[]]$ConfigVars = @()
)

$ErrorActionPreference = 'Stop'
Import-Module -Scope Local -Force "$PSScriptRoot/common.psm1"
Set-StrictMode -Version 1

$depsPath = Resolve-Path "$PSScriptRoot/../build/dependencies.props"
[xml] $dependencies = LoadXml $depsPath

$variables = @{}

if ($UseCoreFx) {
    $githubRaw = "https://raw.githubusercontent.com"
    $versionsRepo = "dotnet/versions"
    $versionsBranch = "master"

    $coreSetupRepo = "dotnet/core-setup"
    $coreFxRepo = "dotnet/corefx"

    $coreSetupVersions = "$githubRaw/$versionsRepo/$versionsBranch/build-info/$coreSetupRepo/master/Latest_Packages.txt"

    $tempDir = "$PSScriptRoot/../obj"
    $localCoreSetupVersions = "$tempDir/coresetup.packages"
    Write-Host "Downloading $coreSetupVersions to $localCoreSetupVersions"
    Invoke-WebRequest -OutFile $localCoreSetupVersions -Uri $coreSetupVersions

    $msNetCoreAppPackageVersion = $null
    $msNetCoreAppPackageName = "Microsoft.NETCore.App"
    foreach ($line in Get-Content $localCoreSetupVersions) {
        if ($line.StartsWith("$msNetCoreAppPackageName ")) {
            $msNetCoreAppPackageVersion = $line.Trim("$msNetCoreAppPackageName ")
        }
        $parts = $line.Split(' ')
        $packageName = $parts[0]

        $varName = "$packageName" + "PackageVersion"
        $varName = $varName.Replace('.', '')

        $packageVersion = $parts[1]
        if ($variables[$varName]) {
            if ($variables[$varName].Where( {$_ -eq $packageVersion}, 'First').Count -eq 0) {
                $variables[$varName] += $packageVersion
            }
        }
        else {
            $variables[$varName] = @($packageVersion)
        }
    }

    if (!$msNetCoreAppPackageVersion) {
        Throw "$msNetCoreAppPackageName was not in $coreSetupVersions"
    }

    $coreAppDownloadLink = "https://dotnet.myget.org/F/dotnet-core/api/v2/package/$msNetCoreAppPackageName/$msNetCoreAppPackageVersion"
    $netCoreAppNupkg = "$tempDir/microsoft.netcore.app.zip"
    Invoke-WebRequest -OutFile $netCoreAppNupkg -Uri $coreAppDownloadLink
    $expandedNetCoreApp = "$tempDir/microsoft.netcore.app/"
    Expand-Archive -Path $netCoreAppNupkg -DestinationPath $expandedNetCoreApp -Force
    $versionsTxt = "$expandedNetCoreApp/$msNetCoreAppPackageName.versions.txt"

    $versionsCoreFxCommit = $null
    foreach ($line in Get-Content $versionsTxt) {
        if ($line.StartsWith("dotnet/versions/corefx")) {
            $versionsCoreFxCommit = $line.Split(' ')[1]
            break
        }
    }

    if (!$versionsCoreFxCommit) {
        Throw "no 'dotnet/versions/corefx' in versions.txt of Microsoft.NETCore.App"
    }

    $coreFxVersionsUrl = "$githubRaw/$versionsRepo/$versionsCoreFxCommit/build-info/$coreFxRepo/$versionsBranch/Latest_Packages.txt"
    $localCoreFxVersions = "$tempDir/$corefx.packages"
    Invoke-WebRequest -OutFile $localCoreFxVersions -Uri $coreFxVersionsUrl

    foreach ($line in Get-Content $localCoreFxVersions) {
        $parts = $line.Split(' ')

        $packageName = $parts[0]

        $varName = "$packageName" + "PackageVersion"
        $varName = $varName.Replace('.', '')
        $packageVersion = $parts[1]
        if ($variables[$varName]) {
            if ($variables[$varName].Where( {$_ -eq $packageVersion}, 'First').Count -eq 0) {
                $variables[$varName] += $packageVersion
            }
        }
        else {
            $variables[$varName] = @($packageVersion)
        }
    }
}
else {
    if ($BuildXml -like 'http*') {
        $url = $BuildXml
        New-Item -Type Directory "$PSScriptRoot/../obj/" -ErrorAction Ignore
        $localXml = "$PSScriptRoot/../obj/build.xml"
        Write-Verbose "Downloading from $url to $BuildXml"
        Invoke-WebRequest -OutFile $localXml $url
    }

    [xml] $remoteDeps = LoadXml $localXml

    foreach ($package in $remoteDeps.SelectNodes('//Package')) {
        $packageId = $package.Id
        $packageVersion = $package.Version
        $varName = PackageIdVarName $packageId
        Write-Verbose "Found {id: $packageId, version: $packageVersion, varName: $varName }"

        if ($variables[$varName]) {
            if ($variables[$varName].Where( {$_ -eq $packageVersion}, 'First').Count -eq 0) {
                $variables[$varName] += $packageVersion
            }
        }
        else {
            $variables[$varName] = @($packageVersion)
        }
    }
}

$updatedVars = @{}
$count = 0

foreach ($varName in ($variables.Keys | sort)) {
    $packageVersions = $variables[$varName]
    if ($packageVersions.Length -gt 1) {
        Write-Warning "Skipped $varName. Multiple version found. { $($packageVersions -join ', ') }."
        continue
    }

    $packageVersion = $packageVersions | Select-Object -First 1

    $depVarNode = $dependencies.SelectSingleNode("//PropertyGroup[`@Label=`"Package Versions: Auto`"]/$varName")
    if ($depVarNode -and $depVarNode.InnerText -ne $packageVersion) {
        $depVarNode.InnerText = $packageVersion
        $count++
        Write-Host -f DarkGray "   Updating $varName to $packageVersion"
        $updatedVars[$varName] = $packageVersion
    }
    elseif ($depVarNode) {
        Write-Host -f DarkBlue "   Didn't update $varName to $packageVersion because it was $($depVarNode.InnerText)"
    }
    else {
        # This isn't a dependency we use
    }
}

if ($count -gt 0) {
    Write-Host -f Cyan "Updating $count version variables in $depsPath"
    SaveXml $dependencies $depsPath

    # Ensure dotnet is installed
    # & "$PSScriptRoot\..\run.ps1" install-tools

    # $ProjectPath = "$PSScriptRoot\update-dependencies\update-dependencies.csproj"

    # $ConfigVars += "--BuildXml"
    # $ConfigVars += $BuildXml

    # $ConfigVars += "--UpdatedVersions"
    # $varString = ""
    # foreach ($updatedVar in $updatedVars.GetEnumerator()) {
    #     $varString += "$($updatedVar.Name)=$($updatedVar.Value);"
    # }
    # $ConfigVars += $varString

    # # Restore and run the app
    # #Write-Host "Invoking App $ProjectPath..."
    # #Invoke-Expression "dotnet run -p `"$ProjectPath`" @ConfigVars"
    # if ($LASTEXITCODE -ne 0) { throw "Build failed" }
}
else {
    Write-Host -f Green "No changes found"
}
