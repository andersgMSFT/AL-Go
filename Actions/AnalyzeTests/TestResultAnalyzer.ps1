﻿$statusOK = " :heavy_check_mark:"
$statusWarning = " :warning:"
$statusError = " :x:"
$statusSkipped = " :question:"

function ReadBcptFile {
    Param(
        [string] $path
    )

    if ((-not $path) -or (-not (Test-Path -Path $path -PathType Leaf))) {
        return $null
    }

    # Read BCPT file
    $bcptResult = Get-Content -Path $path -Encoding UTF8 | ConvertFrom-Json
    $suites = [ordered]@{}
    # Sort by bcptCode, codeunitID, operation
    foreach($measure in $bcptResult) {
        $bcptCode = $measure.bcptCode
        $codeunitID = $measure.codeunitID
        $codeunitName = $measure.codeunitName
        $operation = $measure.operation

        # Create Suite if it doesn't exist
        if(-not $suites.Contains($bcptCode)) {
            $suites."$bcptCode" = [ordered]@{}
        }
        # Create Codeunit under Suite if it doesn't exist
        if (-not $suites."$bcptCode".Contains("$codeunitID")) {
            $suites."$bcptCode"."$codeunitID" = @{
                "codeunitName" = $codeunitName
                "operations" = [ordered]@{}
            }
        }
        # Create Operation under Codeunit if it doesn't exist
        if (-not $suites."$bcptCode"."$codeunitID"."operations".Contains($operation)) {
            $suites."$bcptCode"."$codeunitID"."operations"."$operation" = @{
                "measurements" = @()
            }
        }
        # Add measurement to measurements under operation
        $suites."$bcptCode"."$codeunitID"."operations"."$operation".measurements += @(@{
            "durationMin" = $measure.durationMin
            "numberOfSQLStmts" = $measure.numberOfSQLStmts
        })
    }
    $suites
}

# Build MarkDown of TestResults file
# This function will not fail if the file does not exist or if any test errors are found
# TestResults is in JUnit format
# Returns both a summary part and a failures part
function GetTestResultSummaryMD {
    Param(
        [string] $path
    )

    $summarySb = [System.Text.StringBuilder]::new()
    $failuresSb = [System.Text.StringBuilder]::new()
    if (Test-Path -Path $path -PathType Leaf) {
        $testResults = [xml](Get-Content -path "$project\TestResults.xml" -Encoding UTF8)
        $totalTests = 0
        $totalTime = 0.0
        $totalFailed = 0
        $totalSkipped = 0
        if ($testResults.testsuites) {
            $appNames = @($testResults.testsuites.testsuite | ForEach-Object { $_.Properties.property | Where-Object { $_.Name -eq "appName" } | ForEach-Object { $_.Value } } | Select-Object -Unique)
            if (-not $appNames) {
                $appNames = @($testResults.testsuites.testsuite | ForEach-Object { $_.Properties.property | Where-Object { $_.Name -eq "extensionId" } | ForEach-Object { $_.Value } } | Select-Object -Unique)
            }
            foreach($testsuite in $testResults.testsuites.testsuite) {
                $totalTests += $testsuite.Tests
                $totalTime += [decimal]::Parse($testsuite.time, [System.Globalization.CultureInfo]::InvariantCulture)
                $totalFailed += $testsuite.failures
                $totalSkipped += $testsuite.skipped
            }
            Write-Host "$($appNames.Count) TestApps, $totalTests tests, $totalFailed failed, $totalSkipped skipped, $totalTime seconds"
            $summarySb.Append('|Test app|Tests|Passed|Failed|Skipped|Time|\n|:---|---:|---:|---:|---:|---:|\n') | Out-Null
            foreach($appName in $appNames) {
                $appTests = 0
                $appTime = 0.0
                $appFailed = 0
                $appSkipped = 0
                $suites = $testResults.testsuites.testsuite | where-Object { $_.Properties.property | Where-Object { $_.Value -eq $appName } }
                foreach($suite in $suites) {
                    $appTests += [int]$suite.tests
                    $appFailed += [int]$suite.failures
                    $appSkipped += [int]$suite.skipped
                    $appTime += [decimal]::Parse($suite.time, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                $appPassed = $appTests-$appFailed-$appSkipped
                Write-Host "- $appName, $appTests tests, $appPassed passed, $appFailed failed, $appSkipped skipped, $appTime seconds"
                $summarySb.Append("|$appName|$appTests|") | Out-Null
                if ($appPassed -gt 0) {
                    $summarySb.Append("$($appPassed)$statusOK") | Out-Null
                }
                $summarySb.Append("|") | Out-Null
                if ($appFailed -gt 0) {
                    $summarySb.Append("$($appFailed)$statusError") | Out-Null
                }
                $summarySb.Append("|") | Out-Null
                if ($appSkipped -gt 0) {
                    $summarySb.Append("$($appSkipped)$statusSkipped") | Out-Null
                }
                $summarySb.Append("|$($appTime)s|\n") | Out-Null
                if ($appFailed -gt 0) {
                    $failuresSb.Append("<details><summary><i>$appName, $appTests tests, $appPassed passed, $appFailed failed, $appSkipped skipped, $appTime seconds</i></summary>\n") | Out-Null
                    foreach($suite in $suites) {
                        Write-Host "  - $($suite.name), $($suite.tests) tests, $($suite.failures) failed, $($suite.skipped) skipped, $($suite.time) seconds"
                        if ($suite.failures -gt 0 -and $failuresSb.Length -lt 32000) {
                            $failuresSb.Append("<details><summary><i>$($suite.name), $($suite.tests) tests, $($suite.failures) failed, $($suite.skipped) skipped, $($suite.time) seconds</i></summary>") | Out-Null
                            foreach($testcase in $suite.testcase) {
                                if ($testcase.ChildNodes.Count -gt 0) {
                                    Write-Host "    - $($testcase.name), Failure, $($testcase.time) seconds"
                                    $failuresSb.Append("<details><summary><i>$($testcase.name), Failure</i></summary>") | Out-Null
                                    foreach($failure in $testcase.ChildNodes) {
                                        Write-Host "      - Error: $($failure.message)"
                                        Write-Host "        Stacktrace:"
                                        Write-Host "        $($failure."#text".Trim().Replace("`n","`n        "))"
                                        $failuresSb.Append("<i>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Error: $($failure.message)</i><br/>") | Out-Null
                                        $failuresSb.Append("<i>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Stack trace</i><br/>") | Out-Null
                                        $failuresSb.Append("<i>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;$($failure."#text".Trim().Replace("`n","<br/>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"))</i><br/>") | Out-Null
                                    }
                                    $failuresSb.Append("</details>") | Out-Null
                                }
                            }
                            $failuresSb.Append("</details>") | Out-Null
                        }
                    }
                    $failuresSb.Append("</details>") | Out-Null
                }
            }
        }
        if ($totalFailed -gt 0) {
            $failuresSummaryMD = "<i>$totalFailed failing tests, download test results to see details</i>"
            $failuresSb.Insert(0,"<details><summary>$failuresSummaryMD</summary>") | Out-Null
            $failuresSb.Append("</details>") | Out-Null
        }
        else {
            $failuresSummaryMD = "<i>No test failures</i>"
            $failuresSb.Append($failuresSummaryMD) | Out-Null
        }
    }
    else {
        $summarySb.Append("<i>No test results found</i>") | Out-Null
        $failuresSummaryMD = ''
    }
    $summarySb.ToString()
    $failuresSb.ToString()
    $failuresSummaryMD
}

function GetBcptSummaryMD {
    Param(
        [string] $path,
        [string] $baseLinePath = '',
        [string] $thresholdsPath = '',
        [int] $skipMeasurements = 0,
        [int] $DurationThresholdWarning = 10,
        [int] $DurationThresholdError = 25,
        [int] $NumberOfSqlStmtsThresholdWarning = 5,
        [int] $NumberOfSqlStmtsThresholdError = 10
    )

    $bcpt = ReadBcptFile -path $path
    if (-not $bcpt) {
        return ''
    }
    $baseLine = ReadBcptFile -path $baseLinePath
    # Override thresholds if thresholds file exists
    if ($thresholdsPath -and (Test-Path -path $thresholdsPath)) {
        Write-Host "Reading thresholds from $thresholdsPath"
        $thresholds = Get-Content -Path $thresholdsPath -Encoding UTF8 | ConvertFrom-Json
        foreach($threshold in 'DurationThresholdWarning', 'DurationThresholdError', 'NumberOfSqlStmtsThresholdWarning', 'NumberOfSqlStmtsThresholdError') {
            if ($thresholds.PSObject.Properties.Name -eq $threshold) {
                Set-Variable -Name $threshold -Value $thresholds."$threshold" -Scope local
            }
        }
    }
    Write-Host "Using thresholds:"
    Write-Host "- DurationThresholdWarning: $DurationThresholdWarning"
    Write-Host "- DurationThresholdError: $DurationThresholdError"
    Write-Host "- NumberOfSqlStmtsThresholdWarning: $NumberOfSqlStmtsThresholdWarning"
    Write-Host "- NumberOfSqlStmtsThresholdError: $NumberOfSqlStmtsThresholdError"

    $summarySb = [System.Text.StringBuilder]::new()
    if ($baseLine) {
        $summarySb.Append("|BCPT Suite|Codeunit ID|Codeunit Name|Operation|Status|Duration (ms)|Duration base (ms)|Duration diff (ms)|Duration diff|SQL Stmts|SQL Stmts base|SQL Stmts diff|SQL Stmts diff|\n") | Out-Null
        $summarySb.Append("|:---------|:----------|:------------|:--------|:----:|------------:|-----------------:|-----------------:|------------:|--------:|-------------:|-------------:|-------------:|\n") | Out-Null
    }
    else {
        $summarySb.Append("|BCPT Suite|Codeunit ID|Codeunit Name|Operation|Duration (ms)|SQL Stmts|\n") | Out-Null
        $summarySb.Append("|:---------|:----------|:------------|:--------|------------:|--------:|\n") | Out-Null
    }

    $lastSuiteName = ''
    $lastCodeunitID = ''
    $lastCodeunitName = ''
    $lastOperationName = ''

    # calculate statistics on measurements, skipping the $skipMeasurements longest measurements
    foreach($suiteName in $bcpt.Keys) {
        $suite = $bcpt."$suiteName"
        foreach($codeUnitID in $suite.Keys) {
            $codeunit = $suite."$codeunitID"
            $codeUnitName = $codeunit.codeunitName
            foreach($operationName in $codeunit."operations".Keys) {
                $operation = $codeunit."operations"."$operationName"
                # Get measurements to use for statistics
                $measurements = @($operation."measurements" | Sort-Object -Descending { $_.durationMin } | Select-Object -Skip $skipMeasurements)
                # Calculate statistics and store them in the operation
                $durationMin = ($measurements | ForEach-Object { $_.durationMin } | Measure-Object -Minimum).Minimum
                $numberOfSQLStmts = ($measurements | ForEach-Object { $_.numberOfSQLStmts } | Measure-Object -Minimum).Minimum

                $baseLineFound = $true
                try {
                    $baseLineMeasurements = @($baseLine."$suiteName"."$codeUnitID"."operations"."$operationName"."measurements" | Sort-Object -Descending { $_.durationMin } | Select-Object -Skip $skipMeasurements)
                    if ($baseLineMeasurements.Count -eq 0) {
                        throw "No base line measurements"
                    }
                    $baseDurationMin = ($baseLineMeasurements | ForEach-Object { $_.durationMin } | Measure-Object -Minimum).Minimum
                    $diffDurationMin = $durationMin-$baseDurationMin
                    $baseNumberOfSQLStmts = ($baseLineMeasurements | ForEach-Object { $_.numberOfSQLStmts } | Measure-Object -Minimum).Minimum
                    $diffNumberOfSQLStmts = $numberOfSQLStmts-$baseNumberOfSQLStmts
                }
                catch {
                    $baseLineFound = $false
                    $baseDurationMin = $durationMin
                    $diffDurationMin = 0
                    $baseNumberOfSQLStmts = $numberOfSQLStmts
                    $diffNumberOfSQLStmts = 0
                }

                $pctDurationMin = ($durationMin-$baseDurationMin)*100/$baseDurationMin
                $durationMinStr = "$($durationMin.ToString("#"))|"
                $baseDurationMinStr = "$($baseDurationMin.ToString("#"))|"
                $diffDurationMinStr = "$($diffDurationMin.ToString("+#;-#;0"))|$($pctDurationMin.ToString('+#;-#;0'))%|"

                $pctNumberOfSQLStmts = ($numberOfSQLStmts-$baseNumberOfSQLStmts)*100/$baseNumberOfSQLStmts
                $numberOfSQLStmtsStr = "$($numberOfSQLStmts.ToString("#"))|"
                $baseNumberOfSQLStmtsStr = "$($baseNumberOfSQLStmts.ToString("#"))|"
                $diffNumberOfSQLStmtsStr = "$($diffNumberOfSQLStmts.ToString("+#;-#;0"))|$($pctNumberOfSQLStmts.ToString('+#;-#;0'))%|"

                $thisOperationName = ''; if ($operationName -ne $lastOperationName) { $thisOperationName = $operationName }
                $thisCodeunitName = ''; if ($codeunitName -ne $lastCodeunitName) { $thisCodeunitName = $codeunitName; $thisOperationName = $operationName }
                $thisCodeunitID = ''; if ($codeunitID -ne $lastCodeunitID) { $thisCodeunitID = $codeunitID; $thisOperationName = $operationName }
                $thisSuiteName = ''; if ($suiteName -ne $lastSuiteName) { $thisSuiteName = $suiteName; $thisOperationName = $operationName }

                if (!$baseLine) {
                    # No baseline provided
                    $statusStr = ''
                    $baseDurationMinStr = ''
                    $diffDurationMinStr = ''
                    $baseNumberOfSQLStmtsStr = ''
                    $diffNumberOfSQLStmtsStr = ''
                }
                else {
                    if (!$baseLineFound) {
                        # Baseline provided, but not found for this operation
                        $statusStr = $statusSkipped
                        $baseDurationMinStr = 'N/A|'
                        $diffDurationMinStr = '||'
                        $baseNumberOfSQLStmtsStr = 'N/A|'
                        $diffNumberOfSQLStmtsStr = '||'
                    }
                    else {
                        $statusStr = $statusOK
                        if ($pctDurationMin -ge $DurationThresholdError) {
                            $statusStr = $statusError
                            if ($thisCodeunitName) {
                                # Only give errors and warnings on top level operation
                                OutputError -message "$operationName in $($suiteName):$codeUnitID degrades $($pctDurationMin.ToString('N0'))%, which exceeds the error threshold of $($DurationThresholdError)% for duration"
                            }
                        }
                        if ($pctNumberOfSQLStmts -ge $NumberOfSqlStmtsThresholdError) {
                            $statusStr = $statusError
                            if ($thisCodeunitName) {
                                # Only give errors and warnings on top level operation
                                OutputError -message "$operationName in $($suiteName):$codeUnitID degrades $($pctNumberOfSQLStmts.ToString('N0'))%, which exceeds the error threshold of $($NumberOfSqlStmtsThresholdError)% for number of SQL statements"
                            }
                        }
                        if ($statusStr -eq $statusOK) {
                            if ($pctDurationMin -ge $DurationThresholdWarning) {
                                $statusStr = $statusWarning
                                if ($thisCodeunitName) {
                                    # Only give errors and warnings on top level operation
                                    OutputWarning -message "$operationName in $($suiteName):$codeUnitID degrades $($pctDurationMin.ToString('N0'))%, which exceeds the warning threshold of $($DurationThresholdWarning)% for duration"
                                }
                            }
                            if ($pctNumberOfSQLStmts -ge $NumberOfSqlStmtsThresholdWarning) {
                                $statusStr = $statusWarning
                                if ($thisCodeunitName) {
                                    # Only give errors and warnings on top level operation
                                    OutputWarning -message "$operationName in $($suiteName):$codeUnitID degrades $($pctNumberOfSQLStmts.ToString('N0'))%, which exceeds the warning threshold of $($NumberOfSqlStmtsThresholdWarning)% for number of SQL statements"
                                }
                            }
                        }
                    }
                    $statusStr += '|'
                }

                $summarySb.Append("|$thisSuiteName|$thisCodeunitID|$thisCodeunitName|$thisOperationName|$statusStr$durationMinStr$baseDurationMinStr$diffDurationMinStr$numberOfSQLStmtsStr$baseNumberOfSQLStmtsStr$diffNumberOfSQLStmtsStr\n") | Out-Null

                $lastSuiteName = $suiteName
                $lastCodeunitID = $codeUnitID
                $lastCodeunitName = $codeUnitName
                $lastOperationName = $operationName
            }
        }
    }

    if ($baseLine) {
        $summarySb.Append("\n<i>Used baseline provided in $([System.IO.Path]::GetFileName($baseLinePath)).</i>") | Out-Null
    }
    else {
        $summarySb.Append("\n<i>No baseline provided. Copy a set of BCPT results to $([System.IO.Path]::GetFileName($baseLinePath)) in the project folder in order to establish a baseline.</i>") | Out-Null
    }

    $summarySb.ToString()
}
