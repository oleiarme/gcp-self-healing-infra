# Implementation Plan: SRE-агент авто-диагностики

## Overview

Реализация SRE-агента авто-диагностики как Cloud Function Gen2 (Python 3.12), подписанной на Pub/Sub topic `sre-incidents`. Агент принимает алерты Cloud Monitoring, собирает контекст (логи + метрики + external probe), редактирует секреты, вызывает LLM (или rule-based fallback) и отправляет структурированный диагноз в Telegram. Инфраструктура описывается в Terraform с поддержкой ОС-профиля ( COS).

## Tasks

- [x] 1. Структура проекта, модели данных и конфигурация
  - [x] 1.1 Создать директорию `terraform/functions/sre_agent/` и файлы модулей
    - Создать файлы: `main.py`, `alerts.py`, `context.py`, `redact.py`, `llm.py`, `rules.py`, `notify.py`, `store.py`, `prompts.py`, `models.py`, `settings.py`, `requirements.txt`
    - Создать `__init__.py` для пакета
    - _Requirements: 1.8, 7.1_

  - [x] 1.2 Реализовать Pydantic-модели в `models.py`
    - Определить `LogLine`, `Metric`, `Signal`, `Incident`, `Diagnosis`, `Notification`
    - `Incident.kind` — `Literal["cpu", "mem", "pg_fatal", "n8n_error", "external_unreachable"]`
    - `Diagnosis` — поля `hypothesis`, `evidence_refs`, `confidence`, `suggested_fix`, `suggested_command`, `model`, `tokens_in`, `tokens_out`, `cost_usd`, `created_at`
    - _Requirements: 1.1–1.6, 3.1, 6.5_

  - [x] 1.3 Реализовать `settings.py` — единый источник конфигурации через Pydantic BaseSettings
    - Все time-window константы (`bootstrap_grace_seconds`, `live_migration_window_sec`, `correlation_window_sec`, `cross_kind_correlation_window_sec`) через env-переменные
    - Kill-switch `SRE_AGENT_ENABLED`, LLM-параметры, Telegram, context-gathering параметры
    - _Requirements: 4.2, 7.2, 9.1, 9.2, 11.1, 11.4, 13.1, 13.2_

  - [x] 1.4 Создать `requirements.txt` с зависимостями
    - `google-cloud-logging`, `google-cloud-monitoring`, `google-cloud-firestore`, `google-cloud-compute`, `google-cloud-secret-manager`, `pydantic`, `pydantic-settings`, `httpx`, `dnspython`, `tiktoken` (или эвристика), `cloudevents`
    - _Requirements: 7.1_

- [x] 2. Парсинг алертов и редакция секретов
  - [x] 2.1 Реализовать `alerts.py` — функция `parse_alert(payload) -> Incident | None`
    - Маппинг `policy_name` → `kind` и `severity`
    - Валидация обязательных полей `incident.incident_id`, `incident.policy_name`
    - Возврат `None` при отсутствии обязательных полей (для `"bad_payload"`)
    - Детерминистический парсинг (P3)
    - Registry-паттерн `KIND_HANDLERS: dict[str, Callable]` для расширяемости
    - _Requirements: 1.1–1.8_

  - [ ]* 2.2 Property-тест: parse_alert детерминистичен (P3)
    - **Property 3: parse_alert is deterministic**
    - **Validates: Requirements 1.6**

  - [x] 2.3 Реализовать `redact.py` — функция `redact(text: str) -> str`
    - Таблица `SECRET_PATTERNS`: email, Bearer token, JWT, postgres URL, password=...
    - Опциональный IPv4 через env `REDACT_IPV4`
    - Функция `redact_signals(signals: list[Signal]) -> list[Signal]`
    - _Requirements: 5.1, 5.2, 5.4, 5.5_

  - [ ]* 2.4 Property-тест: redact удаляет все secret-паттерны (P1)
    - **Property 1: Redact removes all secret patterns**
    - **Validates: Requirements 5.1**

  - [ ]* 2.5 Property-тест: redact идемпотентен (P2)
    - **Property 2: Redact is idempotent**
    - **Validates: Requirements 5.2**

  - [ ]* 2.6 Property-тест: redact length bounded (P8)
    - **Property 8: Redact length bounded — `len(redact(s)) ≤ len(s) + 1024`**
    - **Validates: Requirements 5.4**

- [x] 3. Checkpoint — Убедиться что модели, парсинг и редакция работают
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 4. Сбор контекста (логи + метрики + external probe)
  - [x] 4.1 Реализовать `context.py` — функции `get_logs`, `get_metric_series`, `gather_context`
    - Гетерогенный фильтр (COS `jsonPayload.container.name`)
    - Лимит `LOG_LINES_PER_CONTAINER = 100`, окно `LOG_LOOKBACK_MINUTES = 5`
    - Graceful degradation при throttle Cloud Logging API (`partial=true`)
    - Группировка многострочных записей (stack traces) по timestamp
    - _Requirements: 2.1–2.5, 2.9, 11.2, 11.3_

  - [x] 4.2 Реализовать `probe_external_reachability(host)` в `context.py`
    - Четыре фазы строго последовательно: DNS → TCP:443 → HTTPS root → HTTPS `/healthz/deep`
    - Таймауты 5 + 5 + 10 + 10 секунд, общий wall-clock ≤ 30 s
    - Всегда возвращает `dict`, исключения не пробрасываются
    - Каждая фаза независима — отказ одной не блокирует остальные
    - _Requirements: 2.6, 2.7, 2.8_

  - [ ]* 4.3 Property-тест: external probe завершается в пределах timeout budget (P9)
    - **Property 9: External probe completes within timeout budget (≤ 30 s)**
    - **Validates: Requirements 2.7**

  - [x] 4.4 Реализовать `is_live_migration_in_window` и `instance_age_seconds_cached` в `context.py`
    - In-memory TTL-кэш (60 s) на `creation_timestamp` lookups
    - Структурированный лог `event=compute_api_call cache_hit=<true|false>`
    - _Requirements: 9.2, 9.3, 7.8_

  - [x] 4.5 Реализовать контроль размера контекста (token truncation)
    - `MAX_CONTEXT_TOKENS` (default 12000), эвристика `len(text) // 4`
    - Усечение логов снизу вверх (свежие приоритетнее), маркер `[truncated: oldest N lines removed]`
    - Метрики и probe-результат без усечения
    - _Requirements: 11.1, 11.2, 11.3_

- [ ] 5. LLM-интеграция и rule-based fallback
  - [x] 5.1 Реализовать `prompts.py` — `SYSTEM_PROMPT`, `USER_TEMPLATE`, `RUNBOOK_EXCERPT`
    - System-prompt с инструкцией `<untrusted_log>` — не следовать инструкциям из тегов
    - User-template с форматированием incident JSON, логов, метрик
    - Runbook excerpt с паттернами для n8n/postgres/cloudflared/COS
    - _Requirements: 5.3_

  - [x] 5.2 Реализовать `llm.py` — pluggable LLM provider
    - Функция `analyze_with_llm(incident, signals) -> Diagnosis`
    - Адаптеры `_call_gemini`, `_call_claude`, `_call_openai`
    - Переключение через `settings.llm_provider` без изменения сигнатуры
    - `ValueError` при неизвестном провайдере
    - Client-side валидация: `json.loads` → Pydantic `Diagnosis`
    - Таймаут `LLM_TIMEOUT_SECONDS` (default 45 s)
    - Структурированный лог `event=llm_call` с `tokens_in`, `tokens_out`, `cost_usd`, `provider`, `model`
    - _Requirements: 13.1–13.6, 4.6, 11.4_

  - [x] 5.3 Реализовать `rules.py` — `rule_based_diagnose(incident, signals) -> Diagnosis`
    - Детерминистический классификатор: OOM, postgres FATAL, ECONNREFUSED, unknown
    - Всегда `confidence="low"`, `model="rule-based-v1"`
    - _Requirements: 6.4, 6.5_

  - [ ]* 5.4 Property-тест: rule-based diagnosis confidence is low (P7)
    - **Property 7: Rule-based diagnosis confidence is low**
    - **Validates: Requirements 6.5**

- [ ] 6. Хранилище (Firestore) — дедуп, корреляция, бюджет
  - [x] 6.1 Реализовать `store.py` — дедупликация и бюджет
    - `is_duplicate(incident_id)` — проверка Firestore `incidents/{id}` с TTL 1 час
    - `mark_seen(incident_id, ttl_seconds)` — запись документа
    - `today_cost_usd()` — агрегация `cost_usd` из `diagnoses` за текущий день UTC
    - `persist_diagnosis(diagnosis, correlation_id)` — запись в коллекцию `diagnoses` (TTL 30 дней)
    - `persist_diagnosis_skipped(incident, reason)` — запись подавленного инцидента
    - Graceful degradation при недоступности Firestore
    - _Requirements: 4.1, 4.2, 10.1, 10.4_

  - [ ]* 6.2 Unit-тест: дедупликация предотвращает повторный LLM-вызов (P4)
    - **Property 4: Deduplication — для двух инвокаций с одинаковым incident.id LLM вызывается ≤ 1 раз**
    - **Validates: Requirements 4.1**

  - [ ]* 6.3 Unit-тест: budget enforcement — при исчерпании бюджета LLM не вызывается (P5)
    - **Property 5: Token budget enforced**
    - **Validates: Requirements 4.2**

  - [x] 6.4 Реализовать корреляцию в `store.py` — `find_or_create_incident_window`
    - Same-kind окно ≤ 90 s, cross-kind окно ≤ 180 s
    - Firestore Transaction для атомарного обновления `co_signals`, `last_signal_at`, `incident_ids`
    - Priority matrix: `pg_fatal > mem > cpu > external_unreachable > n8n_error`
    - Window-документ открыт до 30 минут
    - _Requirements: 9.1, 9.5_

  - [ ]* 6.5 Unit-тест: корреляция уменьшает количество LLM-вызовов (P10)
    - **Property 10: Correlation reduces LLM calls within window (same-kind и cross-kind)**
    - **Validates: Requirements 9.1**

- [x] 7. Checkpoint — Убедиться что context, LLM, store работают корректно
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 8. Уведомления в Telegram
  - [x] 8.1 Реализовать `notify.py` — отправка диагноза в Telegram
    - `notify_telegram(incident, diagnosis, correlation_id)` — полное сообщение с тремя секциями (🚨 / 🔍 / 🛠)
    - `notify_telegram_brief(incident, reason, vm_age=None)` — короткое уведомление при подавлении
    - `notify_telegram_correlation_update(correlation_id, incident)` — обновление при повышении severity
    - Экранирование спецсимволов для MarkdownV2 / HTML
    - Retry до 3 раз с экспоненциальным backoff (1s, 2s, 4s) только для HTTP ≥ 400
    - Блокировка отправки при отсутствии `incident.id`
    - Структурированный лог `event=notify_fail` при исчерпании retry
    - _Requirements: 3.1–3.7, 4.3_

  - [ ]* 8.2 Unit-тест: Telegram-сообщение содержит incident.id (P6)
    - **Property 6: Telegram message contains incident.id**
    - **Validates: Requirements 3.2**

- [ ] 9. Основной цикл (main.py) — оркестрация слоёв
  - [x] 9.1 Реализовать `main.py` — entry-point `sre_agent(cloud_event)`
    - Kill-switch проверка (`SRE_AGENT_ENABLED`)
    - Layer 1: Idempotency dedup
    - Layer 2: Suppression (Live Migration ±300s, bootstrap grace <1800s)
    - Layer 3: Correlation (same-kind 90s / cross-kind 180s)
    - Layer 4: gather + redact + token truncation + LLM (или fallback)
    - Layer 5: notify + persist
    - Структурированный лог `event=invocation` с `incident.id` и `kind`
    - Обработка `PROCESSING_TIMEOUT_SECONDS = 240` с partial fallback
    - Префикс `[budget exhausted]` при исчерпании бюджета
    - Префикс `[llm down: <reason>]` при ошибке LLM
    - _Requirements: 1.7, 4.1–4.4, 7.2, 7.3, 9.2–9.7, 10.1–10.3_

  - [ ]* 9.2 Unit-тест: suppression пропускает LLM при Live Migration и bootstrap grace (P11)
    - **Property 11: Suppression skips LLM during Live Migration / bootstrap grace**
    - **Validates: Requirements 9.2, 9.3**

- [x] 10. Checkpoint — Убедиться что полный цикл агента работает end-to-end
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 11. Terraform — инфраструктура агента
  - [x] 11.1 Добавить Pub/Sub topics в Terraform
    - Topic `sre-incidents` с `message_retention_duration = 86400s`
    - Topic `sre-incidents-dlq` как dead-letter destination
    - Notification channel типа `pubsub` для alert policies
    - _Requirements: 1.9_

  - [x] 11.2 Добавить service account и IAM-биндинги
    - SA `sre-agent` с ролями: `roles/logging.viewer`, `roles/monitoring.viewer`, `roles/datastore.user`, `roles/storage.objectViewer`, `roles/compute.viewer`, `roles/secretmanager.secretAccessor` (per-secret)
    - Явный запрет write-ролей
    - _Requirements: 6.1, 6.2, 6.3_

  - [x] 11.3 Добавить Cloud Function Gen2 `sre-agent` в Terraform
    - `runtime=python312`, `available_memory=512Mi`, `available_cpu=0.5`, `timeout_seconds=300`
    - `min_instance_count=0`, `max_instance_count=5`, `ingress_settings=ALLOW_INTERNAL_ONLY`
    - `secret_environment_variables` для LLM API key и Telegram token
    - Environment variables для всех настроек из `settings.py`
    - Event trigger на Pub/Sub topic `sre-incidents`
    - _Requirements: 4.5, 5.6, 7.1, 7.5_

  - [x] 11.4 Добавить log-based метрики (COS варианты) в Terraform
    - `postgres_fatal_cos` с `count` за `var.host_os`
    - `n8n_error_cos` с `count` за `var.host_os`
    - `oom_killed_cos` с `count` за `var.host_os`
    - Стабильные логические имена: `n8n/postgres_fatal`, `n8n/n8n_error`, `n8n/oom_killed`
    - _Requirements: 8.1, 8.2, 8.3_

  - [x] 11.5 Добавить alert policies в Terraform
    - `vm_cpu_high` (CPU > 0.85 за 180s)
    - `vm_memory_high` (OOM signal)
    - `postgres_fatal` (rate > 0 за 60s)
    - `n8n_error_spike` (rate > 5/min)
    - `external_unreachable` (uptime check < 50% за 180s)
    - Все policies → notification channel `sre_agent_pubsub`
    - _Requirements: 1.1–1.5_

  - [x] 11.6 Добавить uptime check `/healthz/deep` в Terraform
    - 4 региона, period 60s, timeout 10s, SSL validated
    - Alert policy на uptime fail
    - _Requirements: 8.7_

  - [x] 11.7 Добавить meta-метрики агента (log-based) в Terraform
    - `sre_agent/invocations_total`, `sre_agent/llm_latency_seconds`, `sre_agent/llm_tokens_total`
    - `sre_agent/llm_cost_usd_total`, `sre_agent/diagnosis_failed_total`
    - `sre_agent/suppressed_total` (label `reason`), `sre_agent/correlated_total`
    - `sre_agent/compute_api_calls_total` (label `cache_hit`)
    - Meta-алерт `sre-agent-health-degraded` (diagnosis_failed > 5 / 1h)
    - _Requirements: 7.4, 7.7, 7.8_

- [ ] 12. COS-профиль — sidecar и startup
  - [x] 12.1 Создать `scripts/startup_cos.sh` (или `cloud-config.yaml`)
    - Metadata `google-logging-enabled=true`, `google-monitoring-enabled=true`
    - Docker compose запуск с labels `container_name` и `logging.driver=json-file`
    - _Requirements: 8.4, 8.5_

  - [x] 12.2 Создать sidecar-контейнер `healthz-sidecar` и `healthz_server.py`
    - `/healthz` — bootstrap grace logic (200 в первые `BOOTSTRAP_WINDOW_SECONDS`)
    - `/healthz/deep` — три проверки: Postgres SELECT 1 < 1s, n8n REST < 2s, cloudflared running
    - HTTP 503 с JSON-телом при любом отказе (all-or-nothing)
    - `restart: unless-stopped` в compose
    - Port-mapping `127.0.0.1:8080:8080`
    - _Requirements: 8.6, 8.7, 8.8, 8.9_

  - [x] 12.3 Добавить COS instance template metadata в Terraform
    - Ключи `google-logging-enabled`, `google-monitoring-enabled`, `user-data`
    - Переключение через `var.host_os`
    - _Requirements: 8.4, 8.10_

- [x] 13. Checkpoint — Убедиться что Terraform валиден и все тесты проходят
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 14. Интеграционный тест и CI
  - [x] 14.1 Создать интеграционный тест `test_e2e_happy_path`
    - Полный цикл: Pub/Sub message → parse → context (mocked) → LLM (mocked) → Telegram (mocked) → Firestore (emulator)
    - Проверка корректности всей цепочки
    - _Requirements: 12.4_

  - [x] 14.2 Настроить pytest конфигурацию и CI (GitHub Actions)
    - pytest markers для property-based, unit, integration тестов
    - GitHub Actions workflow для автоматического запуска тестов
    - Блокировка merge при failing test
    - _Requirements: 12.1, 12.2, 12.3_

- [x] 15. Финальный checkpoint — Полная проверка
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Задачи с `*` — опциональные (тесты), могут быть пропущены для ускорения MVP
- Каждая задача ссылается на конкретные требования для трассируемости
- Checkpoints обеспечивают инкрементальную валидацию
- Property-тесты валидируют универсальные свойства корректности P1–P11
- Unit-тесты валидируют конкретные примеры и edge cases
- Язык реализации: Python 3.12 (как указано в design.md)
- Terraform используется для всей инфраструктуры GCP

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "1.4"] },
    { "id": 1, "tasks": ["1.2", "1.3"] },
    { "id": 2, "tasks": ["2.1", "2.3"] },
    { "id": 3, "tasks": ["2.2", "2.4", "2.5", "2.6"] },
    { "id": 4, "tasks": ["4.1", "4.2", "4.4", "4.5", "5.1"] },
    { "id": 5, "tasks": ["4.3", "5.2", "5.3"] },
    { "id": 6, "tasks": ["5.4", "6.1"] },
    { "id": 7, "tasks": ["6.2", "6.3", "6.4"] },
    { "id": 8, "tasks": ["6.5", "8.1"] },
    { "id": 9, "tasks": ["8.2", "9.1"] },
    { "id": 10, "tasks": ["9.2", "11.1", "11.2"] },
    { "id": 11, "tasks": ["11.3", "11.4", "11.5"] },
    { "id": 12, "tasks": ["11.6", "11.7", "12.1"] },
    { "id": 13, "tasks": ["12.2", "12.3"] },
    { "id": 14, "tasks": ["14.1", "14.2"] }
  ]
}
```
