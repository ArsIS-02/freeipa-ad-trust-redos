# Глава 2. Установка поддержки доверия

## 2.1. Пакет

```bash
sudo dnf install -y ipa-server-trust-ad
```

В РЕД ОС пакеты FreeIPA называются `ipa-server`, `ipa-server-trust-ad`, а не `freeipa-server`. Проверка:

```bash
rpm -qa | grep -iE "^ipa-|samba|gssproxy" | sort
```

## 2.2. `ipa-adtrust-install`

```bash
kinit admin
sudo ipa-adtrust-install --add-sids
```

Утилита задаёт вопросы:

- перезаписать `smb.conf` — отвечай «да»;
- про `slapi-nis` (совместимость со старыми клиентами) — по умолчанию «нет», если не нужен.

`--add-sids` присваивает SID всем существующим пользователям и группам IPA. Без этого доверие не заработает
для уже созданных учётных записей.

После установки перезапусти службы и проверь:

```bash
sudo ipactl restart
ipa trustconfig-show
```

Ожидаемо: имя домена, NetBIOS-имя и SID домена IPA.

## Что дальше

Перед созданием доверия проверь версию Samba: [глава 3](03-samba-redos.md).
