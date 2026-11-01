# Глава 3. Samba для РЕД ОС: MIT, а не Heimdal

## 3.1. Симптом

После `ipa-adtrust-install` команда

```bash
ipa trust-add --type=ad ad.example.test --admin Administrator --password
```

завершается так:

```
ipa: ERROR: Ошибка обмена данными с сервером CIFS: код "3221225485", сообщение
"An invalid parameter was passed to a service or function."
```

`3221225485` — это `0xC000000D`, `STATUS_INVALID_PARAMETER`. Особенность: ошибка возникает на локальном шаге
на самом сервере IPA, до обращения к контроллеру. Поэтому она не зависит от пароля, DNS и настроек Windows.
Вариант `--trust-secret` падает с тем же кодом.

В логах Samba (`/var/log/samba/log.winbindd`) при этом пусто, в `/var/log/httpd/error_log` только запись
`trust_add ... RemoteRetrieveError`.

## 3.2. Причина

В Samba 4.23 появилась логика: если передан пароль, а кэш Kerberos-билетов пуст, Samba сама делает `kinit`.
FreeIPA хранит кэш через gssproxy, где учётные данные доступны только через GSSAPI и выглядят «просроченными».
Samba считает кэш неинициализированным, и шаг GSSAPI падает с `STATUS_INVALID_PARAMETER`. Подробный разбор
для Fedora: [FreeIPA #9847](https://www.pagure.io/freeipa/issue/9847) и
[Red Hat Bugzilla 2392626](https://bugzilla.redhat.com/show_bug.cgi?id=2392626).

В РЕД ОС ситуация усугубляется тем, что одну и ту же версию Samba собирают в двух вариантах. Смотри журнал
изменений:

```bash
rpm -q samba
rpm -q --changelog samba | head -15
```

В записях видны пометки «Heimdal» и «MIT», а в номере релиза буквы `h` и `m`:

```
4.23.12-4h.red80   Heimdal
4.23.12-3m.red80   MIT
```

FreeIPA построена на MIT Kerberos, ей нужна MIT-сборка Samba. В лаборатории с `…h.red80` доверие не создавалось
с ошибкой `0xC000000D`, а после отката на `…m.red80` создалось с первой попытки. Это практический вывод, а не
подтверждение со стороны разработчиков РЕД ОС: если у тебя иначе, смотри [главу 6](06-troubleshooting.md).

## 3.3. Какие версии доступны

```bash
dnf list --showduplicates samba samba-libs samba-common samba-common-tools \
  samba-winbind samba-winbind-clients samba-winbind-modules libwbclient | grep -E "4\.23"
```

Нужна самая свежая с суффиксом `m`, в нашем случае `4.23.12-3m.red80`. Версия `h` выше по порядку сортировки,
поэтому `dnf upgrade` её не заменит, нужен откат.

## 3.4. Откат на MIT-сборку

Сделай копию конфигурации на всякий случай:

```bash
sudo cp -a /etc/samba /root/samba-etc.bak
sudo cp -a /var/lib/samba /root/samba-var.bak
```

Собери список установленных пакетов Samba с целевой версией и проверь:

```bash
PK=$(rpm -qa --qf '%{NAME}\n' | grep -E '^(samba|libwbclient|python3-samba|libsmbclient|libnetapi|ctdb)' \
     | sort -u | sed 's/$/-4.23.12-3m.red80/')
echo "$PK"
```

Откат (в лаборатории затронуто 19 пакетов, `ipa-server` и остальное не трогалось). Сначала ответь `N` на запрос и
посмотри список операций, затем повтори и ответь `y`:

```bash
sudo dnf downgrade $PK
```

Если `dnf` предлагает удалить `ipa-server` или `ipa-server-trust-ad`, не продолжай.

После отката перезапусти службы и проверь:

```bash
sudo ipactl restart
rpm -q samba python3-samba
```

## 3.5. Закрепи версию

Иначе обычное обновление вернёт Heimdal-сборку:

```bash
sudo dnf install -y python3-dnf-plugin-versionlock
sudo dnf versionlock add 'samba*' libwbclient libsmbclient libnetapi python3-samba python3-samba-dc
dnf versionlock list
```

Когда в репозитории появится согласованная пара с исправлением, блокировку можно снять командой
`sudo dnf versionlock delete 'samba*'` и подобными для остальных пакетов.

## Что дальше

Создание доверия: [глава 4](04-create-trust.md).
