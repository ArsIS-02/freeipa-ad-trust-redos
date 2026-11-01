<#
.SYNOPSIS
    Интерактивное управление доменом Active Directory (Windows).

.DESCRIPTION
    Меню: сведения о домене и доверии, пользователи, группы, наполнение домена случайными данными,
    очистка созданного. Парный скрипт для FreeIPA: ipa_manager.py (Linux).

    Запускай на контроллере домена или на машине с модулем ActiveDirectory (RSAT).
    Имя домена задаётся параметром или вводится при запуске; его можно сменить из меню.

.EXAMPLE
    .\Manage-AdDomain.ps1
    .\Manage-AdDomain.ps1 -Domain corp.example.com

Лицензия: GPL-3.0.
#>
param(
    [string]$Domain
)

$OuName      = 'LabGenerated'    # подразделение, в котором лежит всё созданное наполнением
$MarkerGroup = 'lab_generated'   # группа-метка (то же имя, что в FreeIPA)

# ---------- Вывод ----------
function Write-Ok($t)    { Write-Host $t -ForegroundColor Green }
function Write-Err($t)   { Write-Host $t -ForegroundColor Red }
function Write-Warn($t)  { Write-Host $t -ForegroundColor Yellow }
function Write-Info($t)  { Write-Host $t -ForegroundColor Cyan }
function Write-Title($t) { Write-Host "`n=== $t ===" -ForegroundColor Magenta }

# ---------- Состояние ----------
$script:DomainFQDN = $null
$script:DomainDN   = $null
$script:NetBIOS    = $null
$script:ADParams   = @{}

function Select-Domain {
    param([string]$Name)
    $fqdnPattern = '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9-]{2,}$'
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            $Name = Read-Host "Имя домена (FQDN, например corp.example.com; пусто: выход)"
            if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
        }
        $Name = $Name.Trim().ToLower()
        if ($Name -notmatch $fqdnPattern) {
            Write-Err "'$Name' не похоже на имя домена. Нужно полное DNS-имя, например corp.example.com"
            $Name = $null; continue
        }
        $params = @{ Server = $Name }
        $same = Read-Host "Использовать текущую учётную запись Windows для $Name ? (Y/n)"
        if ($same -match '^(n|no|н|нет)$') {
            $cred = Get-Credential -Message "Администратор домена $Name"
            if (-not $cred) { Write-Warn "Учётные данные не введены"; $Name = $null; continue }
            $params.Credential = $cred
        }
        try { $d = Get-ADDomain @params -ErrorAction Stop }
        catch { Write-Err "Не удалось подключиться к домену ${Name}: $($_.Exception.Message)"; $Name = $null; continue }
        $script:ADParams   = $params
        $script:DomainFQDN = $d.DNSRoot
        $script:DomainDN   = $d.DistinguishedName
        $script:NetBIOS    = $d.NetBIOSName
        Write-Ok "Подключено к домену $($script:DomainFQDN) ($($script:DomainDN)), контроллер $($d.PDCEmulator)"
        return $true
    }
}

# ---------- Общие функции ----------
function Test-UserExists  { param($n) $p = $script:ADParams; try { Get-ADUser  -Identity $n @p -ErrorAction Stop | Out-Null; $true } catch { $false } }
function Test-GroupExists { param($n) $p = $script:ADParams; try { Get-ADGroup -Identity $n @p -ErrorAction Stop | Out-Null; $true } catch { $false } }

function Select-Location {
    param([string]$Prompt = "Выбери подразделение (номер)")
    $p = $script:ADParams
    $locs = @([pscustomobject]@{ Name = "Users (контейнер по умолчанию)"; DistinguishedName = "CN=Users,$($script:DomainDN)" })
    $locs += @(Get-ADOrganizationalUnit -Filter * -SearchBase $script:DomainDN @p | Select-Object Name, DistinguishedName)
    for ($i = 0; $i -lt $locs.Count; $i++) { Write-Host "$($i+1). $($locs[$i].Name)   [$($locs[$i].DistinguishedName)]" }
    $c = Read-Host $Prompt
    if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $locs.Count) { return $locs[[int]$c - 1].DistinguishedName }
    return $null
}

function Read-NewPassword {
    while ($true) {
        $p1 = Read-Host "Пароль" -AsSecureString
        if ($p1.Length -eq 0) { Write-Err "Пароль не может быть пустым"; continue }
        $p2 = Read-Host "Повтори пароль" -AsSecureString
        $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1)
        $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2)
        try { $same = ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1) -ceq [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1); [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2) }
        if ($same) { return $p1 }
        Write-Err "Пароли не совпадают, попробуй ещё раз"
    }
}

# ---------- Сведения ----------
function Show-DomainInfo {
    $p = $script:ADParams
    Write-Title "Сведения о домене $($script:DomainFQDN)"
    $d = Get-ADDomain @p
    $f = Get-ADForest @p
    Write-Host "Домен:               $($d.DNSRoot) ($($d.NetBIOSName))"
    Write-Host "Лес:                 $($f.Name)"
    Write-Host "SID домена:          $($d.DomainSID)"
    Write-Host "Уровень домена:      $($d.DomainMode)"
    Write-Host "Уровень леса:        $($f.ForestMode)"
    Write-Host "Мастер PDC:          $($d.PDCEmulator)"
    Write-Host ""
    Write-Host "Пользователей:       $(@(Get-ADUser -Filter * -SearchBase $script:DomainDN @p).Count)"
    Write-Host "Групп:               $(@(Get-ADGroup -Filter * -SearchBase $script:DomainDN @p).Count)"
    Write-Host "Подразделений:       $(@(Get-ADOrganizationalUnit -Filter * -SearchBase $script:DomainDN @p).Count)"
    Write-Host "Компьютеров:         $(@(Get-ADComputer -Filter * -SearchBase $script:DomainDN @p).Count)"
    $ouDN = "OU=$OuName,$($script:DomainDN)"
    $labUsers = 0
    try { $labUsers = @(Get-ADUser -Filter * -SearchBase $ouDN @p -ErrorAction Stop).Count } catch { }
    Write-Host "Тестовых (в $OuName):  $labUsers"
    Write-Host ""
    Write-Info "Контроллеры домена:"
    Get-ADDomainController -Filter * @p | Format-Table Name, IPv4Address, Site, OperatingSystem -AutoSize
    $pol = Get-ADDefaultDomainPasswordPolicy @p
    Write-Info "Политика паролей по умолчанию:"
    Write-Host "  Минимальная длина:      $($pol.MinPasswordLength)"
    Write-Host "  Сложность:              $($pol.ComplexityEnabled)"
    Write-Host "  Максимальный срок:      $($pol.MaxPasswordAge.Days) дн."
    Write-Host "  Порог блокировки:       $($pol.LockoutThreshold)"
    Show-Trusts -NoHeader
    Write-Host ""
    Write-Info "Последние 5 созданных пользователей:"
    Get-ADUser -Filter * -SearchBase $script:DomainDN -Properties whenCreated @p |
        Sort-Object whenCreated -Descending | Select-Object -First 5 | Format-Table Name, SamAccountName, whenCreated -AutoSize
}

function Show-Trusts {
    param([switch]$NoHeader)
    $p = $script:ADParams
    if (-not $NoHeader) { Write-Title "Доверительные отношения" }
    $t = @(Get-ADTrust -Filter * @p)
    if ($t.Count -eq 0) { Write-Host "Доверий нет"; return }
    Write-Info "Доверия с другими доменами:"
    $t | Format-Table Name, Direction, TrustType, ForestTransitive, SIDFilteringQuarantined, SIDFilteringForestAware -AutoSize
}

# ---------- Пользователи ----------
function Show-Users {
    $p = $script:ADParams
    Write-Title "Пользователи"
    $q = Read-Host "Строка для поиска (пусто: все)"
    if ([string]::IsNullOrWhiteSpace($q)) { $users = @(Get-ADUser -Filter * -Properties DisplayName, Mail -SearchBase $script:DomainDN @p) }
    else {
        $safe = $q.Replace("'", "''")
        $users = @(Get-ADUser -Filter "Name -like '*$safe*' -or SamAccountName -like '*$safe*'" -Properties DisplayName, Mail -SearchBase $script:DomainDN @p)
    }
    if ($users.Count -eq 0) { Write-Host "Ничего не найдено"; return }
    $users | Sort-Object SamAccountName | Format-Table SamAccountName, Name, Mail, Enabled -AutoSize
    Write-Host "Всего: $($users.Count)"
}

function Show-UserCard {
    $p = $script:ADParams
    Write-Title "Карточка пользователя"
    $n = Read-Host "Логин"
    if (-not $n) { return }
    if (-not (Test-UserExists $n)) { Write-Err "Пользователь $n не найден"; return }
    $u = Get-ADUser -Identity $n -Properties * @p
    Write-Host "Логин:               $($u.SamAccountName)"
    Write-Host "Имя:                 $($u.GivenName) $($u.Surname)"
    Write-Host "Отображаемое имя:    $($u.DisplayName)"
    Write-Host "UPN:                 $($u.UserPrincipalName)"
    Write-Host "Почта:               $($u.EmailAddress)"
    Write-Host "Отдел:               $($u.Department)"
    Write-Host "Включён:             $($u.Enabled)"
    Write-Host "Заблокирован:        $($u.LockedOut)"
    Write-Host "Создан:              $($u.whenCreated)"
    Write-Host "Последний вход:      $($u.LastLogonDate)"
    Write-Host "Расположение:        $($u.DistinguishedName)"
    $groups = @($u.MemberOf | ForEach-Object { ($_ -split ',')[0] -replace '^CN=' })
    Write-Host "Группы:              $(if ($groups.Count) { $groups -join ', ' } else { '-' })"
}

function Add-User {
    $p = $script:ADParams
    Write-Title "Создание пользователя"
    $login = Read-Host "Логин (до 20 символов)"
    if ([string]::IsNullOrWhiteSpace($login)) { return }
    if ($login.Length -gt 20) { Write-Err "sAMAccountName не длиннее 20 символов"; return }
    if (Test-UserExists $login) { Write-Err "Пользователь $login уже существует"; return }
    $first = Read-Host "Имя"; $last = Read-Host "Фамилия"
    if (-not $first -or -not $last) { Write-Err "Имя и фамилия обязательны"; return }
    $display = Read-Host "Отображаемое имя (Enter: $first $last)"
    if ([string]::IsNullOrWhiteSpace($display)) { $display = "$first $last" }
    $ou = Select-Location "Выбери подразделение (номер)"
    if (-not $ou) { Write-Warn "Неверный выбор, использую CN=Users"; $ou = "CN=Users,$($script:DomainDN)" }
    $pw = Read-NewPassword
    $ch = Read-Host "Требовать смену пароля при первом входе? (Y/n)"
    $change = -not ($ch -match '^(n|no|н|нет)$')
    try {
        New-ADUser -Name $display -DisplayName $display -GivenName $first -Surname $last `
            -SamAccountName $login -UserPrincipalName "$login@$($script:DomainFQDN)" `
            -EmailAddress "$login@$($script:DomainFQDN)" -Path $ou -AccountPassword $pw `
            -ChangePasswordAtLogon $change -Enabled $true @p -ErrorAction Stop
        Write-Ok "Пользователь $login создан в $ou"
        if ((Read-Host "Добавить в группы? (y/n)") -eq 'y') {
            foreach ($g in ((Read-Host "Группы через запятую") -split ',')) { if ($g.Trim()) { Add-UserToGroup -User $login -Group $g.Trim() -Quiet } }
        }
    } catch { Write-Err "Ошибка: $_" }
}

function Remove-User {
    $p = $script:ADParams
    Write-Title "Удаление пользователя"
    $n = Read-Host "Логин"
    if (-not $n) { return }
    if (-not (Test-UserExists $n)) { Write-Err "Пользователь $n не найден"; return }
    if ((Read-Host "Удалить $n из $($script:DomainFQDN) без возможности восстановления? (y/n)") -eq 'y') {
        try { Remove-ADUser -Identity $n -Confirm:$false @p -ErrorAction Stop; Write-Ok "Пользователь $n удалён" }
        catch { Write-Err "Ошибка: $_" }
    } else { Write-Warn "Отменено" }
}

function Switch-UserEnabled {
    $p = $script:ADParams
    Write-Title "Включить или отключить пользователя"
    $n = Read-Host "Логин"
    if (-not $n -or -not (Test-UserExists $n)) { Write-Err "Пользователь не найден"; return }
    $u = Get-ADUser -Identity $n @p
    $act = if ($u.Enabled) { "отключить" } else { "включить" }
    if ((Read-Host "$act $n? (y/n)") -eq 'y') {
        try {
            if ($u.Enabled) { Disable-ADAccount -Identity $n @p -ErrorAction Stop } else { Enable-ADAccount -Identity $n @p -ErrorAction Stop }
            Write-Ok "Готово"
        } catch { Write-Err "Ошибка: $_" }
    }
}

function Reset-UserPassword {
    $p = $script:ADParams
    Write-Title "Сброс пароля"
    $n = Read-Host "Логин"
    if (-not $n -or -not (Test-UserExists $n)) { Write-Err "Пользователь не найден"; return }
    $pw = Read-NewPassword
    try {
        Set-ADAccountPassword -Identity $n -Reset -NewPassword $pw @p -ErrorAction Stop
        Set-ADUser -Identity $n -ChangePasswordAtLogon $true @p
        Write-Ok "Пароль задан (при первом входе потребуется смена)"
    } catch { Write-Err "Ошибка: $_" }
}

# ---------- Группы ----------
function Show-Groups {
    $p = $script:ADParams
    Write-Title "Группы"
    $g = @(Get-ADGroup -Filter * -SearchBase $script:DomainDN -Properties Description, Members @p)
    $g | Sort-Object Name | Select-Object Name, GroupCategory, GroupScope, @{ n = 'Польз.'; e = { @($_.Members).Count } }, Description | Format-Table -AutoSize
    Write-Host "Всего: $($g.Count)"
}

function Add-Group {
    $p = $script:ADParams
    Write-Title "Создание группы"
    $name = Read-Host "Имя группы"
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    if (Test-GroupExists $name) { Write-Err "Группа $name уже существует"; return }
    $ou = Select-Location "Выбери подразделение (номер)"
    if (-not $ou) { Write-Warn "Неверный выбор, использую CN=Users"; $ou = "CN=Users,$($script:DomainDN)" }
    $cat = if ((Read-Host "Категория: Security или Distribution [S/D, по умолчанию S]") -match '^(d|D)') { 'Distribution' } else { 'Security' }
    $sc = Read-Host "Область: Global, Universal или DomainLocal [G/U/D, по умолчанию G]"
    $scope = switch -Regex ($sc) { '^(u|U)' { 'Universal' } '^(d|D)' { 'DomainLocal' } default { 'Global' } }
    $desc = Read-Host "Описание (необязательно)"
    try {
        New-ADGroup -Name $name -SamAccountName $name -Path $ou -GroupCategory $cat -GroupScope $scope -Description $desc @p -ErrorAction Stop
        Write-Ok "Группа $name ($cat, $scope) создана в $ou"
    } catch { Write-Err "Ошибка: $_" }
}

function Remove-Group {
    $p = $script:ADParams
    Write-Title "Удаление группы"
    $name = Read-Host "Имя группы"
    if (-not $name -or -not (Test-GroupExists $name)) { Write-Err "Группа не найдена"; return }
    $g = Get-ADGroup -Identity $name @p
    if ($g.DistinguishedName -like '*CN=Builtin,*' -or ($g.SID.Value -match '-(\d+)$' -and [int]$Matches[1] -lt 1000)) {
        Write-Err "Группа $name встроенная, её нельзя удалять здесь"; return
    }
    if ((Read-Host "Удалить группу $name? (y/n)") -eq 'y') {
        try { Remove-ADGroup -Identity $name -Confirm:$false @p -ErrorAction Stop; Write-Ok "Группа $name удалена" }
        catch { Write-Err "Ошибка: $_" }
    } else { Write-Warn "Отменено" }
}

function Show-GroupMembers {
    $p = $script:ADParams
    Write-Title "Участники группы"
    $name = Read-Host "Имя группы"
    if (-not $name -or -not (Test-GroupExists $name)) { Write-Err "Группа не найдена"; return }
    $m = @(Get-ADGroupMember -Identity $name @p)
    if ($m.Count -eq 0) { Write-Warn "Группа пуста" } else { $m | Format-Table Name, SamAccountName, objectClass -AutoSize }
}

function Add-UserToGroup {
    param($User, $Group, [switch]$Quiet)
    $p = $script:ADParams
    if (-not $Quiet) { Write-Title "Добавить пользователя в группу" }
    if (-not $User)  { $User  = Read-Host "Логин" }
    if (-not $Group) { $Group = Read-Host "Группа" }
    if (-not (Test-UserExists $User))   { Write-Err "Пользователь $User не найден"; return }
    if (-not (Test-GroupExists $Group)) { Write-Err "Группа $Group не найдена"; return }
    try { Add-ADGroupMember -Identity $Group -Members $User @p -ErrorAction Stop; Write-Ok "$User добавлен в $Group" }
    catch { Write-Err "Ошибка: $_" }
}

function Remove-UserFromGroup {
    $p = $script:ADParams
    Write-Title "Убрать пользователя из группы"
    $u = Read-Host "Логин"; $g = Read-Host "Группа"
    if (-not (Test-UserExists $u))  { Write-Err "Пользователь $u не найден"; return }
    if (-not (Test-GroupExists $g)) { Write-Err "Группа $g не найдена"; return }
    try { Remove-ADGroupMember -Identity $g -Members $u -Confirm:$false @p -ErrorAction Stop; Write-Ok "$u убран из $g" }
    catch { Write-Err "Ошибка: $_" }
}

# ---------- Генератор случайных людей (те же списки, что в gen_users.py) ----------
$MaleFirst   = 'Иван','Пётр','Алексей','Дмитрий','Сергей','Андрей','Михаил','Николай','Владимир','Евгений','Артём','Максим','Олег','Роман','Кирилл','Антон','Игорь','Константин','Виктор','Павел','Георгий','Тимофей','Степан','Денис'
$FemaleFirst = 'Анна','Мария','Елена','Ольга','Наталья','Татьяна','Ирина','Светлана','Екатерина','Юлия','Анастасия','Дарья','Полина','Виктория','Алёна','Марина','Вера','Надежда','Людмила','Галина','Ксения','Валентина','Алина','Диана'
$MaleLast    = 'Иванов','Петров','Сидоров','Смирнов','Кузнецов','Попов','Васильев','Соколов','Михайлов','Новиков','Фёдоров','Морозов','Волков','Алексеев','Лебедев','Семёнов','Егоров','Павлов','Козлов','Степанов','Николаев','Орлов','Андреев','Макаров','Никитин','Захаров','Зайцев','Соловьёв','Борисов','Яковлев','Григорьев','Романов','Воробьёв','Сергеев','Кузьмин','Ковальский','Белецкий','Лесной'
$EnFirst     = 'John','James','Robert','Michael','William','David','Richard','Joseph','Thomas','Charles','Mary','Patricia','Jennifer','Linda','Elizabeth','Barbara','Susan','Jessica','Sarah','Karen','Daniel','Matthew','Emma','Olivia'
$EnLast      = 'Smith','Johnson','Williams','Brown','Jones','Miller','Davis','Wilson','Anderson','Taylor','Thomas','Moore','Martin','Jackson','Thompson','White','Harris','Clark','Lewis','Walker','Hall','Allen','Young','King','Wright','Scott','Green','Baker','Adams','Nelson'
$Departments = @(
    @{ Name = 'Бухгалтерия'; Slug = 'buh' }, @{ Name = 'Отдел продаж'; Slug = 'sales' }, @{ Name = 'ИТ-отдел'; Slug = 'it' },
    @{ Name = 'Кадры'; Slug = 'hr' }, @{ Name = 'Юридический отдел'; Slug = 'legal' }, @{ Name = 'Логистика'; Slug = 'logistics' },
    @{ Name = 'Маркетинг'; Slug = 'marketing' }, @{ Name = 'Служба поддержки'; Slug = 'support' }
)
$Translit = @{ 'а'='a';'б'='b';'в'='v';'г'='g';'д'='d';'е'='e';'ё'='e';'ж'='zh';'з'='z';'и'='i';'й'='y';'к'='k';'л'='l';'м'='m';'н'='n';'о'='o';'п'='p';'р'='r';'с'='s';'т'='t';'у'='u';'ф'='f';'х'='kh';'ц'='ts';'ч'='ch';'ш'='sh';'щ'='shch';'ъ'='';'ы'='y';'ь'='';'э'='e';'ю'='yu';'я'='ya' }

function ConvertTo-Latin([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToLower().ToCharArray()) {
        $k = [string]$ch
        if ($Translit.ContainsKey($k)) { [void]$sb.Append($Translit[$k]) } else { [void]$sb.Append($k) }
    }
    return $sb.ToString()
}

function ConvertTo-FemaleSurname([string]$s) {
    if ($s.EndsWith('ский')) { return $s.Substring(0, $s.Length - 4) + 'ская' }
    if ($s.EndsWith('цкий')) { return $s.Substring(0, $s.Length - 4) + 'цкая' }
    if ($s.EndsWith('ой'))   { return $s.Substring(0, $s.Length - 2) + 'ая' }
    foreach ($e in 'ов','ев','ёв','ин','ын') { if ($s.EndsWith($e)) { return $s + 'а' } }
    return $s
}

function Get-RandomIndex([int]$max) {
    $b = New-Object byte[] 4
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($b); $rng.Dispose()
    return [int]([uint32][BitConverter]::ToUInt32($b, 0) % [uint32]$max)
}
function Get-Pick($list) { return $list[(Get-RandomIndex $list.Count)] }

function New-RandomPassword {
    $pools = @('abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', '0123456789', '!@#%^*-_=+')
    $chars = New-Object System.Collections.ArrayList
    foreach ($pool in $pools) { [void]$chars.Add($pool[(Get-RandomIndex $pool.Length)]) }
    $all = $pools -join ''
    while ($chars.Count -lt 14) { [void]$chars.Add($all[(Get-RandomIndex $all.Length)]) }
    $arr = $chars.ToArray()
    for ($i = $arr.Length - 1; $i -gt 0; $i--) { $j = Get-RandomIndex ($i + 1); $t = $arr[$i]; $arr[$i] = $arr[$j]; $arr[$j] = $t }
    return -join $arr
}

function New-RandomPeople {
    param([int]$Count, [string]$Lang)
    $people = New-Object System.Collections.ArrayList
    $usedLogins = @{}; $usedNames = @{}; $attempts = 0
    while ($people.Count -lt $Count) {
        $attempts++
        if ($attempts -gt $Count * 50) { throw "Не удалось подобрать столько уникальных имён: уменьши количество или смени язык" }
        $ru = ($Lang -eq 'ru') -or ($Lang -eq 'mix' -and (Get-RandomIndex 2) -eq 0)
        if ($ru) {
            $female = (Get-RandomIndex 2) -eq 0
            $first = if ($female) { Get-Pick $FemaleFirst } else { Get-Pick $MaleFirst }
            $last = Get-Pick $MaleLast
            if ($female) { $last = ConvertTo-FemaleSurname $last }
            $fl = ConvertTo-Latin $first; $ll = ConvertTo-Latin $last
        } else {
            $first = Get-Pick $EnFirst; $last = Get-Pick $EnLast
            $fl = $first.ToLower(); $ll = $last.ToLower()
        }
        $display = "$first $last"
        if ($usedNames.ContainsKey($display)) { continue }
        $usedNames[$display] = $true
        $base = "$fl.$ll"; if ($base.Length -gt 18) { $base = $base.Substring(0, 18) }
        $login = $base; $n = 1
        while ($usedLogins.ContainsKey($login)) { $n++; $login = "$base$n" }
        $usedLogins[$login] = $true
        $dept = Get-Pick $Departments
        [void]$people.Add([pscustomobject]@{
            login = $login; first_name = $first; last_name = $last; display_name = $display
            department = $dept.Name; dept_group = "dept_$($dept.Slug)"; password = (New-RandomPassword)
        })
    }
    return $people
}

# ---------- Наполнение, импорт из CSV, очистка ----------
function Import-People {
    param($People)
    $p = $script:ADParams
    $ouDN = "OU=$OuName,$($script:DomainDN)"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDN'" @p)) {
        New-ADOrganizationalUnit -Name $OuName -Path $script:DomainDN -ProtectedFromAccidentalDeletion $false @p
        Write-Ok "Создано подразделение $OuName"
    }
    $ensure = {
        param($name, $desc)
        if (-not (Get-ADGroup -Filter "SamAccountName -eq '$name'" @p)) {
            New-ADGroup -Name $name -SamAccountName $name -GroupScope Global -GroupCategory Security -Description $desc -Path $ouDN @p
            Write-Ok "Создана группа $name"
        }
    }
    & $ensure $MarkerGroup 'Тестовые учётные записи (создано скриптами из репозитория)'
    foreach ($g in ($People | Select-Object dept_group, department -Unique)) { & $ensure $g.dept_group $g.department }

    $created = 0; $skipped = 0; $failed = 0
    foreach ($r in $People) {
        if (Get-ADUser -Filter "SamAccountName -eq '$($r.login)'" @p) { $skipped++; continue }
        try {
            $sec = ConvertTo-SecureString $r.password -AsPlainText -Force
            New-ADUser -Name $r.display_name -DisplayName $r.display_name -GivenName $r.first_name -Surname $r.last_name `
                -SamAccountName $r.login -UserPrincipalName "$($r.login)@$($script:DomainFQDN)" `
                -EmailAddress "$($r.login)@$($script:DomainFQDN)" -Department $r.department `
                -Path $ouDN -AccountPassword $sec -ChangePasswordAtLogon $true -Enabled $true @p -ErrorAction Stop
            Add-ADGroupMember -Identity $MarkerGroup -Members $r.login @p
            Add-ADGroupMember -Identity $r.dept_group -Members $r.login @p
            $created++
        } catch { $failed++; Write-Err "Ошибка $($r.login): $_" }
    }
    Write-Info "Готово: создано $created, уже существовало $skipped, ошибок $failed"
}

function Invoke-Populate {
    Write-Title "Наполнение домена случайными данными"
    Write-Host "Всё попадёт в подразделение $OuName и группу $MarkerGroup. Очистка (пункт 16) удаляет только это."
    $cnt = 0
    if (-not [int]::TryParse((Read-Host "Сколько пользователей создать (Enter: 20)"), [ref]$cnt) -or $cnt -eq 0) { $cnt = 20 }
    if ($cnt -lt 1 -or $cnt -gt 1000) { Write-Err "Допустимо от 1 до 1000"; return }
    $lang = Read-Host "Имена: ru, en или mix (Enter: mix)"
    if ([string]::IsNullOrWhiteSpace($lang)) { $lang = 'mix' }
    if ($lang -notin 'ru','en','mix') { Write-Err "Допустимо ru, en или mix"; return }
    try { $people = New-RandomPeople -Count $cnt -Lang $lang } catch { Write-Err "$_"; return }
    Write-Info "`nПример того, что будет создано:"
    $people | Select-Object -First 8 | Format-Table login, display_name, department -AutoSize
    if ($cnt -gt 8) { Write-Host "... и ещё $($cnt - 8)" }
    if ((Read-Host "Создать $cnt пользователей в домене $($script:DomainFQDN)? (y/n)") -ne 'y') { Write-Warn "Отменено"; return }
    Import-People -People $people
    $path = Read-Host "`nСохранить CSV, чтобы загрузить тех же людей в FreeIPA? Путь к файлу (Enter: не сохранять)"
    if ($path) {
        $people | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
        Write-Warn "Сохранено в $path. Внутри пароли тестовых учётных записей: не коммить файл и удали после импорта."
    }
}

function Import-FromCsv {
    Write-Title "Загрузка пользователей из CSV"
    $path = Read-Host "Путь к CSV (от gen_users.py или ipa_manager.py)"
    if (-not $path -or -not (Test-Path $path)) { Write-Err "Файл не найден"; return }
    $rows = @(Import-Csv -Path $path -Encoding UTF8)
    foreach ($col in 'login','first_name','last_name','display_name','department','dept_group','password') {
        if (-not ($rows.Count -gt 0 -and $rows[0].PSObject.Properties.Name -contains $col)) { Write-Err "В CSV нет столбца '$col' или файл пуст"; return }
    }
    Write-Host "В файле $($rows.Count) пользователей"
    if ((Read-Host "Загрузить в домен $($script:DomainFQDN)? (y/n)") -eq 'y') { Import-People -People $rows }
}

function Invoke-Cleanup {
    $p = $script:ADParams
    Write-Title "Очистка созданного наполнением"
    $ouDN = "OU=$OuName,$($script:DomainDN)"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDN'" @p)) { Write-Warn "Подразделение $OuName не найдено: удалять нечего"; return }
    $users  = @(Get-ADUser  -SearchBase $ouDN -SearchScope Subtree -Filter * @p)
    $groups = @(Get-ADGroup -SearchBase $ouDN -SearchScope Subtree -Filter * @p)
    Write-Warn "Будет удалено: пользователей $($users.Count), групп $($groups.Count), подразделение $OuName"
    if ((Read-Host "Удалить без возможности восстановления? Введи yes") -ne 'yes') { Write-Warn "Отменено"; return }
    foreach ($u in $users)  { try { Remove-ADUser  -Identity $u.DistinguishedName -Confirm:$false @p -ErrorAction Stop } catch { Write-Err "Ошибка при удалении $($u.SamAccountName): $_" } }
    foreach ($g in $groups) { try { Remove-ADGroup -Identity $g.DistinguishedName -Confirm:$false @p -ErrorAction Stop } catch { Write-Err "Ошибка при удалении группы $($g.Name): $_" } }
    try {
        Set-ADOrganizationalUnit -Identity $ouDN -ProtectedFromAccidentalDeletion $false @p -ErrorAction Stop
        Remove-ADOrganizationalUnit -Identity $ouDN -Confirm:$false @p -ErrorAction Stop
    } catch { Write-Err "Не удалось удалить подразделение: $_" }
    Write-Ok "Очистка завершена"
}

# ---------- Меню ----------
function Show-MainMenu {
    $menu = @(
        @{ T = 'Сведения о домене';                      A = { Show-DomainInfo } },
        @{ T = 'Доверительные отношения';                A = { Show-Trusts } },
        @{ T = 'Список и поиск пользователей';          A = { Show-Users } },
        @{ T = 'Карточка пользователя';                  A = { Show-UserCard } },
        @{ T = 'Создать пользователя';                   A = { Add-User } },
        @{ T = 'Удалить пользователя';                   A = { Remove-User } },
        @{ T = 'Отключить или включить пользователя';   A = { Switch-UserEnabled } },
        @{ T = 'Сбросить пароль';                        A = { Reset-UserPassword } },
        @{ T = 'Список групп';                           A = { Show-Groups } },
        @{ T = 'Создать группу';                         A = { Add-Group } },
        @{ T = 'Удалить группу';                         A = { Remove-Group } },
        @{ T = 'Участники группы';                       A = { Show-GroupMembers } },
        @{ T = 'Добавить пользователя в группу';        A = { Add-UserToGroup } },
        @{ T = 'Убрать пользователя из группы';         A = { Remove-UserFromGroup } },
        @{ T = 'Наполнить домен случайными данными';    A = { Invoke-Populate } },
        @{ T = 'Очистить созданное наполнением';        A = { Invoke-Cleanup } },
        @{ T = 'Загрузить пользователей из CSV';        A = { Import-FromCsv } },
        @{ T = 'Сменить домен';                          A = { if (-not (Select-Domain)) { Write-Warn "Домен не изменён" } } }
    )
    do {
        Clear-Host
        Write-Host "========== УПРАВЛЕНИЕ AD: $($script:DomainFQDN) ==========" -ForegroundColor Magenta
        for ($i = 0; $i -lt $menu.Count; $i++) { Write-Host ("{0,2}. {1}" -f ($i + 1), $menu[$i].T) }
        Write-Host " 0. Выход"
        $choice = Read-Host "`nВыбери действие"
        if ($choice -eq '0') { Write-Ok "До свидания!"; break }
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $menu.Count) {
            try { & $menu[[int]$choice - 1].A } catch { Write-Err "Ошибка: $_" }
        } else { Write-Err "Неверный выбор" }
        Read-Host "`nНажми Enter, чтобы продолжить" | Out-Null
    } while ($true)
}

# ---------- Запуск ----------
function Stop-Script([string]$Message) {
    if ($Message) { Write-Warn $Message }
    Read-Host "`nНажми Enter, чтобы закрыть окно" | Out-Null
}
try {
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Err "Модуль ActiveDirectory не найден."
        Write-Host "Запусти скрипт на контроллере домена или установи RSAT:"
        Write-Host "  Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0   (Windows 10/11)"
        Write-Host "  Install-WindowsFeature RSAT-AD-PowerShell                                        (Windows Server)"
        Stop-Script
    } else {
        Import-Module ActiveDirectory -ErrorAction Stop
        if (Select-Domain -Name $Domain) { Show-MainMenu } else { Stop-Script "Домен не выбран, выход." }
    }
} catch {
    Write-Err "Непредвиденная ошибка: $_"
    Stop-Script
}
