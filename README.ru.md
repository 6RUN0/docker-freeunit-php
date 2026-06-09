# Собственный Docker-образ на базе Debian для FreeUnit с PHP

[English](README.md) · [Русский](README.ru.md) — историю релизов смотрите в
[CHANGELOG.ru.md](CHANGELOG.ru.md).

Репозиторий собирает Docker-образы, объединяющие демон [FreeUnit][upstream]
(форк NGINX Unit) со встроенным модулем PHP, установленным из готовых
Debian-пакетов.

- **Апстрим FreeUnit:** <https://github.com/freeunitorg/freeunit>
- **Сборки пакетов для trixie:** <https://github.com/6RUN0/freeunit/releases> —
  форк, который организует `.deb`-сборки под Debian trixie, устанавливаемые этим
  образом.
- Дистрибутив: Debian **trixie** (только amd64 — апстрим публикует `.deb`
  лишь под amd64).
- Версии PHP: 8.3, 8.4, 8.5 (по одному встроенному PHP на образ — встраиваемый
  SAPI допускает только один).

Единый параметризованный `Dockerfile` покрывает всю матрицу через build-args;
`Makefile` собирает каждый вариант.

[upstream]: https://github.com/freeunitorg/freeunit

## Получение образа

Готовые образы публикуются в GitHub Container Registry по адресу
`ghcr.io/6run0/freeunit-php`. Каждый релиз публикует по одному образу на каждую
ветку PHP (8.3 / 8.4 / 8.5) под несколькими тегами, чтобы можно было закрепиться
настолько свободно или строго, насколько нужно:

| Шаблон тега | Пример | Указывает на |
|-------------|--------|--------------|
| `latest` | `ghcr.io/6run0/freeunit-php` | свежий релиз, PHP по умолчанию (8.4) |
| `<версия>` | `:0.0.4` | этот релиз репозитория, PHP по умолчанию |
| `<suite>-php<X.Y>` | `:trixie-php8.3` | свежий релиз на ветке PHP (двигается вперёд) |
| `<версия>-php<X.Y>` | `:0.0.4-php8.3` | релиз репозитория на ветке PHP |
| `<suite>-<релиз-freeunit>-php<X.Y>` | `:trixie-1.35.5-build4-php8.5` | конкретная сборка FreeUnit на ветке PHP |

```bash
docker pull ghcr.io/6run0/freeunit-php:trixie-php8.4
```

Теги `latest` и `<suite>-php<X.Y>` плавающие — следующий релиз перенаправляет
их. Теги `<версия>…` и `…-<релиз-freeunit>…` остаются привязанными к одному
релизу. Для байт-стабильного деплоя закрепляйтесь по дайджесту (`…@sha256:…`) —
именно эту форму проверяет и `gh attestation verify` (см. раздел
«Примечания»).

## Сборка

```bash
# Образ по умолчанию (trixie, php8.4)
docker build -t freeunit-php .

# Конкретная версия PHP
docker build --build-arg PHP_VER=8.3 -t freeunit-php:8.3 .

# Зафиксировать другой релиз FreeUnit
docker build \
  --build-arg FREEUNIT_VERSION=1.35.5-1 \
  --build-arg FREEUNIT_RELEASE=1.35.5-build4 \
  -t freeunit-php .
```

Или через Makefile:

```bash
make            # собрать все версии PHP (8.3, 8.4, 8.5)
make php8.3     # собрать один вариант
make latest     # собрать PHP по умолчанию (8.4) и пометить тегом :latest
make test       # собрать PHP по умолчанию и прогнать интеграционный smoke-тест
make lint       # запустить все установленные линтеры (hadolint, shellcheck, rumdl, typos)
make scan       # CVE-сканирование образа по умолчанию (trivy/grype, если установлены)
```

Значения по умолчанию для конкретного релиза (`SUITE`, `PHP_VER`,
`FREEUNIT_VERSION`, `FREEUNIT_RELEASE`) хранятся в ARG-ах `Dockerfile`, а
`Makefile` читает их оттуда, поэтому смена версии — это одна правка в
`Dockerfile`. Любую переменную можно переопределить в командной строке,
например `make FREEUNIT_RELEASE=1.35.6-build1 FREEUNIT_VERSION=1.35.6-1`.

## Запуск

```bash
docker run -d --name app \
  -p 8080:8080 \
  -v "$PWD/www:/www:ro" \
  -v "$PWD/config.json:/docker-entrypoint.d/config.json:ro" \
  freeunit-php
```

При первом запуске (когда `/var/lib/unit` пуст) entrypoint поднимает демон на
управляющем сокете, применяет всё содержимое `/docker-entrypoint.d/`, а затем
перезапускает демон на переднем плане. Если эта первоначальная настройка не
удалась, каталог состояния очищается, чтобы следующий запуск начался с чистого
листа.

Запускаемые примеры лежат в [`examples/`](examples/), по одному на подкаталог:

- [`examples/basic/`](examples/basic/) — самодостаточный, ужесточённый по
  безопасности деплой (маленький `Dockerfile` запекает приложение и его конфиг в
  образ): `cd examples/basic && docker compose up --build`.
- [`examples/cron-hook/`](examples/cron-hook/) — система хуков entrypoint: один
  образ работает в двух ролях, веб-сервер Unit и долгоживущий cron-раннер
  `supercronic`, выбираемых для каждого контейнера командой, без второго образа и
  без переопределения entrypoint.

### Соглашения `/docker-entrypoint.d/`

Файлы применяются в лексическом порядке, по расширению:

| Расширение | Действие |
|------------|----------|
| `*.sh`     | Исполняется (от root). |
| `*.pem`    | Загружается как набор сертификатов с именем файла (без `.pem`). |
| `*.json`   | Отправляется `PUT`-запросом в `config` Unit через управляющий сокет. |

Файлы прочих типов логируются и игнорируются.

> Несколько `*.json` **не** объединяются: `PUT /config` заменяет всю
> конфигурацию, поэтому в силу вступает только лексически последний файл
> (entrypoint предупреждает, если их больше одного). Поставляйте один
> объединённый файл конфигурации.

### Переменные окружения

Это runtime-API образа; их читает entrypoint.

| Переменная | По умолчанию | Назначение |
|------------|--------------|------------|
| `APPLICATION_USER`  | `unit` | Пользователь приложения. Если уже существует, его UID сохраняется. |
| `APPLICATION_UID`   | `1000` | UID, используемый только при создании пользователя. |
| `APPLICATION_GROUP` | `unit` | Группа приложения. Если уже существует, её GID сохраняется. |
| `APPLICATION_GID`   | `1000` | GID, используемый только при создании группы. |
| `APPLICATION_DIR`   | _не задана_ | Домашний каталог приложения; создаётся, если отсутствует. |
| `APPLICATION_CHOWN` | `yes`  | При `yes` выполняет `chown` `APPLICATION_DIR` на пользователя приложения. |
| `UNIT_ENTRYPOINT_QUIET_LOGS` | _не задана_ | Если задана, отключает логи entrypoint. |

> `APPLICATION_DIR` должен указывать на путь, принадлежащий контейнеру. При
> `APPLICATION_CHOWN=yes` его владелец переписывается, поэтому указание на
> host-bind-mount перепишет владельца файлов на хосте.

### Модель безопасности

Мастер-процесс Unit работает от root по своей природе — он привязывается к
привилегированным портам и порождает воркеры на каждое приложение. Сбрасывайте
привилегии **для приложения** через ключи `user`/`group` в конфиге Unit (а не
сменой пользователя контейнера) и ужесточайте контейнер в рантайме:

```bash
docker run --cap-drop=ALL --cap-add=SETUID --cap-add=SETGID \
  --security-opt=no-new-privileges ... freeunit-php
```

Относитесь к `/docker-entrypoint.d/*.sh` как к доверенному вводу — эти скрипты
исполняются от root внутри контейнера.

## Примечания

- **Только amd64.** FreeUnit публикует `.deb` под amd64; сборки `linux/arm64`
  нет.
- **Плавающая основа.** Образ фиксирует релиз FreeUnit, но база Debian и пакеты
  PHP с deb.sury.org — rolling, а на этапе сборки выполняется `apt
  full-upgrade`, поэтому две сборки одного тега не бит-в-бит воспроизводимы.
- Проверка целостности `.deb` — это сверка SHA256 с собственным `SHA256SUMS`
  релиза, который сам закреплён в репозитории по своему дайджесту, поэтому
  подменённый релиз не сможет подсунуть подходящий файл контрольных сумм
  (целостность, не апстрим-подлинность — подписи FreeUnit нет).
- **Публикуемые образы несут аттестации.** Каждый образ, отправленный в GHCR
  релизным воркфлоу, записывает безключевую аттестацию происхождения сборки и
  SBOM в формате SPDX как аттестации Sigstore. Проверьте скачанный образ, прежде
  чем доверять ему:

  ```bash
  gh attestation verify \
    oci://ghcr.io/6run0/freeunit-php@<digest> --owner 6RUN0
  ```

## См. также

- [Список изменений](CHANGELOG.ru.md)
- [FreeUnit (апстрим)](https://github.com/freeunitorg/freeunit)
- [Сборки пакетов FreeUnit под trixie](https://github.com/6RUN0/freeunit/releases)
- [Unit в Docker на unit.nginx.org](https://unit.nginx.org/howto/docker/)
- [github.com/nginx/unit/tree/master/pkg/docker](https://github.com/nginx/unit/tree/master/pkg/docker)
