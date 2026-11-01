# Глава 5. Группы AD и HBAC

Группы AD нельзя добавить в группы IPA напрямую. Для этого есть внешняя группа (external group), которая
хранит SID группы AD, и обычная IPA-группа, куда она вложена. Правила HBAC и sudo ссылаются на обычную
группу.

## 5.1. Внешняя группа и обычная группа

```bash
ipa group-add --external ad_admins_external
ipa group-add-member ad_admins_external --external 'AD\Domain Admins'
ipa group-add ad_admins
ipa group-add-member ad_admins --groups ad_admins_external
```

На запросах `[member user]`, `[member group]`, `[member service]` просто нажимай Enter. В русской Windows имя
группы локализовано: `'AD\Администраторы домена'`. Результат: внешний участник с SID, оканчивающимся на `-512`
(это «Domain Admins»), а группа `ad_admins` содержит `ad_admins_external`.

Проверка: `ipa group-show ad_admins_external`, а у пользователя AD в `id` теперь есть группа `ad_admins`.

## 5.2. HBAC

HBAC (host-based access control) решает, кто куда может войти. Посмотри текущие правила:

```bash
ipa hbacrule-find
```

В свежей установке включено правило `allow_all` (все пользователи, все хосты, все службы), поэтому пользователи
AD уже могут входить, и отдельное правило не нужно. Если `allow_all` отключён, создай своё:

```bash
ipa hbacrule-add allow_ad_admins
ipa hbacrule-add-user allow_ad_admins --groups ad_admins
ipa hbacrule-add-host allow_ad_admins --hostcat=all
ipa hbacrule-add-service allow_ad_admins --hbacsvcs sshd
```

Проверка без реального входа:

```bash
ipa hbactest --user='Administrator@ad.example.test' --host=ipa1.ipa.example.test --service=sshd
```

Ожидаемо `Access granted: True`. Реальный вход:

```bash
ssh Administrator@ad.example.test@ipa1.ipa.example.test
```

## 5.3. Если хочешь ужесточить доступ

Отключи `allow_all` (`ipa hbacrule-disable allow_all`) и оставь только нужные правила. Делай это, когда
убедился, что твоя собственная учётная запись входит по новому правилу, иначе можно отрезать себе доступ.

## Что дальше

Если что-то не работает: [глава 6](06-troubleshooting.md).
