﻿[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Global vars used for local test execution only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'All scenario tests have equal parameter set.')]
Param(
    [switch] $github,
    [string] $githubOwner = $global:E2EgithubOwner,
    [string] $repoName = [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetTempFileName()),
    [string] $token = ($Global:SecureE2EPAT | Get-PlainText),
    [string] $pteTemplate = $global:pteTemplate,
    [string] $appSourceTemplate = $global:appSourceTemplate,
    [string] $adminCenterApiToken = ($global:SecureAdminCenterApiToken | Get-PlainText),
    [string] $licenseFileUrl = ($global:SecureLicenseFileUrl | Get-PlainText)
)

Write-Host -ForegroundColor Yellow @'
#  _____                       _____  _       _    __                        _____       _       _   _
# |  __ \                     |  __ \| |     | |  / _|                      / ____|     | |     | | (_)
# | |__) |____      _____ _ __| |__) | | __ _| |_| |_ ___  _ __ _ __ ___   | (___   ___ | |_   _| |_ _  ___  _ __
# |  ___/ _ \ \ /\ / / _ \ '__|  ___/| |/ _` | __|  _/ _ \| '__| '_ ` _ \   \___ \ / _ \| | | | | __| |/ _ \| '_ \
# | |  | (_) \ V  V /  __/ |  | |    | | (_| | |_| || (_) | |  | | | | | |  ____) | (_) | | |_| | |_| | (_) | | | |
# |_|   \___/ \_/\_/ \___|_|  |_|    |_|\__,_|\__|_| \___/|_|  |_| |_| |_| |_____/ \___/|_|\__,_|\__|_|\___/|_| |_|
#
#
# This test tests the following scenario:
#
#  - For the three bcsamples repositories: microsoft/bcsamples-takeorder, microsoft/bcsamples-CoffeeMR and microsoft/bcsampels-WarehouseHelper do the following:
#  - Create a new repository with the same content as the repository
#  - Run the Update AL-Go System Files with the latest AL-Go version (main)
#  - Run the Update AL-Go System Files with the test version
#  - Check that PP workflows exists
#  - Run the "CI/CD" workflow
#  - Check that artifacts are created for the app and the PowerPlatform solution
#  - Remove the repository
#
'@

$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

Remove-Module e2eTestHelper -ErrorAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot "..\..\e2eTestHelper.psm1") -DisableNameChecking

$branch = "main"
$template = "https://github.com/$pteTemplate"
$repoPath = (Get-Location).Path

$repositories = @('bcsamples-WarehouseHelper', 'bcsamples-takeorder', 'bcsamples-CoffeeMR')
$repoVars = @{}

foreach($sourceRepo in $repositories) {
    $repoName = [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetTempFileName())
    Push-Location
    $repository = "$githubOwner/$repoName"

    # Login
    SetTokenAndRepository -github:$github -githubOwner $githubOwner -token $token -repository $repository

    # Create repository1
    CreateAlGoRepository `
        -github:$github `
        -template "https://github.com/microsoft/$sourceRepo" `
        -repository $repository `
        -branch $branch `
        -contentScript {
            Param([string] $path)
            Remove-PropertiesFromJsonFile -path (Join-Path $path '.github/AL-Go-Settings.json') -properties @('environments','DeployTo*')
        }

    $repoPath = (Get-Location).Path
    Write-Host "Repo Path: $repoPath"

    $settings = Get-Content -Path '.github/AL-Go-Settings.json' -Raw | ConvertFrom-Json
    Write-Host "PowerPlatform Solution Folder: $($settings.powerPlatformSolutionFolder)"

    SetRepositorySecret -repository $repository -name 'GHTOKENWORKFLOW' -value $token

    if ($settings.templateUrl -eq 'https://github.com/Microsoft/AL-Go-PTE@PPPreview') {
        # Upgrade AL-Go System Files from PPPreview to main (PPPreview branch still uses Y/N prompt and doesn't support direct AL-Go development - i.e. freddydk/AL-Go@branch)
        $parameters = @{
            "templateUrl" = 'https://github.com/microsoft/AL-Go-PTE@main'
            "directCommit" = 'Y'
        }
        RunWorkflow -name 'Update AL-Go System Files' -parameters $parameters -wait -branch $branch -repository $repository
    }

    # Upgrade AL-Go System Files to test version
    RunUpdateAlGoSystemFiles -directCommit -wait -templateUrl $template -ghTokenWorkflow $token -repository $repository | Out-Null

    CancelAllWorkflows -repository $repository

    # Pull and test workflows
    Pull
    Test-Path -Path '.github/workflows/PullPowerPlatformChanges.yaml' | Should -Be $true -Because "PullPowerPlatformChanges workflow exists"
    Test-Path -Path '.github/workflows/PushPowerPlatformChanges.yaml' | Should -Be $true -Because "PushPowerPlatformChanges workflow exists"
    Test-Path -Path '.github/workflows/_BuildPowerPlatformSolution.yaml' | Should -Be $true -Because "_BuildPowerPlatformSolution workflow exists"

    $run = RunCICD -repository $repository -branch $branch
    Pop-Location

    $repoVars."$sourceRepo" = @{
        "run" = $run
        "repoPath" = $repoPath
        "repoName" = $repoName
        "settings" = $settings
    }
}

foreach($sourceRepo in $repositories) {
    $repoVar = $repoVars."$sourceRepo"
    $run = $repoVar.run
    $repoPath = $repoVar.repoPath
    $repoName = $repoVar.repoName
    $settings = $repoVar.settings

    $repository = "$githubOwner/$repoName"

    Push-Location $repoPath
    WaitWorkflow -repository $repository -runid $run.id

    # Test artifacts generated
    Test-ArtifactsFromRun -runid $run.id -folder 'artifacts' -expectedArtifacts @{"Apps"=1} -repoVersion '*.*' -appVersion '*.*'

    # Test PowerPlatform solution artifact
    Test-Path -Path "./artifacts/$($settings.powerPlatformSolutionFolder)-$branch-PowerPlatformSolution-*.*.*.*/$($settings.powerPlatformSolutionFolder).zip" | Should -Be $true -Because "PowerPlatform solution artifact exists"

    Pop-Location
    RemoveRepository -repository $repository -path $repoPath
}
