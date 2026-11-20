[CmdletBinding()]
param([switch]$Apply)

$ErrorActionPreference = 'Stop'
$onboard = Join-Path $PSScriptRoot 'Invoke-LabOnboarding.ps1'
$csv = Join-Path $PSScriptRoot 'new-hires.csv'
$expected = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
if ($expected.Count -ne 3) { throw 'The sample test expects three new hires.' }

Write-Host '1. Preview (read-only)'
$preview = @(& $onboard -CsvPath $csv)
$preview | Format-Table Status,Username,DisplayName,Department -AutoSize
if (!$Apply) { return }

Write-Host '2. Apply (create disabled accounts)'
$applied = @(& $onboard -CsvPath $csv -Apply -Confirm:$false)
$applied | Format-Table Status,Username,DisplayName,Department -AutoSize

Write-Host '3. Repeat apply (expect all existing accounts to be skipped)'
$repeated = @(& $onboard -CsvPath $csv -Apply -Confirm:$false)
$repeated | Format-Table Status,Username -AutoSize
if ($repeated.Count -ne 3 -or @($repeated | Where-Object Status -ne 'SkippedExisting').Count -ne 0) {
    throw 'Repeat-run verification failed.'
}

Write-Host '4. Read back the three sample accounts from Active Directory'
$base = 'OU=Onboarding,OU=training,DC=ad,DC=example,DC=test'
$actual = @(Get-ADUser -Filter * -SearchBase $base -SearchScope OneLevel -Server 'DC01.ad.example.test' -Properties DisplayName,Department,Title,UserPrincipalName)
$verified = foreach ($person in $expected) {
    $account = @($actual | Where-Object SamAccountName -eq $person.Username)
    if ($account.Count -ne 1 -or $account[0].Enabled -or
        $account[0].DisplayName -ne "$($person.FirstName) $($person.LastName)" -or
        $account[0].Department -ne $person.Department -or $account[0].Title -ne $person.Title -or
        $account[0].UserPrincipalName -ne "$($person.Username)@ad.example.test") {
        throw "Directory verification failed for '$($person.Username)'."
    }
    $account[0] | Select-Object SamAccountName,DisplayName,Department,Enabled
}
$verified | Format-Table -AutoSize
Write-Host 'PASS: Three disabled lab accounts verified. Repeat apply skipped all three.' -ForegroundColor Green
