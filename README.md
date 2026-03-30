# Инфраструктура проекта ВКР

Этот репозиторий поднимает базовую инфраструктуру для проекта по контрактно-ориентированной интеграции данных:

- `PostgreSQL` как общую СУБД для сервисов и экспериментов
- `Keycloak` как сервер аутентификации и управления пользователями
- `MinIO` как S3-совместимое объектное хранилище

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
- Airflow auth client `airflow-auth`
- direct-grants client `contracts-client`
- browser client `contracts-ui-dev`
- audience client `contracts-api`
- service client `airflow-minio-sts`
- service client `airflow-contracts`
- system roles client `system-roles`
- системные роли `producer`, `consumer`, `admin`, `contracts_reader`
- realm roles `Viewer`, `User`, `Op`, `Admin`, `SuperAdmin`
- демо-пользователи `producer`, `consumer`, `admin`
- multi-role пользователь `minio-user`

Keycloak в этом стенде работает в dev-режиме по HTTP. Это сделано специально для локальной разработки.

### MinIO

MinIO подключен к Keycloak через OIDC и использует JWT claim-flow по claim `system_roles`.

Смысл роли в системе:

- `admin`: полные права
- `consumer`: чтение данных и управление бакетами
- `producer`: чтение данных

Эти роли рассматриваются как системные. Keycloak в этой схеме только хранит membership и выдает их в токене.

Для MinIO зафиксирована версия:

- `minio/minio:RELEASE.2025-04-22T22-12-26Z`

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
- Airflow auth client: `airflow-auth`
- direct grants client: `contracts-client`
- browser client: `contracts-ui-dev`
- audience client: `contracts-api`
- service client: `airflow-contracts`
- system roles client: `system-roles`
- demo users:
  `admin / admin`, `consumer / consumer`, `producer / producer`
- multi-role user:
  `minio-user / minio-user` с ролями `producer + consumer`

Для Airflow FAB OAuth SSO demo users дополнительно получают realm roles:

- `admin` -> `SuperAdmin`
- `producer` -> `User`
- `consumer` -> `User + Op`
- `minio-user` -> `User`

### MinIO

- S3 API: `http://localhost:9000`
- Console: `http://localhost:9001`
- Root user: `minioadmin`
- Root password: `minioadmin`

MinIO Console настроен на OIDC через Keycloak. Для текущей зафиксированной версии Console API возвращает redirect-flow, а не обычную form-only схему.

МинIO читает системные роли из claim:

- `system_roles`

Mapping ролей в MinIO:

- `admin` -> полный доступ
- `consumer` -> чтение + изменение бакетов
- `producer` -> только чтение
- `ingestion_rw` -> чтение и запись в landing bucket `ingestion-landing`

Если у пользователя несколько ролей, MinIO объединяет соответствующие policies.

Для интеграционного контура Airflow также создается service client:

- client id: `airflow-minio-sts`
- client secret: `airflow-minio-sts-secret`

Этот клиент получает системную роль `ingestion_rw`, а его access token дополнительно содержит:

- claim `system_roles`
- audience `minio-console`

Это позволяет Airflow выполнять обмен:

```text
Keycloak client_credentials
  -> JWT access token
  -> MinIO AssumeRoleWithWebIdentity
  -> temporary S3 credentials
```

Для доступа к `data-contracts-service` также создаётся отдельный service client:

- client id: `airflow-contracts`
- client secret: `airflow-contracts-secret`
- system role: `contracts_reader`
- audience: `contracts-api`

Это позволяет Airflow получать bearer token для contract registry отдельно от MinIO/STS-контура.

Для browser-тестирования `/docs` также создаётся публичный OIDC client:

- client id: `contracts-ui-dev`
- flow: Authorization Code + PKCE
- redirect URI: `http://localhost:8000/docs/oauth2-redirect`
- audience: `contracts-api`

Это позволяет логиниться в Swagger UI сервиса контрактов через Keycloak и тестировать методы прямо из браузера.

Для Airflow FAB OAuth SSO также создаётся отдельный confidential client:

- client id: `airflow-auth`
- client secret: `airflow-auth-secret`
- root URL: `http://localhost:8088`
- redirect URI: `http://localhost:8088/auth/oauth-authorized/keycloak`
- authentication flow:
  - `Standard Flow = ON`
  - `Direct Access Grants = ON`
  - `Service Accounts Roles = OFF`
  - `Authorization = OFF`

Этот client используется Airflow UI для OAuth login через Keycloak. Доступы в самом UI потом
разруливаются FAB-ролями Airflow, которые синхронизируются из `realm_access.roles` токена.
