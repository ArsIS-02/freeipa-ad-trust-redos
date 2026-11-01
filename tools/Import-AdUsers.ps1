<#
.SYNOPSIS
    Импорт тестовых пользователей и групп в Active Directory из CSV, который делает gen_users.py.

.DESCRIPTION
    Запускай на контроллере домена или на машине с модулем ActiveDirectory (RSAT).
    Всё создаётся в отдельном подразделении (по умолчанию LabGenerated), поэтому очистка удаляет
    только его содержимое и не затрагивает остальной каталог.

.EXAMPLE
    .\Import-AdUsers.ps1 -Domain corp.example.com -CsvPath .\users.csv -DryRun
    .\Import-AdUsers.ps1 -Domain corp.example.com -CsvPath .\users.csv
    .\Import-AdUsers.ps1 -Domain corp.example.com -Cleanup

Лицензия: GPL-3.0.
#>
param(
    [Parameter(Mandatory)][string]$Domain,
    [string]$CsvPath,
    [string]$OuName = 'LabGenerated',
    [string]$MarkerGroup = 'lab_generated',
    [switch]$Cleanup,
    [switch]$DryRun,
    [switch]$Force,
    [pscredential]$Credential
)

Import-Module ActiveDirectory -ErrorAction Stop

$ad = @{ Server = $Domain }
if ($Credential) { $ad.Credential = $Credential }

try {
    $d = Get-ADDomain @ad -ErrorAction Stop
} catch {
    Write-Host "Не удалось подключиться к домену ${Domain}: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$ouDN = "OU=$OuName,$($d.DistinguishedName)"
Write-Host "Домен: $($d.DNSRoot) ($($d.DistinguishedName)); подразделение: $ouDN" -ForegroundColor Cyan

function Test-OuExists {
    return [bool](Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDN'" @ad)
}

# ---------------- Очистка ----------------
if ($Cleanup) {
    if (-not (Test-OuExists)) { Write-Host "Подразделение $ouDN не найдено: удалять нечего" -ForegroundColor Yellow; exit 0 }
    $users  = @(Get-ADUser  -SearchBase $ouDN -SearchScope Subtree -Filter * @ad)
    $groups = @(Get-ADGroup -SearchBase $ouDN -SearchScope Subtree -Filter * @ad)
    Write-Host "Будет удалено: пользователей $($users.Count), групп $($groups.Count), подразделение $OuName" -ForegroundColor Yellow
    if ($DryRun) { Write-Host "[dry-run] ничего не удалено"; exit 0 }
    if (-not $Force) {
        $answer = Read-Host "Удалить без возможности восстановления? Введи yes"
        if ($answer -ne 'yes') { Write-Host "Отменено"; exit 0 }
    }
    foreach ($u in $users)  { try { Remove-ADUser  -Identity $u.DistinguishedName -Confirm:$false @ad -ErrorAction Stop } catch { Write-Host "Ошибка при удалении $($u.SamAccountName): $_" -ForegroundColor Red } }
    foreach ($g in $groups) { try { Remove-ADGroup -Identity $g.DistinguishedName -Confirm:$false @ad -ErrorAction Stop } catch { Write-Host "Ошибка при удалении группы $($g.Name): $_" -ForegroundColor Red } }
    try {
        Set-ADOrganizationalUnit -Identity $ouDN -ProtectedFromAccidentalDeletion $false @ad -ErrorAction Stop
        Remove-ADOrganizationalUnit -Identity $ouDN -Confirm:$false @ad -ErrorAction Stop
    } catch { Write-Host "Не удалось удалить подразделение: $_" -ForegroundColor Red }
    Write-Host "Очистка завершена" -ForegroundColor Green
    exit 0
}

# ---------------- Импорт ----------------
if (-not $CsvPath -or -not (Test-Path $CsvPath)) { Write-Host "Укажи существующий файл: -CsvPath .\users.csv" -ForegroundColor Red; exit 1 }
$rows = @(Import-Csv -Path $CsvPath -Encoding UTF8)
$need = 'login','first_name','last_name','display_name','department','dept_group','password'
foreach ($col in $need) {
    if (-not ($rows.Count -gt 0 -and $rows[0].PSObject.Properties.Name -contains $col)) {
        Write-Host "В CSV нет столбца '$col' или файл пуст" -ForegroundColor Red; exit 1
    }
}
$deptGroups = $rows | Select-Object dept_group, department -Unique

if ($DryRun) {
    Write-Host "[dry-run] подразделение: $ouDN"
    Write-Host "[dry-run] группа-метка: $MarkerGroup; групп отделов: $($deptGroups.Count)"
    Write-Host "[dry-run] пользователей: $($rows.Count)"
    $rows | Select-Object -First 5 | ForEach-Object { Write-Host "[dry-run]   $($_.login)  $($_.display_name)  ($($_.department))" }
    exit 0
}

if (-not (Test-OuExists)) {
    New-ADOrganizationalUnit -Name $OuName -Path $d.DistinguishedName -ProtectedFromAccidentalDeletion $false @ad
    Write-Host "Создано подразделение $OuName" -ForegroundColor Green
}
function Ensure-Group($name, $description) {
    if (-not (Get-ADGroup -Filter "SamAccountName -eq '$name'" @ad)) {
        New-ADGroup -Name $name -SamAccountName $name -GroupScope Global -GroupCategory Security `
            -Description $description -Path $ouDN @ad
        Write-Host "Создана группа $name" -ForegroundColor Green
    }
}
Ensure-Group $MarkerGroup 'Тестовые учётные записи (создано Import-AdUsers.ps1)'
foreach ($g in $deptGroups) { Ensure-Group $g.dept_group $g.department }

$created = 0; $skipped = 0; $failed = 0
foreach ($r in $rows) {
    if (Get-ADUser -Filter "SamAccountName -eq '$($r.login)'" @ad) { $skipped++; continue }
    try {
        $securePwd = ConvertTo-SecureString $r.password -AsPlainText -Force
        New-ADUser -Name $r.display_name -DisplayName $r.display_name `
            -GivenName $r.first_name -Surname $r.last_name `
            -SamAccountName $r.login -UserPrincipalName "$($r.login)@$($d.DNSRoot)" `
            -EmailAddress "$($r.login)@$($d.DNSRoot)" -Department $r.department `
            -Path $ouDN -AccountPassword $securePwd -ChangePasswordAtLogon $true -Enabled $true @ad -ErrorAction Stop
        Add-ADGroupMember -Identity $MarkerGroup -Members $r.login @ad
        Add-ADGroupMember -Identity $r.dept_group -Members $r.login @ad
        $created++
    } catch {
        $failed++
        Write-Host "Ошибка $($r.login): $_" -ForegroundColor Red
    }
}
Write-Host "Готово: создано $created, уже существовало $skipped, ошибок $failed" -ForegroundColor Cyan
