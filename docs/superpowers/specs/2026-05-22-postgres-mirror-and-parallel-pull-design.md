# Спецификация дизайна: Зеркалирование Postgres и параллельный docker pull в startup_cos.sh

**Дата**: 2026-05-22  
**Статус**: На рассмотрении  

## 1. Введение и цели
Цели изменений:
1. **Зеркалирование образа `postgres:15-alpine`** в GCP Artifact Registry, чтобы избежать задержек скачивания и лимитов на запросы (rate limits) со стороны публичного Docker Hub.
2. **Параллельное скачивание образов** (`n8n`, `cloudflared`, `postgres`, `healthz-sidecar`) в скрипте инициализации ВМ `startup_cos.sh` для ускорения холодного старта инстанса.
3. **Параметризация образа Postgres** в Docker Compose файлах, так как ранее он был жестко захардкожен, из-за чего зеркалирование не работало для этого контейнера.

## 2. Предлагаемые изменения

### 2.1 Переменные Terraform

#### [MODIFY] [variables.tf](file:///c:/Users/oleia/Documents/2026/antigravity/gcp-self-healing-infra/terraform/variables.tf)
Добавляются новые переменные для фиксации образа Postgres по его SHA256-хешу:
* `postgres_image`: Полный путь к публичному образу с закрепленным digest.
* `postgres_image_tag`: Тэг версии (по умолчанию `15-alpine`).

#### [MODIFY] [main.tf](file:///c:/Users/oleia/Documents/2026/antigravity/gcp-self-healing-infra/terraform/main.tf)
В `locals` рассчитывается путь к образу в Artifact Registry:
* `postgres_digest_short = substr(element(split("@sha256:", var.postgres_image), 1), 0, 8)`
* `postgres_ar_image = "${local.ar_prefix}/postgres:${var.postgres_image_tag}-${local.postgres_digest_short}"`

Эти параметры передаются в `user-data` в качестве аргументов функции `templatefile` для `startup_cos.sh`.

---

### 2.2 CI/CD деплой

#### [MODIFY] [deploy.yml](file:///c:/Users/oleia/Documents/2026/antigravity/gcp-self-healing-infra/.github/workflows/deploy.yml)
* Добавляются переменные окружения `TF_VAR_postgres_image` и `TF_VAR_postgres_image_tag`.
* Обновляется шаг `Mirror images to Artifact Registry`: образ `postgres` скачивается, тэгируется и пушится в AR.
* Обновляются шаги верификации и проверки загрузки.

---

### 2.3 Docker Compose конфигурация

#### [MODIFY] [docker-compose.cos.yml](file:///c:/Users/oleia/Documents/2026/antigravity/gcp-self-healing-infra/scripts/docker-compose.cos.yml)
* Меняется описание образа Postgres: `image: ${POSTGRES_IMAGE}`.
* Переменная `POSTGRES_IMAGE` документируется в шапке файла в списке ожидаемых переменных.

---

### 2.4 Скрипт инициализации ВМ

#### [MODIFY] [startup_cos.sh](file:///c:/Users/oleia/Documents/2026/antigravity/gcp-self-healing-infra/scripts/startup_cos.sh)
1. **Проверка манифеста**:
   Аналогично `n8n` и `cloudflared`, добавляется проверка наличия образа в AR через `docker manifest inspect`. При отсутствии образа происходит откат на публичный Docker Hub.
2. **Параметризация шаблона Compose**:
   Встроенный шаблон docker-compose обновляется: `image: $${POSTGRES_IMAGE}`.
3. **Параллельное скачивание**:
   Вместо последовательного `docker pull` запускаются 4 фоновых процесса (`docker pull ... &`). Логи перенаправляются в `/var/log/pull_*.log`.
   Скрипт ожидает завершения всех процессов через `wait`. В случае ошибок выводится лог упавшего скачивания. При ошибке `healthz-sidecar` выполняется локальная сборка образа.

---

## 3. План верификации

### Автоматические тесты
1. Локальная валидация синтаксиса `startup_cos.sh`:
   ```bash
   shellcheck scripts/startup_cos.sh
   ```
2. Валидация Terraform:
   ```bash
   terraform validate
   ```

### Ручная верификация
Развернуть инфраструктуру в тестовой среде GCP и проанализировать `/var/log/startup.log` на созданном инстансе, проверив успешность параллельной загрузки образов из Artifact Registry.
