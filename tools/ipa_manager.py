#!/usr/bin/python3
"""Интерактивное управление доменом FreeIPA (Linux).

Запускай на сервере IPA (или хосте с ipa-client) после `kinit admin`:

    python3 ipa_manager.py

Меню: сведения о домене и доверии, пользователи, группы, наполнение домена случайными данными,
очистка созданного. Парный скрипт для Active Directory: Manage-AdDomain.ps1 (Windows).

Лицензия: GPL-3.0.
"""
import csv
import getpass
import os
import platform
import random
import socket
import subprocess
import sys
import textwrap

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_users      # noqa: E402  генератор случайных людей
import import_ipa     # noqa: E402  общие функции импорта и очистки

MARKER = "lab_generated"

# ---------- Вывод ----------
C = {"r": "\033[31m", "g": "\033[32m", "y": "\033[33m", "c": "\033[36m", "m": "\033[35m", "0": "\033[0m"}
if not sys.stdout.isatty():
    C = {k: "" for k in C}


def say(color, text):
    print(f"{C[color]}{text}{C['0']}")


def title(text):
    print(f"\n{C['m']}=== {text} ==={C['0']}")


def first(v, default=""):
    if v is None:
        return default
    if isinstance(v, (list, tuple)):
        return first(v[0], default) if v else default
    return v


def table(headers, rows):
    rows = [[str(c) for c in r] for r in rows]
    widths = [max([len(h)] + [len(r[i]) for r in rows]) for i, h in enumerate(headers)]
    line = "  ".join(h.ljust(widths[i]) for i, h in enumerate(headers))
    print(C["c"] + line + C["0"])
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print("  ".join(r[i].ljust(widths[i]) for i in range(len(headers))))


def ask(prompt, default=None):
    suffix = f" [{default}]" if default not in (None, "") else ""
    v = input(f"{prompt}{suffix}: ").strip()
    return v if v else (default if default is not None else "")


def confirm(prompt):
    return input(f"{prompt} (y/n): ").strip().lower() in ("y", "yes", "д", "да")


def read_password():
    while True:
        p1 = getpass.getpass("Пароль: ")
        if not p1:
            say("r", "Пароль не может быть пустым")
            continue
        if p1 == getpass.getpass("Повтори пароль: "):
            return p1
        say("r", "Пароли не совпадают, попробуй ещё раз")


# ---------- Шапка: домен, учётная запись, хост ----------
def _local_ips():
    try:
        out = subprocess.run(["ip", "-4", "-o", "addr", "show"], capture_output=True, text=True, timeout=5).stdout
        ips = [ln.split()[3].split("/")[0] for ln in out.splitlines() if len(ln.split()) > 3]
        return [i for i in ips if not i.startswith("127.")]
    except Exception:
        return []


def _os_name():
    try:
        with open("/etc/os-release", encoding="utf-8") as f:
            for ln in f:
                if ln.startswith("PRETTY_NAME="):
                    return ln.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return platform.platform()


def build_header():
    """Собирает сведения для шапки один раз при подключении."""
    env = Ctx.api.env
    h = {"domain": env.domain, "realm": getattr(env, "realm", "-"),
         "server": getattr(env, "server", None) or getattr(env, "host", "-"),
         "version": "-", "principal": "-", "display": "-", "rights": "не удалось определить"}
    try:
        h["version"] = str(cmd("ping").get("summary", "-")).strip()
    except Exception:
        pass
    try:
        who = cmd("whoami")["result"]
        kind, args = who.get("object"), who.get("arguments") or ()
        name = str(args[0]) if args else "-"
        h["principal"] = f"{name} ({kind})" if kind else name
        if kind == "user":
            u = cmd("user_show", name, all=True)["result"]
            h["display"] = first(u.get("displayname")) or first(u.get("cn"), "-")
            groups = set(u.get("memberof_group", ())) | set(u.get("memberofindirect_group", ()))
            roles = list(u.get("memberof_role", ()))
            if "admins" in groups:
                h["rights"] = "администратор FreeIPA (группа admins)"
            else:
                h["rights"] = "не в группе admins: часть действий может быть недоступна"
            if roles:
                h["rights"] += f"; роли: {', '.join(roles)}"
    except Exception:
        pass
    ips = _local_ips()
    h["host"] = {
        "name": socket.gethostname(), "fqdn": socket.getfqdn(), "ips": ", ".join(ips) or "н/д",
        "os": _os_name(), "py": platform.python_version(), "user": getpass.getuser(),
        "root": hasattr(os, "geteuid") and os.geteuid() == 0,
    }
    return h


def show_header():
    h = Ctx.header
    print(f"\n{C['m']}========== УПРАВЛЕНИЕ FreeIPA: {Ctx.api.env.domain} =========={C['0']}")
    if not h:
        return
    w = h["host"]
    rows = [
        ("Домен:", f"{h['domain']}, область Kerberos {h['realm']}"),
        ("Сервер IPA:", f"{h['server']}   ({h['version']})"),
        ("Учётная запись:", f"{h['principal']}, {h['display']}"),
        ("Права:", h["rights"]),
        ("АРМ:", f"{w['name']} ({w['fqdn']})"),
        ("", f"IP {w['ips']}"),
        ("", f"{w['os']}; Python {w['py']}; локальный пользователь {w['user']}{' (root)' if w['root'] else ''}"),
    ]
    for label, value in rows:
        print(f"{C['c']}{label:<17}{C['0']}{value}")
    print("-" * 60)


# ---------- Подключение ----------
class Ctx:
    api = None
    errors = None
    header = None


def connect():
    from ipalib import errors
    Ctx.errors = errors
    Ctx.api = import_ipa.connect()
    Ctx.header = build_header()


def cmd(name, *args, **kw):
    return getattr(Ctx.api.Command, name)(*args, **kw)


def count(name, **kw):
    return cmd(name, sizelimit=0, **kw).get("count", 0)


def user_exists(uid):
    try:
        cmd("user_show", uid)
        return True
    except Ctx.errors.NotFound:
        return False


def group_exists(name):
    try:
        cmd("group_show", name)
        return True
    except Ctx.errors.NotFound:
        return False


# ---------- Сведения ----------
def show_info():
    env = Ctx.api.env
    title(f"Сведения о домене {env.domain}")
    print(f"Realm:          {env.realm}")
    print(f"Домен:          {env.domain}")
    print(f"Сервер:         {env.host}")
    print()
    try:
        print(f"Пользователей:  {count('user_find')}")
        print(f"Групп:          {count('group_find')}")
        print(f"Хостов:         {count('host_find')}")
        print(f"Правил HBAC:    {count('hbacrule_find')}")
        try:
            members = cmd("group_show", MARKER)["result"].get("member_user", ())
            print(f"Тестовых (в группе {MARKER}): {len(members)}")
        except Ctx.errors.NotFound:
            print(f"Тестовых (в группе {MARKER}): 0")
    except Exception as e:
        say("r", f"Ошибка при чтении каталога: {e}")
    try:
        pol = cmd("pwpolicy_show")["result"]
        print("\nГлобальная политика паролей:")
        print(f"  Макс. срок жизни, дней: {first(pol.get('krbmaxpwdlife'), '-')}")
        print(f"  Мин. длина:             {first(pol.get('krbpwdminlength'), '-')}")
        print(f"  Мин. число классов:     {first(pol.get('krbpwdmindiffchars'), '-')}")
    except Exception:
        pass
    show_trusts(header=False)


def show_trusts(header=True):
    if header:
        title("Доверительные отношения")
    try:
        found = cmd("trust_find", sizelimit=0)["result"]
    except Exception as e:
        say("y", f"Доверия недоступны: {e}")
        return
    if not found:
        print("\nДоверий нет")
        return
    print("\nДоверия с другими доменами:")
    rows = []
    for t in found:
        name = first(t.get("cn"))
        try:
            full = cmd("trust_show", name)["result"]
        except Exception:
            full = t
        rows.append([name, first(full.get("ipantflatname")), first(full.get("trust_direction")),
                     first(full.get("trust_type")), first(full.get("trust_status"), "-")])
    table(["Домен", "NetBIOS", "Направление", "Тип", "Состояние"], rows)
    try:
        zones = cmd("dnsforwardzone_find", sizelimit=0)["result"]
        if zones:
            print("\nЗоны-переадресации DNS:")
            table(["Зона", "Пересыльщики"], [[first(z.get("idnsname")), ", ".join(z.get("idnsforwarders", ()))] for z in zones])
    except Exception:
        pass


# ---------- Пользователи ----------
def list_users():
    title("Пользователи")
    crit = ask("Строка для поиска (пусто: все)", "")
    kw = {"sizelimit": 0}
    users = cmd("user_find", crit, **kw)["result"] if crit else cmd("user_find", **kw)["result"]
    rows = [[first(u.get("uid")), first(u.get("cn")), first(u.get("mail")),
             "отключён" if first(u.get("nsaccountlock"), False) else "активен"] for u in users]
    if not rows:
        print("Ничего не найдено")
        return
    table(["Логин", "Имя", "Почта", "Статус"], sorted(rows))
    print(f"\nВсего: {len(rows)}")


def print_user(uid):
    """Печатает карточку пользователя. Возвращает False, если его нет."""
    try:
        u = cmd("user_show", uid, all=True)["result"]
    except Ctx.errors.NotFound:
        say("r", f"Пользователь {uid} не найден")
        return False
    for label, key in [("Логин", "uid"), ("Имя", "givenname"), ("Фамилия", "sn"), ("Отображаемое имя", "displayname"),
                       ("Почта", "mail"), ("Принципал", "krbprincipalname"), ("Оболочка", "loginshell"),
                       ("Домашний каталог", "homedirectory"), ("UID", "uidnumber")]:
        print(f"{label + ':':<20}{', '.join(str(x) for x in (u.get(key) or ['-']))}")
    print(f"{'Заблокирован:':<20}{'да' if first(u.get('nsaccountlock'), False) else 'нет'}")
    groups = list(u.get("memberof_group", ()))
    print(f"{'Группы (' + str(len(groups)) + '):':<20}{', '.join(groups) or '-'}")
    for label, key in [("Правила HBAC", "memberof_hbacrule"), ("Правила sudo", "memberof_sudorule"), ("Роли", "memberof_role")]:
        if u.get(key):
            print(f"{label + ':':<20}{', '.join(u[key])}")
    return True


def show_user():
    title("Карточка пользователя")
    uid = ask("Логин")
    if uid:
        print_user(uid)


def add_user():
    title("Создание пользователя")
    uid = ask("Логин")
    if not uid:
        return
    if user_exists(uid):
        say("r", f"Пользователь {uid} уже существует")
        return
    first_name = ask("Имя")
    last_name = ask("Фамилия")
    if not first_name or not last_name:
        say("r", "Имя и фамилия обязательны")
        return
    display = ask("Отображаемое имя", f"{first_name} {last_name}")
    mail = ask("Почта", f"{uid}@{Ctx.api.env.domain}")
    password = read_password()
    try:
        cmd("user_add", uid, givenname=first_name, sn=last_name, cn=display, displayname=display,
            mail=[mail], userpassword=password)
        say("g", f"Пользователь {uid} создан (при первом входе потребуется сменить пароль)")
    except Exception as e:
        say("r", f"Ошибка: {e}")
        return
    if confirm("Добавить в группы?"):
        for g in ask("Группы через запятую").split(","):
            g = g.strip()
            if g:
                add_to_group(uid, g, quiet=True)


def delete_user():
    title("Удаление пользователя")
    uid = ask("Логин")
    if not uid:
        return
    say("c", "Будет удалена учётная запись:")
    if not print_user(uid):
        return
    me = (Ctx.header or {}).get("principal", "").split(" ")[0]
    if me == uid:
        say("y", "ВНИМАНИЕ: это учётная запись, под которой запущен скрипт.")
    if confirm(f"\nУдалить {uid} без возможности восстановления?"):
        try:
            cmd("user_del", uid)
            say("g", f"Пользователь {uid} удалён")
        except Exception as e:
            say("r", f"Ошибка: {e}")
    else:
        say("y", "Отменено")


def toggle_user():
    title("Включить или отключить пользователя")
    uid = ask("Логин")
    if not uid or not user_exists(uid):
        say("r", "Пользователь не найден")
        return
    locked = first(cmd("user_show", uid)["result"].get("nsaccountlock"), False)
    action = "включить" if locked else "отключить"
    if confirm(f"{action.capitalize()} {uid}?"):
        try:
            cmd("user_enable" if locked else "user_disable", uid)
            say("g", f"Готово: {uid} {'включён' if locked else 'отключён'}")
        except Exception as e:
            say("r", f"Ошибка: {e}")


def reset_password():
    title("Сброс пароля")
    uid = ask("Логин")
    if not uid or not user_exists(uid):
        say("r", "Пользователь не найден")
        return
    pw = read_password()
    try:
        cmd("user_mod", uid, userpassword=pw)
        say("g", "Пароль задан (при первом входе пользователь обязан его сменить)")
    except Exception as e:
        say("r", f"Ошибка: {e}")


# ---------- Группы ----------
def list_groups():
    title("Группы")
    groups = cmd("group_find", sizelimit=0)["result"]
    rows = [[first(g.get("cn")), first(g.get("description")), len(g.get("member_user", ()))] for g in groups]
    table(["Группа", "Описание", "Польз."], sorted(rows))
    print(f"\nВсего: {len(rows)}")


def add_group():
    title("Создание группы")
    name = ask("Имя группы")
    if not name:
        return
    if group_exists(name):
        say("r", f"Группа {name} уже существует")
        return
    try:
        cmd("group_add", name, description=ask("Описание", name))
        say("g", f"Группа {name} создана")
    except Exception as e:
        say("r", f"Ошибка: {e}")


def print_group(name):
    """Печатает сведения о группе и состав. Возвращает число участников или None, если группы нет."""
    try:
        g = cmd("group_show", name, all=True)["result"]
    except Ctx.errors.NotFound:
        say("r", f"Группа {name} не найдена")
        return None
    users, groups = list(g.get("member_user", ())), list(g.get("member_group", ()))
    ext = list(g.get("ipaexternalmember", ()))
    print(f"{'Группа:':<20}{name}")
    print(f"{'Описание:':<20}{first(g.get('description'), '-')}")
    print(f"{'GID:':<20}{first(g.get('gidnumber'), '-')}")
    print(f"{'Входит в группы:':<20}{', '.join(g.get('memberof_group', ())) or '-'}")
    for label, key in [("Правила HBAC", "memberof_hbacrule"), ("Правила sudo", "memberof_sudorule")]:
        if g.get(key):
            print(f"{label + ':':<20}{', '.join(g[key])}")
    print(f"{'Пользователи (' + str(len(users)) + '):':<20}{', '.join(sorted(users)) or '-'}")
    print(f"{'Группы (' + str(len(groups)) + '):':<20}{', '.join(sorted(groups)) or '-'}")
    if ext:
        print(f"{'Внешние (AD) (' + str(len(ext)) + '):':<20}{', '.join(ext)}")
    return len(users) + len(groups) + len(ext)


def delete_group():
    title("Удаление группы")
    name = ask("Имя группы")
    if not name or not group_exists(name):
        say("r", "Группа не найдена")
        return
    if name in ("admins", "editors", "trust admins", "ipausers"):
        say("r", f"Группа {name} служебная, её нельзя удалять здесь")
        return
    say("c", "Будет удалена группа:")
    total = print_group(name)
    if total:
        say("y", f"В группе {total} участников. Сами записи не удаляются, но потеряют права, выданные через эту группу.")
        ok = ask("\nДля удаления введи yes") == "yes"
    else:
        ok = confirm(f"\nУдалить группу {name}?")
    if ok:
        try:
            cmd("group_del", name)
            say("g", f"Группа {name} удалена")
        except Exception as e:
            say("r", f"Ошибка: {e}")
    else:
        say("y", "Отменено")


def show_members():
    title("Участники группы")
    name = ask("Имя группы")
    if name:
        print_group(name)


def add_to_group(uid=None, group=None, quiet=False):
    if not quiet:
        title("Добавить пользователя в группу")
    uid = uid or ask("Логин")
    group = group or ask("Группа")
    if not user_exists(uid):
        say("r", f"Пользователь {uid} не найден")
        return
    if not group_exists(group):
        say("r", f"Группа {group} не найдена")
        return
    try:
        cmd("group_add_member", group, user=[uid])
        say("g", f"{uid} добавлен в {group}")
    except Exception as e:
        say("r", f"Ошибка: {e}")


def remove_from_group():
    title("Убрать пользователя из группы")
    uid, group = ask("Логин"), ask("Группа")
    if not group_exists(group):
        say("r", f"Группа {group} не найдена")
        return
    say("c", f"Текущий состав группы {group}:")
    g = cmd("group_show", group)["result"]
    members = sorted(g.get("member_user", ()))
    print(f"Пользователи ({len(members)}): {', '.join(members) or '-'}")
    if uid not in members:
        say("y", f"{uid} не состоит в группе {group}")
        return
    if not confirm(f"Убрать {uid} из {group}?"):
        say("y", "Отменено")
        return
    try:
        cmd("group_remove_member", group, user=[uid])
        say("g", f"{uid} убран из {group}")
    except Exception as e:
        say("r", f"Ошибка: {e}")


# ---------- Наполнение и очистка ----------
def populate():
    title("Наполнение домена случайными данными")
    print("Пользователи попадут в группу-метку", MARKER, "и в группы отделов. Очистка (пункт 16) удаляет только их.")
    try:
        n = int(ask("Сколько пользователей создать", "20"))
    except ValueError:
        say("r", "Нужно число")
        return
    if not 1 <= n <= 1000:
        say("r", "Допустимо от 1 до 1000")
        return
    lang = ask("Имена: ru, en или mix (смесь)", "mix")
    if lang not in ("ru", "en", "mix"):
        say("r", "Допустимо ru, en или mix")
        return
    rows = gen_users.generate(n, lang, random.Random())
    print("\nПример того, что будет создано:")
    table(["Логин", "Имя", "Отдел"], [[r["login"], r["display_name"], r["department"]] for r in rows[:8]])
    if n > 8:
        print(f"... и ещё {n - 8}")
    if not confirm(f"\nСоздать {n} пользователей в домене {Ctx.api.env.domain}?"):
        say("y", "Отменено")
        return
    import_ipa.import_rows(Ctx.api, Ctx.errors, rows, MARKER, Ctx.api.env.domain)
    path = ask("\nСохранить CSV, чтобы загрузить тех же людей в AD? Путь к файлу (пусто: не сохранять)", "")
    if path:
        with open(path, "w", newline="", encoding="utf-8-sig") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
        os.chmod(path, 0o600)
        say("y", f"Сохранено в {path}. Внутри пароли тестовых учётных записей: не коммить файл и удали после импорта.")


def cleanup():
    title("Очистка созданного наполнением")
    import_ipa.cleanup_marker(Ctx.api, Ctx.errors, MARKER)


# ---------- Меню ----------
MENU = [
    ("Сведения о домене", show_info),
    ("Доверительные отношения", show_trusts),
    ("Список и поиск пользователей", list_users),
    ("Карточка пользователя", show_user),
    ("Создать пользователя", add_user),
    ("Удалить пользователя", delete_user),
    ("Отключить или включить пользователя", toggle_user),
    ("Сбросить пароль", reset_password),
    ("Список групп", list_groups),
    ("Создать группу", add_group),
    ("Удалить группу", delete_group),
    ("Участники группы", show_members),
    ("Добавить пользователя в группу", add_to_group),
    ("Убрать пользователя из группы", remove_from_group),
    ("Наполнить домен случайными данными", populate),
    ("Очистить созданное наполнением", cleanup),
]


def main():
    connect()
    while True:
        show_header()
        for i, (label, _) in enumerate(MENU, 1):
            print(f"{i:>2}. {label}")
        print(" 0. Выход")
        try:
            choice = input("\nВыбери действие: ").strip()
            if choice == "0":
                say("g", "До свидания!")
                return
            if choice.isdigit() and 1 <= int(choice) <= len(MENU):
                MENU[int(choice) - 1][1]()
            else:
                say("r", "Неверный выбор")
            input("\nНажми Enter, чтобы продолжить...")
        except (KeyboardInterrupt, EOFError):
            print()
            say("y", "Прервано")
            return
        except Exception as e:
            say("r", f"Ошибка: {e}")
            input("\nНажми Enter, чтобы продолжить...")


if __name__ == "__main__":
    main()
