#!/usr/bin/python3
"""Импорт тестовых пользователей и групп в FreeIPA из CSV, который делает gen_users.py.

Запускай на сервере IPA (или на хосте с ipa-client) после `kinit admin`.

  python3 import_ipa.py users.csv --dry-run         # показать, что будет сделано
  python3 import_ipa.py users.csv                   # создать пользователей и группы
  python3 import_ipa.py --cleanup                   # удалить всё созданное этим скриптом

Как скрипт помечает созданное. Все пользователи входят в группу lab_generated (имя можно
изменить ключом --marker), а группы отделов вложены в неё же. Очистка удаляет только то,
что лежит в этой группе, поэтому настоящие учётные записи она не затронет.

Первый вход: пароль, заданный администратором, в FreeIPA считается истёкшим, и пользователь
при первом входе обязан его сменить. Это штатное поведение.

Лицензия: GPL-3.0.
"""
import argparse
import csv
import sys


def read_rows(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    need = {"login", "first_name", "last_name", "display_name", "department", "dept_group", "password"}
    if not rows or not need.issubset(rows[0].keys()):
        sys.exit(f"{path}: нет нужных столбцов или файл пуст (ожидаю: {', '.join(sorted(need))})")
    return rows


def connect():
    from ipalib import api
    api.bootstrap(context="cli")
    api.finalize()
    try:
        api.Backend.rpcclient.connect()
    except Exception as e:  # нет билета Kerberos и т. п.
        sys.exit(f"Не удалось подключиться к IPA: {e}\nСначала выполни: kinit admin")
    return api


def ensure_group(api, errors, name, description):
    try:
        api.Command.group_add(name, description=description)
        return True
    except errors.DuplicateEntry:
        return False


def import_rows(api, errors, rows, marker, mail_domain):
    """Создаёт группы отделов и пользователей из строк CSV. Возвращает (создано, пропущено, ошибок)."""
    groups = {}
    for r in rows:
        groups[r["dept_group"]] = r["department"]

    if ensure_group(api, errors, marker, "Тестовые учётные записи (создано скриптами из репозитория)"):
        print(f"Создана группа-метка {marker}")
    for name, dept in sorted(groups.items()):
        if ensure_group(api, errors, name, dept):
            print(f"Создана группа {name} ({dept})")
            # вкладываем в метку только группы, созданные здесь: чужие группы очистка не тронет
            api.Command.group_add_member(marker, group=[name])
        else:
            print(f"Группа {name} уже существовала, она останется после очистки")

    created = skipped = failed = 0
    for r in rows:
        login = r["login"]
        try:
            api.Command.user_add(
                login,
                givenname=r["first_name"], sn=r["last_name"], cn=r["display_name"],
                displayname=r["display_name"], mail=[f"{login}@{mail_domain}"],
                userpassword=r["password"],
            )
        except errors.DuplicateEntry:
            skipped += 1
            continue
        except Exception as e:
            failed += 1
            print(f"Ошибка {login}: {e}", file=sys.stderr)
            continue
        api.Command.group_add_member(marker, user=[login])
        api.Command.group_add_member(r["dept_group"], user=[login])
        created += 1
    print(f"Готово: создано {created}, уже существовало {skipped}, ошибок {failed}")
    return created, skipped, failed


def cleanup_marker(api, errors, marker, yes=False, dry_run=False):
    """Удаляет пользователей и группы, помеченные группой marker, и саму метку."""
    try:
        res = api.Command.group_show(marker)["result"]
    except errors.NotFound:
        print(f"Группа {marker} не найдена: удалять нечего")
        return False
    users = sorted(res.get("member_user", ()))
    groups = sorted(res.get("member_group", ()))
    print(f"Будет удалено: пользователей {len(users)}, групп отделов {len(groups)}, группа {marker}")
    if users:
        print("Пользователи:", ", ".join(users[:10]) + (" ..." if len(users) > 10 else ""))
    if dry_run:
        print("[dry-run] ничего не удалено")
        return False
    if not yes and input("Удалить без возможности восстановления? Введи yes: ").strip() != "yes":
        print("Отменено")
        return False
    for u in users:
        try:
            api.Command.user_del(u)
        except Exception as e:
            print(f"Ошибка при удалении {u}: {e}", file=sys.stderr)
    for g in groups:
        try:
            api.Command.group_del(g)
        except Exception as e:
            print(f"Ошибка при удалении группы {g}: {e}", file=sys.stderr)
    api.Command.group_del(marker)
    print("Очистка завершена")
    return True


def do_import(args):
    rows = read_rows(args.csv)
    groups = {r["dept_group"]: r["department"] for r in rows}
    if args.dry_run:
        print(f"[dry-run] группа-метка: {args.marker}")
        print(f"[dry-run] групп отделов: {len(groups)}: {', '.join(sorted(groups))}")
        print(f"[dry-run] пользователей: {len(rows)}")
        for r in rows[:5]:
            print(f"[dry-run]   {r['login']}  {r['display_name']}  ({r['department']})")
        if len(rows) > 5:
            print(f"[dry-run]   ... и ещё {len(rows) - 5}")
        return
    from ipalib import errors
    api = connect()
    import_rows(api, errors, rows, args.marker, args.mail_domain or api.env.domain)


def do_cleanup(args):
    from ipalib import errors
    api = connect()
    cleanup_marker(api, errors, args.marker, yes=args.yes, dry_run=args.dry_run)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", nargs="?", help="CSV от gen_users.py (для импорта)")
    ap.add_argument("--marker", default="lab_generated", help="группа-метка (по умолчанию lab_generated)")
    ap.add_argument("--mail-domain", help="домен для адресов почты (по умолчанию домен IPA)")
    ap.add_argument("--dry-run", action="store_true", help="ничего не менять, только показать план")
    ap.add_argument("--cleanup", action="store_true", help="удалить всё, что создал этот скрипт")
    ap.add_argument("--yes", action="store_true", help="не спрашивать подтверждение при очистке")
    args = ap.parse_args()
    if args.cleanup:
        do_cleanup(args)
    elif args.csv:
        do_import(args)
    else:
        ap.error("укажи CSV для импорта или --cleanup")


if __name__ == "__main__":
    main()
