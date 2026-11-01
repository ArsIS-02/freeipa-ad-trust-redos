# Глава 6. Диагностика ошибок

Все ошибки ниже встретились при настройке реальной лаборатории (FreeIPA 4.12.2, РЕД ОС 8, Windows Server 2025).

| Симптом | Причина | Что делать |
|---|---|---|
| `ipa trust-add`: CIFS, код `3221225485` (`0xC000000D`), «An invalid parameter was passed…» | Heimdal-сборка Samba (`…h.red80`) поверх FreeIPA на MIT, плюс баг Samba 4.23 с `kinit` и gssproxy | [Глава 3](03-samba-redos.md): откат на MIT-сборку `…m.red80`, `versionlock` |
| `ipa trust-add`: CIFS, код `3221225581` (`0xC000006D`), «The attempted logon is invalid…» | Неверный логин или пароль администратора AD, либо учётная запись заблокирована | Проверь пароль через `kinit Administrator@AD.EXAMPLE.TEST`, на DC: `Get-ADUser <имя> -Properties LockedOut,BadLogonCount`, при блокировке `Unlock-ADAccount` |
| `ipa dnsforwardzone-add`: для одного имени зоны допустим только один тип зоны | Есть пустая обычная зона с тем же именем | `ipa dnszone-find`, при необходимости `ipa dnszone-del` для пустой зоны |
| `dig` в зону AD даёт `SERVFAIL` | DNSSEC-валидация в `named` | [Глава 1.2](01-prepare.md): `dnssec-validation no;`, перезапуск `named` |
| DC резолвит имя сервера IPA в два адреса | Кэш DNS на DC | `Clear-DnsServerCache -Force` |
| `smbclient`: `Failed to open registry /var/lib/samba/registry.tdb` | Запуск без `sudo` | Это не ошибка доверия. Для диагностики используй `sudo smbclient …` |
| `smbclient -U Administrator`: `NT_STATUS_LOGON_FAILURE` | В русской Windows встроенная учётная запись называется «Администратор» | Используй реальное имя учётной записи |
| `id user@ad` не находит пользователя | Кэш SSSD или не готово доверие | Подожди минуту, `sudo sss_cache -E`, проверь `ipa trust-show` |
| Создание доверия упирается в остаток старого | После `ipa trust-del` не удалено доверие на DC | «Домены и доверие» → «Удалить» или проверь `Get-ADTrust -Filter *` |

## Что собирать при обращении за помощью

```bash
rpm -qa | grep -iE "^ipa-|samba|gssproxy|libwbclient" | sort
sudo tail -60 /var/log/httpd/error_log | grep -iE "trust|cifs|samba|NT_STATUS"
sudo tail -40 /var/log/samba/log.winbindd
sudo journalctl -u gssproxy --since "10 min ago" --no-pager | tail -40
ipa trustconfig-show
```

Не публикуй пароли и реальные имена доменов: замени их на вымышленные.
