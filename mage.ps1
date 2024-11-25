param (
    [Alias('p')][string]$Path = '.',
    [Alias('r')][switch]$Recurse,
    [Alias('o')][string]$OutputCsv = 'MagicNumberCheckResults.csv',
    [Alias('i')][string]$MagicNumbersFile = 'MagicNumbers.json',
    [Alias('f')][switch]$FileTypeCheck,
    [Alias('a')][switch]$Append,
    [Alias('h')][switch]$Help,
    [Alias('v')][switch]$Verbose
)

# ASCII Art Header
Write-Output @"
  __  __          _____ ______ 
 |  \/  |   /\   / ____|  ____|
 | \  / |  /  \ | |  __| |__   
 | |\/| | / /\ \| | |_ |  __|  
 | |  | |/ ____ \ |__| | |____ 
 |_|  |_/_/    \_\_____|______|

Magic Analyzer for Genuine Extensions
use -h for help
Created by Dacey Black 2024

"@

# Display help message if -Help parameter is used
if ($Help) {
    Write-Output @"
This script checks for the magic numbers contained in the file header of files and outputs.
This can be useful to validate if file has been successfully decrypted.
The MagicNumbers.json file must be in the same directory as this script.
You can add or remove filetypes from the MagicNumbers.json file as suits your need.

Usage: MagicNumberValidator.ps1 [parameters]

Parameters:
  -a,  -Append            Append results to the output CSV file instead of overwriting it.
  -f,  -FileTypeCheck     Check if the actual magic number matches any known file type's magic number.
                          (This is slower and a bit buggy but can be useful in some situations)
  -h,  -Help              Display this help message.
  -i,  -MagicNumbersFile  Specify the JSON file containing magic numbers (default is 'MagicNumbers.json').
  -o,  -OutputCsv         Specify the name of the output CSV file (default is 'MagicNumberCheckResults.csv').
  -p,  -Path              Specify the directory or individual file to check (default is current directory).
  -r,  -Recurse           Include subfolders in the check.
  -v,  -Verbose           Output detailed information to the shell.

Example:
  .\MagicNumberValidator.ps1 -p C:\Files -r -v -o Output.csv -a
"@
    exit
}

# Function to get magic numbers from the JSON file
function Get-MagicNumbers {
    param (
        [string]$MagicNumbersFile
    )
    if (Test-Path $MagicNumbersFile) {
        try {
            # Read and parse the JSON file directly into a hashtable
            $parsedJson = Get-Content -Path $MagicNumbersFile -Raw | ConvertFrom-Json
            # Convert the PSCustomObject to a hashtable explicitly
            $magicNumbersHashTable = @{}
            foreach ($key in $parsedJson.PSObject.Properties.Name) {
                $magicNumbersHashTable[$key] = $parsedJson.$key
            }
            return $magicNumbersHashTable
        } catch {
            Write-Output "[ERROR] Failed to read magic numbers from $MagicNumbersFile. Exiting."
            exit
        }
    } else {
        Write-Output "[ERROR] Magic numbers file not found: $MagicNumbersFile. The file is required. Exiting."
        exit
    }
}

# Function to test if a file's magic number matches the expected value
function Test-FileMagic {
    param (
        [string]$FilePath,
        [hashtable]$MagicNumbers,
        [switch]$FileTypeCheck
    )
    $fileExtension = [System.IO.Path]::GetExtension($FilePath).ToLower()
    if ($MagicNumbers.ContainsKey($fileExtension)) {
        $expectedMagic = $MagicNumbers[$fileExtension]
        $fileStream = [System.IO.File]::OpenRead($FilePath)
        $buffer = New-Object byte[] ($expectedMagic.Length / 2)
        $fileStream.Read($buffer, 0, $buffer.Length) | Out-Null
        $fileStream.Close()
        $fileMagic = [BitConverter]::ToString($buffer).Replace('-', '')
        $pass = $fileMagic -eq $expectedMagic
        $identifiedExtension = 'Unknown'

        # Attempt to identify the actual file type if magic number doesn't match
        if ($FileTypeCheck -and -not $pass) {
            foreach ($key in $MagicNumbers.Keys) {
                if ($MagicNumbers[$key] -eq $fileMagic) {
                    $identifiedExtension = $key
                    break
                }
            }
        }

        return [PSCustomObject]@{
            FilePath = $FilePath
            Extension = $fileExtension
            ExpectedMagic = $expectedMagic
            ActualMagic = $fileMagic
            Pass = $pass
            IdentifiedExtension = if ($FileTypeCheck) { $identifiedExtension } else { 'N/A' }
        }
    } else {
        Write-Output "[WARNING] No magic number check available for file extension: $fileExtension"
        return [PSCustomObject]@{
            FilePath = $FilePath
            Extension = $fileExtension
            ExpectedMagic = 'N/A'
            ActualMagic = 'N/A'
            Pass = 'N/A'
            IdentifiedExtension = if ($FileTypeCheck) { 'Unknown' } else { 'N/A' }
        }
    }
}

# Function to check all files in the specified directory
function Check-Files {
    param (
        [string]$Directory,
        [switch]$Recurse,
        [string]$OutputCsv,
        [hashtable]$MagicNumbers,
        [switch]$FileTypeCheck,
        [switch]$Append
    )

    # Determine whether to search subdirectories
    $searchOption = if ($Recurse) { [System.IO.SearchOption]::AllDirectories } else { [System.IO.SearchOption]::TopDirectoryOnly }
    $files = Get-ChildItem -Path $Directory -File -Recurse:$Recurse

    $results = @()
    foreach ($file in $files) {
        if ($Verbose) { Write-Output "Checking file: $($file.FullName)" }
        # Test the magic number of the file
        $result = Test-FileMagic -FilePath $file.FullName -MagicNumbers $MagicNumbers -FileTypeCheck:$FileTypeCheck
        $results += $result
        if ($result.Pass -eq $true) {
            if ($Verbose) { Write-Output "[PASS] Magic number matches for $($file.FullName)" }
        } elseif ($result.Pass -eq $false) {
            if ($Verbose) { Write-Output "[FAIL] Magic number does not match for $($file.FullName)" }
        }
    }

    # Export results to CSV file, with option to append or overwrite
    if ($Append -and (Test-Path $OutputCsv)) {
        $results | Export-Csv -Path $OutputCsv -NoTypeInformation -Append
    } else {
        $results | Export-Csv -Path $OutputCsv -NoTypeInformation
    }
    Write-Output "[INFO] Output CSV file created at: $(Resolve-Path -Path $OutputCsv)"
}

# Main script execution
try {
    # Load magic numbers from the specified JSON file
    $MagicNumbers = Get-MagicNumbers -MagicNumbersFile $MagicNumbersFile

    # Check if the specified path exists
    if (Test-Path $Path) {
        $resolvedPath = Resolve-Path $Path
        # If the path is a directory, check all files within
        if ((Get-Item -Path $resolvedPath).PSIsContainer) {
            if ($Verbose) { Write-Output "Checking directory: $resolvedPath" }
            # Check all files in the directory
            Check-Files -Directory "$resolvedPath" -Recurse:$Recurse -OutputCsv "$OutputCsv" -MagicNumbers $MagicNumbers -FileTypeCheck:$FileTypeCheck -Append:$Append
        } else {
            # If the path is a single file, check that file
            if ($Verbose) {Write-Output "Checking individual file: $resolvedPath"}
            $result = Test-FileMagic -FilePath "$resolvedPath" -MagicNumbers $MagicNumbers -FileTypeCheck:$FileTypeCheck
            if ($Append -and (Test-Path $OutputCsv)) {
                $result | Export-Csv -Path "$OutputCsv" -NoTypeInformation -Append
            } else {
                $result | Export-Csv -Path "$OutputCsv" -NoTypeInformation
            }
            if ($result.Pass -eq $true) {
                if ($Verbose) { Write-Output "[PASS] Magic number matches for $resolvedPath" }
            } elseif ($result.Pass -eq $false) {
                if ($Verbose) { Write-Output "[FAIL] Magic number does not match for $resolvedPath" }
            }
            Write-Output "[INFO] Output CSV file created at: $OutputCsv"
        }
    } else {
        Write-Output "[ERROR] Path not found: $Path"
    }
} catch {
    # Handle any errors that occur during script execution
    Write-Output "An error occurred: $($_.Exception.Message)"
}
