#!/usr/bin/env python3
"""Генератор случайных тестовых пользователей для FreeIPA и Active Directory.

Создаёт CSV (UTF-8 с BOM), который читают оба импортёра:
  import_ipa.py       для сервера FreeIPA
  Import-AdUsers.ps1  для контроллера домена AD

Примеры:
  python3 gen_users.py --count 50 --out users.csv
  python3 gen_users.py --count 200 --lang ru --seed 42 --out users.csv

Лицензия: GPL-3.0.
"""
import argparse
import csv
import random
import secrets
import string
import sys

MALE_FIRST = ["Иван", "Пётр", "Алексей", "Дмитрий", "Сергей", "Андрей", "Михаил", "Николай", "Владимир",
              "Евгений", "Артём", "Максим", "Олег", "Роман", "Кирилл", "Антон", "Игорь", "Константин",
              "Виктор", "Павел", "Георгий", "Тимофей", "Степан", "Денис"]
FEMALE_FIRST = ["Анна", "Мария", "Елена", "Ольга", "Наталья", "Татьяна", "Ирина", "Светлана", "Екатерина",
                "Юлия", "Анастасия", "Дарья", "Полина", "Виктория", "Алёна", "Марина", "Вера", "Надежда",
                "Людмила", "Галина", "Ксения", "Валентина", "Алина", "Диана"]
MALE_LAST = ["Иванов", "Петров", "Сидоров", "Смирнов", "Кузнецов", "Попов", "Васильев", "Соколов", "Михайлов",
             "Новиков", "Фёдоров", "Морозов", "Волков", "Алексеев", "Лебедев", "Семёнов", "Егоров", "Павлов",
             "Козлов", "Степанов", "Николаев", "Орлов", "Андреев", "Макаров", "Никитин", "Захаров", "Зайцев",
             "Соловьёв", "Борисов", "Яковлев", "Григорьев", "Романов", "Воробьёв", "Сергеев", "Кузьмин",
             "Ковальский", "Белецкий", "Лесной"]
EN_FIRST = ["John", "James", "Robert", "Michael", "William", "David", "Richard", "Joseph", "Thomas", "Charles",
            "Mary", "Patricia", "Jennifer", "Linda", "Elizabeth", "Barbara", "Susan", "Jessica", "Sarah", "Karen",
            "Daniel", "Matthew", "Emma", "Olivia"]
EN_LAST = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Miller", "Davis", "Wilson", "Anderson", "Taylor",
           "Thomas", "Moore", "Martin", "Jackson", "Thompson", "White", "Harris", "Clark", "Lewis", "Walker",
           "Hall", "Allen", "Young", "King", "Wright", "Scott", "Green", "Baker", "Adams", "Nelson"]
DEPARTMENTS = [
    ("Бухгалтерия", "buh"), ("Отдел продаж", "sales"), ("ИТ-отдел", "it"), ("Кадры", "hr"),
    ("Юридический отдел", "legal"), ("Логистика", "logistics"), ("Маркетинг", "marketing"),
    ("Служба поддержки", "support"),
]

TR = {"а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i",
      "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t",
      "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch", "ъ": "", "ы": "y",
      "ь": "", "э": "e", "ю": "yu", "я": "ya"}


def translit(s):
    return "".join(TR.get(ch, ch) for ch in s.lower())


def feminize(last):
    if last.endswith("ский"):
        return last[:-4] + "ская"
    if last.endswith("цкий"):
        return last[:-4] + "цкая"
    if last.endswith("ой"):
        return last[:-2] + "ая"
    if last.endswith(("ов", "ев", "ёв", "ин", "ын")):
        return last + "а"
    return last


def make_password(length=14):
    """Случайный пароль с символами четырёх классов (проходит типовые политики AD и IPA)."""
    symbols = "!@#%^*-_=+"
    pools = [string.ascii_lowercase, string.ascii_uppercase, string.digits, symbols]
    chars = [secrets.choice(p) for p in pools]
    allchars = "".join(pools)
    chars += [secrets.choice(allchars) for _ in range(length - len(chars))]
    secrets.SystemRandom().shuffle(chars)
    return "".join(chars)


def login_for(first_lat, last_lat, used):
    base = f"{first_lat}.{last_lat}"[:18]
    login, n = base, 1
    while login in used:
        n += 1
        login = f"{base}{n}"
    used.add(login)
    return login


def generate(count, lang, rnd):
    people, used_logins, used_names = [], set(), set()
    attempts = 0
    while len(people) < count:
        attempts += 1
        if attempts > count * 50:
            raise SystemExit("Не удалось подобрать столько уникальных имён: уменьши --count или смени --lang")
        use_ru = lang == "ru" or (lang == "mix" and rnd.random() < 0.5)
        if use_ru:
            female = rnd.random() < 0.5
            first = rnd.choice(FEMALE_FIRST if female else MALE_FIRST)
            last = rnd.choice(MALE_LAST)
            last = feminize(last) if female else last
            first_lat, last_lat = translit(first), translit(last)
        else:
            first, last = rnd.choice(EN_FIRST), rnd.choice(EN_LAST)
            first_lat, last_lat = first.lower(), last.lower()
        display = f"{first} {last}"
        if display in used_names:
            continue
        used_names.add(display)
        dept, slug = rnd.choice(DEPARTMENTS)
        people.append({
            "login": login_for(first_lat, last_lat, used_logins),
            "first_name": first, "last_name": last, "display_name": display,
            "department": dept, "dept_group": f"dept_{slug}",
            "password": make_password(),
        })
    return people


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--count", type=int, default=50, help="сколько пользователей создать (по умолчанию 50)")
    ap.add_argument("--lang", choices=["ru", "en", "mix"], default="mix",
                    help="ru, en или mix: смесь русских и английских имён (по умолчанию mix)")
    ap.add_argument("--seed", type=int, help="зерно для повторяемого набора имён (пароли всегда случайные)")
    ap.add_argument("--out", default="users.csv", help="выходной CSV (по умолчанию users.csv)")
    args = ap.parse_args()
    if not 1 <= args.count <= 5000:
        sys.exit("--count должен быть от 1 до 5000")

    people = generate(args.count, args.lang, random.Random(args.seed))
    fields = ["login", "first_name", "last_name", "display_name", "department", "dept_group", "password"]
    with open(args.out, "w", newline="", encoding="utf-8-sig") as f:   # BOM: PowerShell 5.1 читает кириллицу
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(people)
    print(f"Создано {len(people)} записей в {args.out}")
    print("В файле лежат пароли тестовых учётных записей: не коммить его и удали после импорта.")


if __name__ == "__main__":
    main()
