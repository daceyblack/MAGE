param (
    [Alias('p')][string]$Path = '.',
    [Alias('r')][switch]$Recurse,
    [Alias('o')][string]$OutputCsv = 'MagicNumberCheckResults.csv',
    [Alias('i')][string]$MagicNumbersFile = 'MagicNumbers.json',
    [Alias('f')][switch]$FileTypeCheck,
    [Alias('a')][switch]$Append,
    [Alias('h')][switch]$Help,
    [Alias('v')][switch]$Verbose,
    [Alias('s')][switch]$SkipUnknown,
    [Alias('b')][int]$BatchSize = 100
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
  -b,  -BatchSize         Specify the number of files to process before writing to the CSV (default is 100).
  -f,  -FileTypeCheck     Check if the actual magic number matches any known file type's magic number.
                          (This is slower if you have many mis-extentioned but valid files but may be helpful in some situations)
  -h,  -Help              Display this help message.
  -i,  -MagicNumbersFile  Specify the JSON file containing magic numbers (default is 'MagicNumbers.json').
  -o,  -OutputCsv         Specify the name of the output CSV file (default is 'MagicNumberCheckResults.csv').
  -p,  -Path              Specify the directory or individual file to check (default is current directory).
  -r,  -Recurse           Include subfolders in the check.
  -s,  -SkipUnknown       Skip files that don't have an extension listed in the MagicNumbers.json file. (faster)
  -v,  -Verbose           Output detailed information to the shell.

Example:
  .\MagicNumberValidator.ps1 -p C:\Files -r -v -o Output.csv -a -s
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

# Function to get the maximum magic number length from the magic numbers hashtable
function Get-MaxMagicNumberLength {
    param (
        [hashtable]$MagicNumbers
    )
    $maxLength = 0
    foreach ($value in $MagicNumbers.Values) {
        $length = $value.Length / 2
        if ($length -gt $maxLength) {
            $maxLength = $length
        }
    }
    return $maxLength
}

# Function to test if a file's magic number matches the expected value
function Test-FileMagic {
    param (
        [string]$FilePath,
        [hashtable]$MagicNumbers,
        [switch]$FileTypeCheck
    )
    $fileExtension = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $expectedMagic = if ($MagicNumbers.ContainsKey($fileExtension)) { $MagicNumbers[$fileExtension] } else { '' }
    $pass = $false
    $identifiedExtension = 'Unknown'
    $fileMagic = ''

    # Only open and read the file if it has a known file type or if -f is enabled
    if ($expectedMagic -ne '' -or $FileTypeCheck) {
        $maxMagicLength = Get-MaxMagicNumberLength -MagicNumbers $MagicNumbers
        $fileStream = [System.IO.File]::OpenRead($FilePath)
        $buffer = New-Object byte[] $maxMagicLength
        $fileStream.Read($buffer, 0, $buffer.Length) | Out-Null
        $fileStream.Close()
        $fileMagic = [BitConverter]::ToString($buffer).Replace('-', '')
    }

    # Check if the magic number matches the expected value for the file extension
    if ($expectedMagic -ne '' -and $fileMagic.Length -ge $expectedMagic.Length) {
        $fileMagicTruncated = $fileMagic.Substring(0, $expectedMagic.Length)
        $pass = $fileMagicTruncated -eq $expectedMagic
        if ($pass) {
            $identifiedExtension = $fileExtension
        }
    }

    # Attempt to identify the actual file type if magic number doesn't match or if -f is enabled
    if ($FileTypeCheck -and (-not $pass -or $expectedMagic -eq '')) {
        foreach ($key in $MagicNumbers.Keys) {
            $currentMagic = $MagicNumbers[$key]
            if ($fileMagic.Length -ge $currentMagic.Length -and $currentMagic -eq $fileMagic.Substring(0, $currentMagic.Length)) {
                $identifiedExtension = $key
                break
            }
        }
    }

    return [PSCustomObject]@{
        FilePath = $FilePath
        Extension = $fileExtension
        ExpectedMagic = if ($expectedMagic -ne '') { $expectedMagic } else { 'N/A' }
        ActualMagic = if ($fileMagic.Length -ge $maxMagicLength) { $fileMagic.Substring(0, $maxMagicLength) } else { 'N/A' }
        Pass = if ($expectedMagic -ne '') { $pass } else { 'N/A' }
        IdentifiedExtension = $identifiedExtension
    }
}

# Main script execution
try {
    # Load magic numbers from the specified JSON file
    $MagicNumbers = Get-MagicNumbers -MagicNumbersFile $MagicNumbersFile

    # Initialize results array and file counter
    $results = @()
    $fileCounter = 0

    # Check if the specified path exists
    if (Test-Path $Path) {
        $resolvedPath = Resolve-Path $Path
        if ((Get-Item -Path $resolvedPath).PSIsContainer) {
            # Lazy file enumeration
            $searchOption = if ($Recurse) { [System.IO.SearchOption]::AllDirectories } else { [System.IO.SearchOption]::TopDirectoryOnly }
            [System.IO.Directory]::EnumerateFiles($resolvedPath, "*", $searchOption) | ForEach-Object {
                $fileExtension = [System.IO.Path]::GetExtension($_).ToLower()
                if ($SkipUnknown -and -not $MagicNumbers.ContainsKey($fileExtension)) {
                    if ($Verbose) { Write-Output "[SKIP] Aggressively skipping file with unknown extension: $_" }
                    return
                }
                if ($Verbose) { Write-Output "Checking file: $_" }
                $result = Test-FileMagic -FilePath $_ -MagicNumbers $MagicNumbers -FileTypeCheck:$FileTypeCheck
                $results += $result
                $fileCounter++

                # Write to CSV if batch size is reached
                if ($fileCounter -ge $BatchSize) {
                    if ($Append -and (Test-Path $OutputCsv)) {
                        $results | Export-Csv -Path $OutputCsv -NoTypeInformation -Append -Force
                    } else {
                        $results | Export-Csv -Path $OutputCsv -NoTypeInformation
                        $Append = $true  # Ensure subsequent writes append
                    }
                    $results = @()  # Clear the results array
                    $fileCounter = 0
                }
            }

            # Final write for remaining results
            if ($results.Count -gt 0) {
                if ($Append -and (Test-Path $OutputCsv)) {
                    $results | Export-Csv -Path $OutputCsv -NoTypeInformation -Append -Force
                } else {
                    $results | Export-Csv -Path $OutputCsv -NoTypeInformation
                }
            }
            Write-Output "[INFO] Output CSV file created at: $(Resolve-Path -Path $OutputCsv)"
        } else {
            # If the path is a single file, check that file
            $fileExtension = [System.IO.Path]::GetExtension($resolvedPath).ToLower()
            if ($SkipUnknown -and -not $MagicNumbers.ContainsKey($fileExtension)) {
                if ($Verbose) { Write-Output "[SKIP] Aggressively skipping file with unknown extension: $resolvedPath" }
                exit
            }
            if ($Verbose) { Write-Output "Checking individual file: $resolvedPath" }
            $result = Test-FileMagic -FilePath "$resolvedPath" -MagicNumbers $MagicNumbers -FileTypeCheck:$FileTypeCheck
            $results += $result

            # Write the final result to the CSV
            if ($Append -and (Test-Path $OutputCsv)) {
                $results | Export-Csv -Path "$OutputCsv" -NoTypeInformation -Append -Force
            } else {
                $results | Export-Csv -Path "$OutputCsv" -NoTypeInformation
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
