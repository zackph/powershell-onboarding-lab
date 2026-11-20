[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CsvPath = (Join-Path $PSScriptRoot 'new-hires.csv'),
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$labDomain = 'ad.example.test'
if ($env:COMPUTERNAME -ne 'DC01') {
    throw 'Run this script inside the DC01 lab VM.'
}

$expectedColumns = 'FirstName', 'LastName', 'Username', 'Department', 'Title'
$rows = @(Import-Csv -LiteralPath $CsvPath -Encoding UTF8)
if ($rows.Count -eq 0) { throw 'The CSV must contain at least one new hire.' }
$actualColumns = @($rows[0].PSObject.Properties.Name)
if (($actualColumns -join ',') -cne ($expectedColumns -join ',')) {
    throw "Expected CSV columns in this order: $($expectedColumns -join ', ')."
}

$seen = @{}
foreach ($row in $rows) {
    foreach ($column in $expectedColumns) {
        $row.$column = ([string]$row.$column).Trim()
        if (!$row.$column -or $row.$column -match '[\x00-\x1F\x7F]' -or $row.$column.Length -gt 64) {
            throw "Each $column value must be 1 to 64 characters without control characters."
        }
    }
    if ($row.Username -cnotmatch '^lab-[a-z][a-z0-9]*\.[a-z][a-z0-9]*$' -or $row.Username.Length -gt 20) {
        throw "Invalid lab username '$($row.Username)'. Use lab-first.last, up to 20 characters."
    }
    if ($seen.ContainsKey($row.Username)) { throw "Duplicate username in CSV: $($row.Username)." }
    $seen[$row.Username] = $true
}

Import-Module ActiveDirectory -ErrorAction Stop
$domain = Get-ADDomain
if ($domain.DNSRoot -ne $labDomain -or $domain.DistinguishedName -ne 'DC=ad,DC=example,DC=test') {
    throw "This script is limited to the $labDomain lab."
}
$server = 'DC01.ad.example.test'
$trainingOu = 'OU=training,DC=ad,DC=example,DC=test'
$destination = "OU=Onboarding,$trainingOu"
$null = Get-ADOrganizationalUnit -Identity $trainingOu -Server $server
$target = Get-ADOrganizationalUnit -LDAPFilter '(ou=Onboarding)' -SearchBase $trainingOu -SearchScope OneLevel -Server $server

$plan = foreach ($row in $rows) {
    $login = $row.Username
    $upn = "$login@$labDomain"
    # Username validation above allows only LDAP-safe characters.
    $filter = "(|(sAMAccountName=$login)(userPrincipalName=$upn))"
    $directoryMatches = @(Get-ADObject -LDAPFilter $filter -SearchBase $domain.DistinguishedName -Properties sAMAccountName,userPrincipalName -Server $server)
    $sameUser = $directoryMatches.Count -eq 1 -and $directoryMatches[0].ObjectClass -eq 'user' -and
        $directoryMatches[0].sAMAccountName -eq $login -and $directoryMatches[0].userPrincipalName -eq $upn
    if ($directoryMatches.Count -gt 0 -and !$sameUser) {
        throw "Directory identity conflict for '$login'. No changes were made."
    }
    [pscustomobject]@{ Row = $row; Upn = $upn; Exists = $sameUser }
}

$pending = @($plan | Where-Object { !$_.Exists })
if ($Apply -and $pending.Count -gt 0 -and !$target) {
    if ($PSCmdlet.ShouldProcess($destination, 'Create protected organizational unit')) {
        $target = New-ADOrganizationalUnit -Name 'Onboarding' -Path $trainingOu -ProtectedFromAccidentalDeletion $true -Server $server -PassThru
    }
}

foreach ($item in $plan) {
    $row = $item.Row
    $displayName = "$($row.FirstName) $($row.LastName)"
    $status = 'WouldCreate'
    if ($item.Exists) {
        $status = 'SkippedExisting'
    }
    elseif ($Apply -and $target -and $PSCmdlet.ShouldProcess($item.Upn, 'Create disabled onboarding account')) {
        New-ADUser -Name $row.Username -DisplayName $displayName -GivenName $row.FirstName -Surname $row.LastName `
            -SamAccountName $row.Username -UserPrincipalName $item.Upn -Department $row.Department -Title $row.Title `
            -Enabled $false -Path $destination -Server $server
        $status = 'CreatedDisabled'
    }
    [pscustomobject]@{
        Status = $status
        Username = $row.Username
        DisplayName = $displayName
        Department = $row.Department
        Destination = $destination
    }
}
