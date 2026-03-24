# Инфраструктура проекта ВКР

Этот репозиторий поднимает базовую инфраструктуру для проекта по контрактно-ориентированной интеграции данных:

- `PostgreSQL` как общую СУБД для сервисов и экспериментов
- `Keycloak` как сервер аутентификации и управления пользователями
- `MinIO` как S3-совместимое объектное хранилище

Если коротко: это стартовая точка для локальной разработки. Сначала поднимается этот стенд, затем поверх него запускаются прикладные сервисы.

## Для чего нужен этот репозиторий

Репозиторий не содержит бизнес-логику ingestion или registry-сервисов. Его задача:

- дать готовую локальную среду без ручной настройки PostgreSQL, Keycloak и MinIO
- создать нужные базы данных заранее
- автоматически подготовить Keycloak realm и OIDC client для MinIO
- дать единый dev-стенд, на который могут опираться соседние сервисы проекта

## Как эта инфраструктура связана с остальным проектом

В рабочем каталоге рядом с этим репозиторием обычно лежат соседние сервисы:

- `contract` или `contract_test`:
  сервис управления Data Contracts
- `data-contract-ingestion-service`:
  MVP ingestion-пайплайна с registry и Airflow
- `integration-platform`:
  более разнесенная версия ingestion-платформы
- `datasets`:
  локальные тестовые наборы данных

Типичный порядок работы такой:

1. поднять этот infra-стенд
2. проверить, что доступны PostgreSQL, Keycloak и MinIO
3. запустить нужный прикладной сервис
4. настроить прикладной сервис на использование уже поднятой инфраструктуры

## Что поднимается

### PostgreSQL

Создаются базы:

- `keycloak`
- `test_data_set`
- `data_contracts`
- `data_lake`
- `dag_audit`

Они создаются автоматически при `docker compose up`, если их еще нет.

### Keycloak

Автоматически подготавливается:

- admin-пользователь
- realm `vkr`
- OIDC client `minio-console`
- тестовый пользователь `minio-user`

Keycloak в этом стенде работает в dev-режиме по HTTP. Это сделано специально для локальной разработки.

### MinIO

MinIO подключен к Keycloak через OIDC и использует стандартный `RolePolicy` flow.

Для MinIO зафиксирована версия:

- `minio/minio:RELEASE.2025-04-22T22-12-26Z`

Это сделано осознанно: более поздний `latest` в текущей проверенной конфигурации отдавал `loginStrategy=form` и ломал нормальный browser redirect-flow через Keycloak.

## Быстрый старт

Из директории `infra`:

```bash
docker compose up -d
```

Проверить, что все поднялось:

```bash
docker compose ps -a
```

Нормальное состояние:

- `postgres`, `keycloak`, `minio` в `Up`
- `postgres-init`, `keycloak-init` в `Exited (0)`

Это важно: `Exited (0)` для init-контейнеров здесь нормально.

## Доступ к сервисам

### PostgreSQL

- Host: `localhost`
- Port: `5432`
- User: `postgres`
- Password: `postgres`

### Keycloak

- URL: `http://localhost:8081`
- Admin Console: `http://localhost:8081/admin`
- Admin login: `admin`
- Admin password: `admin`

Подготовленные сущности:

- realm: `vkr`
- OIDC client: `minio-console`
- test user: `minio-user / minio-user`

### MinIO

- S3 API: `http://localhost:9000`
- Console: `http://localhost:9001`
- Root user: `minioadmin`
- Root password: `minioadmin`

MinIO Console настроен на OIDC через Keycloak. Для текущей зафиксированной версии Console API возвращает redirect-flow, а не обычную form-only схему.

## Рекомендуемый сценарий первого запуска

### 1. Поднять инфраструктуру

```bash
docker compose up -d
```

### 2. Открыть веб-интерфейсы

- Keycloak: `http://localhost:8081/admin`
- MinIO: `http://localhost:9001`

### 3. Проверить, что Keycloak корректно инициализировался

В Keycloak должны быть:

- realm `vkr`
- client `minio-console`
- user `minio-user`

### 4. Выбрать прикладной сервис, с которым будете работать

Например:

- если нужен registry контрактов, смотрите репозиторий `contract`
- если нужен ingestion pipeline, смотрите `data-contract-ingestion-service`
- если нужна Airflow-ориентированная платформа, смотрите `integration-platform`

## Как устроен этот репозиторий

```text
infra/
├── docker-compose.yml
├── README.md
├── keycloak/
│   └── init-keycloak.sh
└── postgres/
    └── init-databases.sh
```

Ключевые файлы:

- `docker-compose.yml`:
  основной compose-стенд
- `postgres/init-databases.sh`:
  создание баз данных
- `keycloak/init-keycloak.sh`:
  bootstrap Keycloak realm/client/user

## Что важно понимать перед запуском прикладных сервисов

Некоторые соседние репозитории поднимают собственные PostgreSQL и API через свои `docker-compose.yml`. Из-за этого возможны конфликты портов.

Наиболее частые конфликты:

- `5432` уже занят этим infra-стендом
- `8000` может быть занят registry/API сервисом
- `8080` или `8088` может быть занят Airflow

Если вы хотите использовать именно этот общий infra-стенд, у прикладного сервиса обычно нужно:

- либо не поднимать его встроенный PostgreSQL
- либо изменить порты в его compose-файле
- либо запускать сам сервис без compose, но с переменными окружения на уже поднятую инфраструктуру

## Какие базы можно использовать

Практически:

- `keycloak`:
  служебная база Keycloak
- `data_contracts`:
  база для contract registry
- `data_lake`:
  база для ingestion/lake-сценариев
- `dag_audit`:
  аудит и метаданные пайплайнов
- `test_data_set`:
  эксперименты, тестовые таблицы и ручные проверки

## Полезные команды

Запуск:

```bash
docker compose up -d
```

Остановка:

```bash
docker compose down
```

Полный сброс состояния:

```bash
docker compose down -v
docker compose up -d
```

Проверка compose-конфига:

```bash
docker compose config
```

Логи:

```bash
docker compose logs -f
docker compose logs -f postgres
docker compose logs -f keycloak
docker compose logs -f minio
docker compose logs keycloak-init
docker compose logs postgres-init
```

Повторно прогнать bootstrap Keycloak:

```bash
docker compose up -d --force-recreate keycloak-init
```

## Быстрые smoke-check проверки

### Проверить MinIO Console login flow

```bash
curl http://localhost:9001/api/v1/login
```

Ожидаемо в ответе должен быть `loginStrategy=redirect`.

### Проверить, что MinIO видит OIDC provider

```bash
docker run --rm --network infra_default --entrypoint /bin/sh minio/mc -c \
  'mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null && mc idp openid info local'
```

### Проверить, что Keycloak realm доступен

```bash
curl http://localhost:8081/realms/vkr/.well-known/openid-configuration
```

## Типовые проблемы

### Порты уже заняты

Проверьте, не запущены ли другие compose-стенды из соседних репозиториев.

### `postgres-init` или `keycloak-init` завершились

Если статус `Exited (0)`, это штатно.

### MinIO не дает OIDC redirect

Проверьте:

- что используется именно `RELEASE.2025-04-22T22-12-26Z`
- что `http://localhost:9001/api/v1/login` возвращает `loginStrategy=redirect`

### Что-то сломалось после серии правок в Keycloak/MinIO

Самый простой dev-способ начать заново:

```bash
docker compose down -v
docker compose up -d
```

## С чего начать новому разработчику

Если вы впервые заходите в проект, минимальный маршрут такой:

1. поднимите этот infra-стенд
2. зайдите в Keycloak и MinIO
3. убедитесь, что понимаете, какие сервисы уже доступны на локальной машине
4. выберите один прикладной репозиторий и прочитайте его README
5. запустите его поверх уже поднятой инфраструктуры, избегая конфликтов портов и дублирования PostgreSQL

Если нужна только инфраструктура для экспериментов с БД, MinIO и Keycloak, этого репозитория достаточно. Если нужна полная цепочка ingestion, нужен еще минимум один прикладной сервис из соседних репозиториев.
