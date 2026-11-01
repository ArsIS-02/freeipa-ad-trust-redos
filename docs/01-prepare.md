# Глава 1. Подготовка: DNS, время, порты

Доверие держится на трёх вещах: каждый домен находит другой по имени, часы расходятся не больше чем на
5 минут, и нужные порты открыты. Если пропустить этот шаг, ошибки появятся уже на создании доверия и будут
выглядеть так, будто виновата Samba.

Обозначения: `ipa.example.test` — домен FreeIPA (сервер `192.0.2.10`), `ad.example.test` — домен AD
(контроллер `192.0.2.20`).

## 1.1. DNS на стороне FreeIPA

Серверу IPA нужно резолвить имена домена AD, в первую очередь записи `_ldap._tcp.dc._msdcs.ad.example.test`.
Для этого создаём зону-переадресацию (forward zone) на контроллер домена:

```bash
kinit admin
ipa dnsforwardzone-add ad.example.test --forwarder=192.0.2.20 --forward-policy=only
```

Если такая зона уже есть как обычная (master), команда выдаст ошибку: для одного имени зоны допустим только
один тип. Посмотри, что есть, и удали пустую зону:

```bash
ipa dnszone-find
ipa dnsforwardzone-find
ipa dnszone-del ad.example.test      # только если зона пустая и не нужна
```

Проверка:

```bash
dig +short SRV _ldap._tcp.dc._msdcs.ad.example.test @127.0.0.1
dig +short dc1.ad.example.test @127.0.0.1
```

Должны вернуться имя и адрес контроллера. Если пришёл `SERVFAIL`, переходи к 1.2.

### 1.2. DNSSEC-валидация

IPA включает проверку DNSSEC в `named`. Контроллер AD, как правило, подписи не отдаёт, и запросы в зону AD
заканчиваются `SERVFAIL`. Надёжный способ, который сработал в лаборатории, — отключить валидацию в
конфигурации `named`:

```bash
grep -n dnssec /etc/named/ipa-options-ext.conf
sudo sed -i 's/dnssec-validation yes;/dnssec-validation no;/' /etc/named/ipa-options-ext.conf
sudo systemctl restart named
```

Важно:

- В РЕД ОС служба называется `named` (юнит `named-pkcs11` замаскирован), перезапускай именно её.
- Валидация отключается для всего резолвера на сервере IPA. В домашней сети это приемлемо. В боевой
  инфраструктуре сначала подумай, не нужен ли другой подход (например, исключение для зоны).
- Не запускай `ipa-dns-install --no-dnssec-validation` как «правильный» путь: он повторно настраивает DNS и в
  лаборатории попытался прописать `127.0.0.1` как внешний пересыльщик, поэтому его пришлось прервать.

Повтори `dig` из 1.1.

## 1.3. DNS на стороне Windows

На контроллере домена нужен условный пересыльщик (conditional forwarder) на домен IPA. Выполни в PowerShell
от администратора:

```powershell
Add-DnsServerConditionalForwarderZone -Name "ipa.example.test" -MasterServers 192.0.2.10
Resolve-DnsName ipa1.ipa.example.test
Resolve-DnsName -Type SRV _ldap._tcp.ipa.example.test
```

Если DC резолвит имя сервера IPA в два адреса (один старый), это кэш DNS. Очисть его:

```powershell
Clear-DnsServerCache -Force
```

## 1.4. Время

Kerberos терпит расхождение не больше 5 минут. Сверь часы:

```bash
chronyc tracking        # на сервере IPA
```
```powershell
w32tm /stripchart /computer:ipa1.ipa.example.test /samples:3 /dataonly   # на DC
```

Если разница заметная, настрой единый источник времени (NTP).

## 1.5. Порты и firewalld

На сервере IPA открой сервис, который включает порты, нужные доверию (135, 138, 139, 389, 445, 1024–1300 и
другие):

```bash
sudo firewall-cmd --permanent --add-service=freeipa-trust
sudo firewall-cmd --reload
sudo firewall-cmd --list-services
```

Из IPA проверь доступность контроллера:

```bash
nc -zv 192.0.2.20 445
nc -zv 192.0.2.20 135
nc -zv 192.0.2.20 389
```

Если на DC работает VPN-клиент, который перехватывает трафик, на время настройки отключи его: он ломает
имена и маршруты.

## Что дальше

Установка поддержки доверия: [глава 2](02-adtrust-install.md).
