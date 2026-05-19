# Requirements Document

**Feature:** SRE-агент авто-диагностики (`sre-agent-auto-diagnostics`)

> Документ выведен из `design.md` (Design-First). Дизайн является авторитативным источником: эти требования формализуют то, что зафиксировано в архитектуре. Любое расхождение разрешается в пользу `design.md`.
>
> **Связи:** требования ссылаются на свойства корректности **P1–P11** (раздел `Correctness Properties` в `design.md`) и на лог решений **Q1–Q15** (раздел `Open Questions / Decision Log`).

## Introduction

Текущая инфраструктура (`gcp-self-healing-infra`) уже умеет автоматически восстанавливать VM через Regional MIG + HealthCheck. Это инфра-уровневое самовосстановление отвечает на вопрос «что сломалось» (упало → пересоздали), но не отвечает на «почему», «насколько плохо» и «что делать оператору в 03:00, кроме как ждать MIG».

SRE-агент авто-диагностики — диагностический мозг поверх существующего инфра-хила: он подписывается на сигналы Cloud Monitoring, собирает контекст (логи `n8n` / `postgres` / `cloudflared` за окно перед инцидентом, host-метрики, внешний пробинг), редактирует секреты, отдаёт контекст LLM и возвращает структурированный диагноз (гипотеза root-cause + подсказка фикса) в существующий Telegram-бот. Агент работает off-host (Cloud Functions Gen2, scale-to-zero), не имеет ни одной write-роли, не может выполнять destructive-команды, и поэтому ортогонален MIG-самохилу и SLO burn-rate алертам.

MVP покрывает 4+1 классов сигналов (CPU sustained, OOM/Memory, Postgres FATAL/PANIC, n8n ERROR / restart-loop, External Unreachability), укладывается в GCP Free Tier по compute, и оставляет под собственным управлением только бюджет токенов LLM (целевой потолок — `LLM_BUDGET_USD_PER_DAY=2.00`). Стек должен поддерживать как Ubuntu (текущий прод), так и Container-Optimized OS (COS) — single agent, два ОС-профиля.

## Glossary

- **SRE-агент** / **Агент** — Cloud Function Gen2 `sre-agent`, единая точка приёма инцидентов из Pub/Sub topic `sre-incidents`. Off-host, scale-to-zero, IAM read-only.
- **Инцидент (Incident)** — одно событие из Cloud Monitoring или внешнего health-check'а, нормализованное парсером `parse_alert` в Pydantic-модель с полями `id`, `kind`, `severity`, `started_at`, `resource`, `raw_payload`.
- **Сигнал (Signal)** — единица контекста, собранная агентом для конкретного инцидента: лог-строки (`n8n_error`, `pg_fatal`, `cf_5xx`), метрики (`cpu`, `mem`), результат внешнего пробинга (`external_probe`).
- **Диагноз (Diagnosis)** — JSON-структура, возвращаемая LLM или fallback'ом: `{hypothesis, evidence_refs, confidence ∈ {low, medium, high}, suggested_fix, suggested_command}`.
- **Дедуп (Idempotency dedup)** — защита от повторной обработки одного и того же `incident.id` в окне TTL = 1 час (Firestore document `incidents/{id}`).
- **Окно корреляции (Correlation window)** — два окна с разной шириной для multi-signal incident'ов. **Same-kind**: `CORRELATION_WINDOW_SEC = 90` s — повторные burst'ы того же `kind` от одного ресурса (`resource.vm` или `resource.public_host`) сливаются в один incident-window и обрабатываются одним LLM-вызовом. **Cross-kind**: `CROSS_KIND_CORRELATION_WINDOW_SEC = 180` s — разные `kind` одного ресурса (например, downstream cascade `pg_fatal → n8n_error`, который физически разнесён на 2–3 минуты из-за connection-pool timeout'ов) сливаются в тот же incident-window. Оба значения биндятся в `Settings` Pydantic-модели через env-переменные.
- **Подавление (Suppression)** — отказ от вызова LLM, когда сигнал заведомо false-positive: Live Migration в окне ±300 s от инцидента или возраст инстанса < `BOOTSTRAP_GRACE_SECONDS`.
- **Грейс (Bootstrap grace)** — окно `BOOTSTRAP_GRACE_SECONDS = 1800` s (синхронизировано с MIG `initial_delay_sec`), внутри которого алерты `external_unreachable` и `n8n_error` подавляются как ожидаемое поведение startup'а.
- **Live Migration** — событие GCP `compute.instances.migrateOnHostMaintenance` или `compute.instances.hostError`; в окне ±`LIVE_MIGRATION_WINDOW_SEC = 300` s агент подавляет шумные сигналы.
- **External probe** — функция `probe_external_reachability(host)` в `context.py`: фазы DNS / TCP:443 / HTTPS root / HTTPS `/healthz/deep` со своими timeout (5 / 5 / 10 / 10 s), всегда возвращает `dict`.
- **Redact (Редакция)** — функция `redact(text)` поверх таблицы `SECRET_PATTERNS` (email, Bearer, JWT, postgres URL, password=…); применяется к каждой evidence-строке перед отправкой в LLM.
- **Untrusted log** — обёртка `<untrusted_log>...</untrusted_log>` в user-prompt'е, инструктирующая LLM трактовать содержимое строго как данные, а не как инструкции (защита от prompt-injection).
- **Rule-based fallback** — детерминистический классификатор `rule_based_diagnose` в `rules.py`, используется при отказе LLM или исчерпании дневного бюджета токенов; всегда возвращает `confidence=low`.
- **Kill-switch** — env-переменная `SRE_AGENT_ENABLED` (default `true`); при `false` функция возвращает `"disabled"` без побочных эффектов.
- **ОС-профиль** — конфигурация stack'а под конкретную ОС VM: `Ubuntu` (Ops Agent logging-only) или `COS` (built-in fluent-bit, sidecar `healthz-sidecar`, COS-варианты log-based метрик без зависимости от severity).
- **Гетерогенный фильтр** — Cloud Logging filter в `get_logs`, матчящий одновременно `labels."container_name"=X` (Ubuntu) и `jsonPayload.container.name=X` (COS), чтобы агентский код был ОС-инвариантным.
- **Pluggable LLM provider** — переключение между `gemini` (default), `claude`, `openai` через env `LLM_PROVIDER` без изменений кода-вызывающего слоя (`analyze_with_llm`).

## Requirements

### Requirement 1: Реакция на 4+1 классов сигналов

**User Story:** Как on-call SRE, я хочу, чтобы агент реагировал на унифицированный набор инцидент-сигналов (CPU / Memory / Postgres / n8n / External), чтобы все production-классы инцидентов автоматически попадали в Telegram с диагнозом, а не только подмножество.

#### Acceptance Criteria

1. КОГДА в Cloud Monitoring срабатывает alert policy `vm_cpu_high` (`compute.googleapis.com/instance/cpu/utilization > 0.85` за 180 s), ТО SRE-агент ДОЛЖЕН принять инцидент с `kind="cpu"`, `severity="warning"` и собрать контекст за окно `LOG_LOOKBACK_MINUTES = 5`.
2. КОГДА в Cloud Monitoring срабатывает alert policy `vm_memory_high` (log-based метрика `n8n/oom_killed > 0` за 60 s), ТО SRE-агент ДОЛЖЕН принять инцидент с `kind="mem"` и пометить `severity="critical"`.
3. КОГДА в Cloud Monitoring срабатывает alert policy `postgres_fatal` (log-based метрика `n8n/postgres_fatal > 0` за 60 s), ТО SRE-агент ДОЛЖЕН принять инцидент с `kind="pg_fatal"` и `severity="critical"`.
4. КОГДА в Cloud Monitoring срабатывает alert policy `n8n_error_spike` (log-based метрика `n8n/n8n_error > 5` за 60 s ИЛИ ресет `compute.googleapis.com/instance/uptime`), ТО SRE-агент ДОЛЖЕН принять инцидент с `kind="n8n_error"` и `severity="warning"`.
5. КОГДА в Cloud Monitoring срабатывает alert policy `external_unreachable` (uptime check `/healthz/deep` < 50% зондов OK за 180 s), ТО SRE-агент ДОЛЖЕН принять инцидент с `kind="external_unreachable"` и `severity="critical"`.
6. КОГДА один и тот же payload Cloud Monitoring подаётся в `parse_alert` многократно, ТО парсер ДОЛЖЕН возвращать `Incident`, у которого поля `id`, `source`, `severity`, `kind`, `started_at`, `resource` побайтно равны между вызовами; поле `raw_payload` ДОЛЖНО содержать те же ключи и значения, что и исходный payload, без зависимости от порядка ключей в JSON-сериализации (детерминизм по deep-equality модели, modulo упорядочение `raw_payload`). _**Validates: Requirement 1.1 (P3)**_
7. ЕСЛИ payload не содержит обязательного поля `incident.incident_id` ИЛИ `incident.policy_name`, ТО SRE-агент ДОЛЖЕН вернуть строку `"bad_payload"` и не выполнять никаких побочных действий (LLM, Telegram, Firestore-запись, Cloud Logging API чтение); обработка (context collection и прочие шаги) МОЖЕТ продолжаться до момента обнаружения отсутствующего поля, после чего ДОЛЖНА быть прекращена; `"bad_payload"` возвращается ТОЛЬКО при отсутствии `incident_id` или `policy_name`, а не при иных ошибках валидации.
8. КОГДА новый класс сигналов добавляется в Phase ≥ 2 (например, `cf_5xx` через Cloudflare Logpush), ТО архитектура парсинга и context-gathering ДОЛЖНА позволять расширение перечисления `kind` без модификации существующих обработчиков `cpu | mem | pg_fatal | n8n_error | external_unreachable`; расширение ДОЛЖНО реализовываться через registry-паттерн (dict `KIND_HANDLERS: dict[str, Callable]`), где новый kind добавляется регистрацией handler'а без изменения dispatch-логики.
9. ГДЕ создаётся Pub/Sub topic `sre-incidents`, ТАМ ДОЛЖЕН быть установлен `message_retention_duration = 86400` секунд (1 день), и ДОЛЖЕН существовать parallel topic `sre-incidents-dlq` как dead-letter destination для сообщений, исчерпавших политику ретраев Eventarc.

### Requirement 2: Сбор контекста (логи + метрики + external probe)

**User Story:** Как on-call SRE, я хочу, чтобы вместе с инцидентом агент автоматически приносил мне последние 100 строк логов n8n и postgres за окно 5 минут до сбоя плюс host-метрики, чтобы LLM имел реальный материал для root-cause анализа, а не только заголовок алерта.

#### Acceptance Criteria

1. КОГДА агент обрабатывает любой инцидент, ТО `gather_context` ДОЛЖЕН запросить из Cloud Logging до `LOG_LINES_PER_CONTAINER = 100` строк лога каждого из контейнеров `n8n` и `postgres` за окно `LOG_LOOKBACK_MINUTES = 5` минут перед `incident.started_at`.
2. КОГДА агент обрабатывает любой инцидент, ТО `gather_context` ДОЛЖЕН запросить временной ряд метрики `compute.googleapis.com/instance/cpu/utilization` за то же окно через Monitoring API.
3. КОГДА VM использует ОС-профиль Ubuntu, ТО фильтр `get_logs` ДОЛЖЕН матчить контейнер по полю `labels."container_name"`.
4. КОГДА VM использует ОС-профиль COS, ТО фильтр `get_logs` ДОЛЖЕН матчить контейнер по полю `jsonPayload.container.name`.
5. ГДЕ применяется единый код агента для гетерогенного парка Ubuntu+COS, ТАМ фильтр `get_logs` ДОЛЖЕН использовать дизъюнкцию обоих условий из критериев 2.3 и 2.4 в одном выражении.
6. КОГДА `incident.kind == "external_unreachable"`, ТО `gather_context` ДОЛЖЕН дополнительно вызвать `probe_external_reachability(host)` и `get_cloudflared_logs(...)`.
7. КОГДА вызывается `probe_external_reachability(host)`, ТО функция ДОЛЖНА выполнить четыре фазы строго последовательно (DNS → TCP/443 → HTTPS root → HTTPS `/healthz/deep`) с индивидуальными таймаутами 5 + 5 + 10 + 10 секунд; параллельное выполнение фаз НЕ ДОПУСКАЕТСЯ; общий wall-clock завершения ДОЛЖЕН быть ≤ 30 секунд при любом исходе каждой фазы (success / timeout / exception); функция ДОЛЖНА всегда возвращать `dict` (исключения наружу не пробрасываются). _**Validates: Requirement 8.1 (P9)**_
8. ЕСЛИ любая фаза external probe (DNS / TCP / HTTP root / deep) завершается ошибкой или таймаутом, ТО соответствующее поле `*_ok=false` и `*_error=...` ДОЛЖНО быть зафиксировано в результирующем `dict`, последующие фазы ДОЛЖНЫ запуститься независимо от исхода предыдущих (в том числе при одновременном отказе нескольких фаз), и обработка инцидента ДОЛЖНА продолжиться с частичным контекстом только после завершения всех четырёх фаз.
9. ЕСЛИ Cloud Logging API возвращает throttle / 5xx / timeout, ТО агент ДОЛЖЕН продолжить обработку инцидента с теми логами, что успели собраться до ошибки (partial logs), и зафиксировать `partial=true` и `partial_reason=<описание>` в `evidence_refs` итогового `Diagnosis`; обработка инцидента (context gathering, LLM/fallback, Telegram) продолжается с неполным контекстом.

### Requirement 3: Структурированный диагноз в Telegram

**User Story:** Как on-call SRE, я хочу получать в Telegram структурированное сообщение «🚨 что случилось / 🔍 root cause гипотеза / 🛠 что делать», содержащее `incident.id` для трассировки, чтобы за 60 секунд понять масштаб инцидента и иметь конкретный следующий шаг.

#### Acceptance Criteria

1. КОГДА агент завершает анализ инцидента (через LLM или rule-based fallback), ТО он ДОЛЖЕН отправить ровно одно сообщение в Telegram с тремя секциями в фиксированном порядке: `🚨 <kind / severity / resource>` (что произошло), `🔍 <hypothesis с цитатой evidence>` (root-cause гипотеза), `🛠 <suggested_fix> [+ опционально <suggested_command> в моноширинном блоке]` (что делать).
2. КАЖДОЕ сообщение, отправленное в Telegram SRE-агентом, ДОЛЖНО содержать строку `incident.id` в текстовом теле для последующей трассировки в Cloud Logging и Firestore; ЕСЛИ `incident.id` отсутствует или malformed, ТО сообщение ДОЛЖНО быть заблокировано (не отправлено) и залогировано как `event=notify_blocked reason=missing_incident_id`. _**Validates: Requirement 3.1 (P6)**_
3. КОГДА агент обрабатывает инцидент в нормальном режиме (LLM доступен, бюджет не исчерпан, suppression не сработал), ТО end-to-end p95 latency «алерт принят функцией → сообщение успешно отправлено в Telegram (HTTP 200 от Bot API)» ДОЛЖНА быть ≤ 60 секунд, измеренная по rolling-window 7 дней по сумме meta-метрик `sre_agent/llm_latency_seconds + sre_agent/notify_latency_seconds`; инвокации, помеченные структурированным полем `cold_start=true` в логе, ИСКЛЮЧАЮТСЯ из расчёта p95 как outlier'ы холодного запуска.
4. ЕСЛИ Telegram Bot API возвращает HTTP-ошибку (статус ≥ 400), ТО агент ДОЛЖЕН выполнить до 3 retry с экспоненциальным backoff (1 s, 2 s, 4 s); retry выполняется ТОЛЬКО для HTTP-ошибок (≥ 400 status codes); сетевые timeout'ы и ошибки парсинга JSON-ответа НЕ ДОЛЖНЫ вызывать retry; ЕСЛИ все 3 попытки завершились неуспехом, ТО агент ДОЛЖЕН залогировать структурированное событие `event=notify_fail incident_id=<id> last_error=<...>` (источник для meta-алерта `sre-agent-notify-fail`); альтернативные каналы уведомления (email, Slack) НЕ используются — только логирование.
5. КОГДА сработало подавление (Live Migration или bootstrap grace), ТО агент ДОЛЖЕН отправить **короткое** уведомление в Telegram (`🔄 Подавлено: live migration` или `🛠 Подавлено: bootstrap grace, vm_age=<N>s`), включающее `incident.id`, чтобы оператор знал, что агент видел сигнал и сознательно его проигнорировал.
6. КОГДА сработала корреляция (новый сигнал попал в существующее incident-window), ТО агент НЕ ДОЛЖЕН отправлять отдельное Telegram-сообщение для co-сигнала уровня `severity != critical`; обновление сообщения допустимо только при повышении severity до `critical` (повышение фиксируется в Firestore-документе window'а в поле `severity`).
7. КОГДА сообщение отправляется в Telegram, ТО все динамические подстановки (`hypothesis`, `suggested_command`, evidence-цитаты, имена ресурсов) ДОЛЖНЫ экранироваться по правилам выбранного режима форматирования Telegram Bot API (MarkdownV2 или HTML), чтобы спецсимволы из логов не ломали разметку и не интерпретировались как форматирующие control-токены.

### Requirement 4: Контроль стоимости и шумоподавления

**User Story:** Как владелец проекта на GCP Free Tier, я хочу, чтобы агент имел жёсткий потолок на дневные расходы LLM и не запускал LLM повторно для дубликатов и для серий связанных сигналов одного инцидента, чтобы один storm алертов не пробивал бюджет за день.

#### Acceptance Criteria

1. КОГДА в окне TTL = 1 час уже был обработан инцидент с тем же `incident.id` (Firestore документ `incidents/{id}` существует и не истёк), ТО агент ДОЛЖЕН вернуть `"duplicate"` и НЕ ДОЛЖЕН: вызывать LLM, отправлять в Telegram любое сообщение (даже короткое суппресс-формата), записывать новый `Diagnosis` в коллекцию `diagnoses`, обновлять Firestore-документ — кроме служебного поля `last_seen_at` для аудита частоты дубликатов. _**Validates: Requirement 4.1 (P4)**_
2. КОГДА суммарная стоимость LLM-вызовов за текущий календарный день (UTC) уже больше или равна `LLM_BUDGET_USD_PER_DAY` (default `$2.00`), ТО агент ДОЛЖЕН использовать rule-based fallback и НЕ ДОЛЖЕН вызывать LLM. _**Validates: Requirement 4.2 (P5)**_
3. КОГДА срабатывает корреляция (см. требование 9), ТО для всех co-сигналов одного incident-window ДОЛЖЕН быть выполнен ровно один LLM-вызов; остальные сигналы ДОЛЖНЫ записываться как evidence в существующий window-документ.
4. КОГДА агент работает в режиме budget-exhausted fallback (LLM фактически не вызывается из-за исчерпания бюджета), ТО `Diagnosis.hypothesis` ДОЛЖЕН начинаться с префикса `[budget exhausted]` для прозрачности перед оператором; при исчерпании бюджета все LLM-вызовы ЗАПРЕЩЕНЫ — используется только rule-based fallback; префикс добавляется ТОЛЬКО когда LLM фактически обойдён из-за бюджетных ограничений.
5. ГДЕ конфигурируется Cloud Function `sre-agent` через `service_config.max_instance_count`, ТАМ значение ДОЛЖНО быть равно `5`, и enforcement параллелизма ДОЛЖЕН выполняться платформой Cloud Run / Cloud Functions Gen2 на уровне service-config, а не application-кодом; рост числа сообщений в Pub/Sub сверх лимита ДОЛЖЕН откладываться в очереди (с retention `86400` s, см. требование 1.9), а не приводить к параллельному порождению дополнительных инстансов агента.
6. КОГДА агент логирует событие `event=llm_call`, ТО лог ДОЛЖЕН содержать поля `tokens_in`, `tokens_out`, `cost_usd`, `provider`, `model` для агрегации в meta-метрику `sre_agent/llm_cost_usd_total`.

### Requirement 5: Безопасность данных и редакция

**User Story:** Как security-ответственный, я хочу, чтобы перед отправкой в внешний LLM-провайдер агент удалял секреты и PII из логов и был защищён от prompt-injection, чтобы случайный JWT в лог-строке n8n не утекал к Gemini / Claude / OpenAI.

#### Acceptance Criteria

1. КОГДА `redact(s)` применяется к произвольной строке `s`, ТО в выводе НЕ ДОЛЖЕН матчиться ни один паттерн из `SECRET_PATTERNS` (email, `Bearer <token>`, JWT `eyJ...`, `postgres://creds@host/db`, `password=...`). _**Validates: Requirement 5.1 (P1)**_
2. КОГДА `redact(s)` применяется повторно к уже редактированной строке, ТО результат ДОЛЖЕН быть равен результату первого применения: `redact(redact(s)) == redact(s)`. _**Validates: Requirement 5.2 (P2)**_
3. КОГДА агент формирует user-prompt для LLM, ТО блок логов ДОЛЖЕН быть обёрнут в теги `<untrusted_log>...</untrusted_log>`, а system-prompt ДОЛЖЕН явно инструктировать LLM не следовать инструкциям из этих тегов.
4. КОГДА `redact(s)` применяется к строке `s`, ТО длина результата ДОЛЖНА удовлетворять `len(redact(s)) ≤ len(s) + 1024`. _**Validates: Requirement 7.1 (P8)**_
5. ГДЕ конфигурируется редакция IPv4-адресов, ТАМ её toggle ДОЛЖЕН реализовываться через явную env-переменную `REDACT_IPV4` (значения `"true"` или `"false"`, default `"false"`); при `REDACT_IPV4="true"` паттерн `(?:\d{1,3}\.){3}\d{1,3}` ДОЛЖЕН быть включён в `SECRET_PATTERNS`, при `"false"` — исключён, чтобы не мешать диагностике DDoS / unreachable (см. Q8).
6. КОГДА секреты передаются в Cloud Function (LLM API key, Telegram token), ТО они ДОЛЖНЫ быть смонтированы только через `secret_environment_variables` из Secret Manager; хранение секретов в plain-text в коде или лог-строках НЕ ДОПУСКАЕТСЯ; после извлечения из Secret Manager хранение в памяти процесса ДОПУСКАЕТСЯ.

### Requirement 6: Read-only blast radius и rule-based fallback

**User Story:** Как security-ответственный, я хочу, чтобы service account агента физически не мог выполнить ни одной destructive-операции в проекте, и чтобы любой fallback-диагноз честно помечался как `confidence=low`, чтобы оператор понимал степень уверенности.

#### Acceptance Criteria

1. ГДЕ выдаются IAM-роли service-account'у `sre-agent`, ТАМ роли ДОЛЖНЫ быть только из read-only набора: `roles/logging.viewer`, `roles/monitoring.viewer`, `roles/datastore.user`, `roles/storage.objectViewer` (на bucket `*-cloudflare-logs`), `roles/compute.viewer`, и `roles/secretmanager.secretAccessor` per-secret для `sre-agent-llm-key` и `telegram-bot-token`; любые write-роли (включая `roles/logging.logWriter`, `roles/monitoring.metricWriter`, `roles/datastore.owner`) ЯВНО ЗАПРЕЩЕНЫ для данного service-account.
2. ГДЕ конфигурируется service-account `sre-agent`, ТАМ НЕ ДОЛЖНО быть ни одной из ролей: `roles/editor`, `roles/owner`, `compute.instanceAdmin*`, `iam.*`, `compute.instances.*` (write), любых ролей с правом записи в Cloud Logging / Cloud Monitoring.
3. ГДЕ описаны действия агента в MVP (Phase 1), ТАМ запрещены к исполнению агентом следующие destructive-операции (исчерпывающий список): `docker restart`, `docker stop`, `docker kill`, `docker rm`, `pg_terminate_backend`, `pg_cancel_backend`, `ALTER TABLE`, `DROP TABLE`, `DELETE`, `UPDATE`, `TRUNCATE`, `compute.instances.reset`, `compute.instances.stop`, `compute.instances.delete`, `compute.instanceGroupManagers.recreateInstances`, `iam.serviceAccountKeys.create`, любые SSH-команды через IAP-туннель; все перечисленные операции — явная цель Phase 5 с human-in-the-loop confirmation через Telegram inline-кнопки.
4. КОГДА LLM-провайдер возвращает 5xx / timeout / невалидный JSON / schema-несовместимый JSON, ТО агент ДОЛЖЕН использовать `rule_based_diagnose` и пометить `Diagnosis.hypothesis` префиксом `[llm down: <reason>]`; при этом повторные попытки LLM-вызова ДОПУСКАЮТСЯ параллельно с подготовкой rule-based fallback.
5. КОГДА агент возвращает `Diagnosis` с `model == "rule-based-v1"`, ТО `Diagnosis.confidence` ДОЛЖЕН быть равен `"low"` (никогда `medium` / `high`). _**Validates: Requirement 6.1 (P7)**_

### Requirement 7: Free Tier совместимость и observability агента

**User Story:** Как владелец проекта на Free Tier, я хочу, чтобы сама инфраструктура агента работала в бесплатных лимитах (compute, Pub/Sub, Firestore, Logging), имела meta-метрики для собственной диагностики и kill-switch для аварийного отключения, чтобы baseline-стоимость агента оставалась $0/мес.

#### Acceptance Criteria

1. ГДЕ задаются параметры Cloud Function `sre-agent`, ТАМ они ДОЛЖНЫ быть: `runtime=python312`, `available_memory=512Mi`, `available_cpu=0.5`, `timeout_seconds=300`, `min_instance_count=0`, `max_instance_count=5`, `ingress_settings=ALLOW_INTERNAL_ONLY`.
2. ПОКА env-переменная `SRE_AGENT_ENABLED` равна `"false"`, СИСТЕМА ДОЛЖНА сразу возвращать `"disabled"` из entry-point, не выполняя ни одного запроса к Cloud Logging / Cloud Monitoring / LLM / Telegram / Firestore.
3. КОГДА Cloud Function вызывается через триггер Pub/Sub topic `sre-incidents`, ТО агент ДОЛЖЕН логировать структурированное событие `event=invocation` с `incident.id` и `kind` для агрегации в meta-метрику `sre_agent/invocations_total`.
4. ГДЕ определяются meta-метрики агента, ТАМ ДОЛЖНЫ существовать как минимум: `sre_agent/invocations_total`, `sre_agent/llm_latency_seconds`, `sre_agent/llm_tokens_total`, `sre_agent/llm_cost_usd_total`, `sre_agent/diagnosis_failed_total`, `sre_agent/suppressed_total` (с label `reason`), `sre_agent/correlated_total`; КАЖДАЯ метрика ДОЛЖНА быть log-based (Cloud Logging derived metric) с `metric_kind=DELTA`, `value_type=INT64` для счётчиков (`invocations_total`, `llm_tokens_total`, `diagnosis_failed_total`, `suppressed_total`, `correlated_total`) или `value_type=DOUBLE` для распределений (`llm_latency_seconds`, `llm_cost_usd_total`); filter expression каждой метрики ДОЛЖНО ссылаться на структурированные поля JSON-логов функции (`event=invocation`, `event=llm_call`, `event=suppressed`, `event=correlated`, `event=diagnosis_failed`) согласно сводке meta-observability в `design.md`.
5. ГДЕ работает Cloud Function `sre-agent`, ТАМ `vpc_connector_egress_settings` НЕ ДОЛЖЕН быть установлен в `ALL_TRAFFIC`, чтобы external probe мог использовать публичный DNS и публичный edge через managed NAT.
6. КОГДА существуют дашборды мониторинга, ТО рядом с тайлом `n8n_slo` ДОЛЖЕН быть тайл `SRE-agent invocations / latency / cost / failures / suppressed / correlated`.
7. ЕСЛИ за скользящее окно 60 минут значение `sre_agent/diagnosis_failed_total` превысило 5, ТО ДОЛЖЕН срабатывать meta-алерт `sre-agent-health-degraded` (low priority, email + slack); окно является rolling (может срабатывать многократно); ручное подавление алерта во время maintenance windows НЕ ДОПУСКАЕТСЯ — алерт всегда обязателен; резервный механизм оповещения при отказе основной системы алертинга НЕ ТРЕБУЕТСЯ — используется единственный механизм Cloud Monitoring alerting.
8. ГДЕ определяются meta-метрики агента, ТАМ ДОЛЖНА существовать meta-метрика `sre_agent/compute_api_calls_total` с label `cache_hit ∈ {"true","false"}`, log-based из структурированного события `event=compute_api_call cache_hit=<true|false>`, `metric_kind=DELTA`, `value_type=INT64`. Метрика ДОЛЖНА фиксировать каждый вызов `instance_age_seconds_cached(...)` и распознавать, был ли он обслужен из in-memory TTL-кэша (`cache_hit=true`) или потребовал реальный вызов Compute API (`cache_hit=false`); используется для visibility TTL-кэша на `creation_timestamp` lookups, защищающего Compute API от throttling в alert storm. _**Validates: Requirement 7 (Compute API cache observability)**_

### Requirement 8: Поддержка двух ОС-профилей (Ubuntu + COS)

**User Story:** Как платформенный инженер, я хочу, чтобы один и тот же код агента и алерт-полиси работали с обеими ОС VM (Ubuntu с Ops Agent и COS со встроенным fluent-bit) без модификации логики LLM/Telegram/Firestore, чтобы миграция MIG instance template на COS не ломала диагностику.

#### Acceptance Criteria

1. КОГДА VM использует ОС-профиль `cos` (`var.host_os == "cos"`), ТО Terraform ДОЛЖЕН разворачивать COS-варианты log-based метрик (`postgres_fatal_cos`, `n8n_error_cos`, `oom_killed`) с фильтрами на `jsonPayload.container.name` и `textPayload`/`jsonPayload.log` без зависимости от поля `severity`.
2. КОГДА VM использует ОС-профиль `ubuntu`, ТО Terraform ДОЛЖЕН разворачивать Ubuntu-варианты log-based метрик с фильтрами на `labels."container_name"` и `severity>=ERROR`.
3. ГДЕ Terraform определяет два набора ресурсов log-based метрик (Ubuntu и COS), ТАМ переключение ДОЛЖНО реализовываться через атрибут `count` каждого `google_logging_metric`, выводимый из `var.host_os`: ровно один набор активен (`count = 1`) в каждый момент времени, второй неактивен (`count = 0`); при `var.host_os == "ubuntu"` активны Ubuntu-метрики и неактивны COS-метрики, при `var.host_os == "cos"` — наоборот; alert policies ДОЛЖНЫ ссылаться на стабильное логическое имя метрики (`n8n/postgres_fatal`, `n8n/n8n_error`, `n8n/oom_killed`) и НЕ ДОЛЖНЫ зависеть от `count`-флага.
4. ГДЕ задаётся instance metadata MIG instance template для COS, ТАМ ДОЛЖНЫ присутствовать ключи `google-logging-enabled = "true"`, `google-monitoring-enabled = "true"`, `user-data` (cloud-init / `scripts/startup_cos.sh`).
5. ГДЕ задаются compose-сервисы на COS (`n8n`, `postgres`, `cloudflared`, `healthz-sidecar`), ТАМ КАЖДЫЙ сервис ДОЛЖЕН иметь label `container_name: "<имя>"` и `logging.driver = "json-file"` с `max-size: "10m"`, `max-file: "3"`.
6. ГДЕ запускается health-server `/healthz/deep` на COS, ТАМ ДОЛЖЕН быть отдельный sidecar-контейнер `healthz-sidecar` (не systemd unit и не `nohup` из cloud-init), подключённый к docker network того же compose, с port-mapping `127.0.0.1:8080:8080`; сервис ДОЛЖЕН иметь `restart: unless-stopped` в compose, чтобы его падение не приводило к ложным `external_unreachable` алертам.
7. КОГДА health-server `/healthz/deep` отвечает, ТО он ДОЛЖЕН проверить три условия: `Postgres SELECT 1` за < 1 s, n8n REST `/rest/active-workflows` за < 2 s, контейнер `cloudflared` в state `running` (а не в restart-loop); HTTP 200 возвращается ТОЛЬКО когда все три условия выполнены.
8. ЕСЛИ хотя бы одно из трёх условий из 8.7 не выполнено (включая временную медленность Postgres во время backup), ТО `/healthz/deep` ДОЛЖЕН вернуть HTTP 503 с JSON-телом, идентифицирующим какая проверка упала; проверка строгая (all-or-nothing) — частичная деградация любого компонента ПРИНУДИТЕЛЬНО приводит к 503, независимо от состояния остальных проверок.
9. ГДЕ существует bootstrap-grace окно для `/healthz` (не `/healthz/deep`), ТАМ окно ДОЛЖНО быть настраиваемо через env (`BOOTSTRAP_WINDOW_SECONDS`) и значение по умолчанию ДОЛЖНО совпадать с MIG `initial_delay_sec` (1800 s) — см. Q14.
10. ГДЕ `Incident.kind` маршрутизирует логику агента, ТАМ код ДОЛЖЕН быть инвариантным к ОС-профилю VM: переключение Ubuntu↔COS не требует изменения `main.py`, `alerts.py`, `llm.py`, `notify.py`, `store.py`, `redact.py`.

### Requirement 9: Корреляция и подавление multi-signal инцидентов

**User Story:** Как on-call SRE, я хочу, чтобы для одного инцидента, проявляющегося одновременно через несколько сигналов (например, OOM + n8n_error + external_unreachable), агент посылал мне один диагноз, а не три, и чтобы нормальные maintenance-события (Live Migration, MIG bootstrap) не превращались в шквал ложных срабатываний.

#### Acceptance Criteria

1. КОГДА два сигнала с одинаковым ключом ресурса (`resource.vm` ИЛИ `resource.public_host`) попадают в окно корреляции, ТО агент ДОЛЖЕН выполнить ровно один LLM-вызов и записать co-сигнал в существующий incident-window-документ Firestore коллекции `incident_windows` через атомарное обновление полей `co_signals` (через `ArrayUnion([incident.kind])`), `last_signal_at` (= `incident.started_at`) и `incident_ids` (через `ArrayUnion([incident.id])`) внутри Firestore Transaction (для защиты от race condition при параллельных инстансах); window-документ ДОЛЖЕН оставаться открытым до 30 минут с момента создания (поле `opened_at`). Окно зависит от того, совпадает ли `kind`:
   - **(a) Same-kind:** ЕСЛИ `incident.kind == window.primary_kind`, ТО окно ≤ `CORRELATION_WINDOW_SEC = 90` секунд (same-kind dedup для повторных burst'ов одного типа сигнала).
   - **(b) Cross-kind:** ЕСЛИ `incident.kind != window.primary_kind`, ТО окно ≤ `CROSS_KIND_CORRELATION_WINDOW_SEC = 180` секунд (cross-kind cascade). Большее окно отражает физическую задержку downstream-каскадов: типичный пример `pg_fatal` срабатывает в `t=0`, а вызванный им `n8n_error` появляется через 2–3 мин — после connection-pool timeout'а и провала первых workflow. _**Validates: Requirement 9.1 (P10)**_
2. ЕСЛИ в момент инцидента `incident.kind ∈ {external_unreachable, n8n_error, cpu, mem}` Cloud Logging содержит событие `compute.instances.migrateOnHostMaintenance` ИЛИ `compute.instances.hostError` в окне ±`LIVE_MIGRATION_WINDOW_SEC = 300` s от `incident.started_at`, ТО агент ДОЛЖЕН вернуть `"suppressed_live_migration"` и НЕ ДОЛЖЕН вызывать LLM. _**Validates: Requirement 9.2 (P11)**_
3. ЕСЛИ в момент инцидента `incident.kind ∈ {external_unreachable, n8n_error}` возраст инстанса (`now - creation_timestamp`) меньше `BOOTSTRAP_GRACE_SECONDS = 1800` s, ТО агент ДОЛЖЕН вернуть `"suppressed_bootstrap_grace"` и НЕ ДОЛЖЕН вызывать LLM; `incident.kind == "pg_fatal"` ИСКЛЮЧЁН из bootstrap grace подавления — PG_FATAL всегда обрабатывается как реальный инцидент (согласно AC 9.6). _**Validates: Requirement 9.2 (P11)**_
4. КОГДА срабатывает любое подавление, ТО агент ДОЛЖЕН залогировать структурированное событие `event=suppressed reason=<live_migration|bootstrap_grace>` для агрегации в meta-метрику `sre_agent/suppressed_total`; подавление ДОЛЖНО продолжиться даже если логирование события завершилось ошибкой.
5. ГДЕ применяется priority matrix для co-firing сигналов одного incident-window, ТАМ canonical `kind` ДОЛЖЕН выбираться по тотальной упорядоченности (от сильнейшего к слабейшему): `pg_fatal > mem > cpu > external_unreachable > n8n_error`; при N ≥ 2 co-firing сигналах canonical kind ДОЛЖЕН быть максимумом из присутствующих kind'ов по этой упорядоченности, а все остальные kind'ы ДОЛЖНЫ быть записаны как evidence в массив `co_signals` Firestore-документа окна; правила `external_unreachable + pg_fatal → pg_fatal`, `external_unreachable + mem → mem`, `external_unreachable + cpu → cpu`, `external_unreachable + n8n_error → external_unreachable`, `cpu/mem/pg_fatal + n8n_error → <левая часть>` следуют из этой упорядоченности и распространяются на любой набор из 3 и более сигналов без дополнительных правил.
6. ЕСЛИ `incident.kind ∈ {pg_fatal, mem}`, ТО подавления Live Migration и bootstrap-grace ПРИМЕНЯТЬСЯ НЕ ДОЛЖНЫ — это всегда настоящие инциденты (см. suppression matrix в `design.md`); при одновременном обнаружении `pg_fatal` и Live Migration события, `pg_fatal` ДОЛЖЕН быть обработан немедленно с игнорированием maintenance-события.
7. КОГДА `incident.kind == "cpu"` и в окне ±300 s присутствует Live Migration, ТО подавление ПРИМЕНЯЕТСЯ; КОГДА `incident.kind == "cpu"` и возраст инстанса < 1800 s, ТО подавление НЕ ПРИМЕНЯЕТСЯ (cold start честно нагружает CPU и оператор должен это видеть).

### Requirement 10: Graceful degradation и устойчивость к отказам зависимостей

**User Story:** Как on-call SRE, я хочу, чтобы при недоступности Firestore или превышении общего time-budget агент всё равно доставлял мне диагноз (пусть неполный), а не молча падал, чтобы ни один production-инцидент не остался без уведомления.

#### Acceptance Criteria

1. ЕСЛИ Firestore недоступен (timeout / 5xx / сетевая ошибка) при попытке дедуп-проверки или записи корреляции, ТО агент ДОЛЖЕН продолжить обработку инцидента без дедупликации и корреляции, залогировать структурированное событие `event=firestore_unavailable operation=<dedup|correlation|budget_check> error=<описание>`, и пометить `Diagnosis.evidence_refs` флагом `firestore_degraded=true`; повторная обработка дубликата в этом режиме ДОПУСКАЕТСЯ как trade-off.
2. ЕСЛИ суммарное время обработки инцидента (от приёма Pub/Sub message до момента готовности Telegram-сообщения) превышает `PROCESSING_TIMEOUT_SECONDS = 240` секунд, ТО агент ДОЛЖЕН прервать ожидание оставшихся шагов (LLM / probe), использовать rule-based fallback с имеющимся частичным контекстом, и отправить в Telegram partial diagnosis с пометкой `[timeout: partial]` в `Diagnosis.hypothesis`.
3. ЕСЛИ `partial=true` в контексте инцидента (из-за throttle Cloud Logging API, см. req 2.9), ТО секция `🔍` Telegram-сообщения ДОЛЖНА содержать пометку `[partial context: <partial_reason>]` перед hypothesis, чтобы оператор знал о неполноте данных.
4. ГДЕ агент обращается к Firestore для проверки дневного бюджета LLM (`cost_today >= LLM_BUDGET_USD_PER_DAY`), ТАМ при недоступности Firestore агент ДОЛЖЕН использовать rule-based fallback (conservative path) и НЕ ДОЛЖЕН вызывать LLM, чтобы избежать неконтролируемого расхода при потере state.

### Requirement 11: Контроль размера контекста и обработка многострочных логов

**User Story:** Как платформенный инженер, я хочу, чтобы агент не превышал лимит токенов LLM-провайдера и корректно обрабатывал многострочные stack traces в логах n8n/postgres, чтобы LLM получал релевантный контекст, а не обрезанную середину трейса.

#### Acceptance Criteria

1. ГДЕ задаётся env-переменная `MAX_CONTEXT_TOKENS`, ТАМ значение (default `12000`) ДОЛЖНО определять максимальный размер контекста (логи + метрики + probe результат) в токенах, передаваемого в LLM; подсчёт токенов ДОЛЖЕН использовать tiktoken-совместимый счётчик или эвристику `len(text) // 4`.
2. ЕСЛИ собранный контекст превышает `MAX_CONTEXT_TOKENS`, ТО агент ДОЛЖЕН усечь логи снизу вверх (самые свежие строки — приоритетнее), сохраняя метрики и probe-результат без усечения; усечённый контекст ДОЛЖЕН содержать маркер `[truncated: oldest N lines removed]` в начале лог-блока.
3. КОГДА `get_logs` возвращает лог-строки контейнера, ТО агент ДОЛЖЕН группировать многострочные записи (stack traces) по timestamp: строки с одинаковым timestamp (±1 ms) или без собственного timestamp (continuation lines) ДОЛЖНЫ считаться одной логической записью и усекаться/сохраняться атомарно, чтобы не обрезать stack trace посередине.
4. ГДЕ задаётся env-переменная `LLM_TIMEOUT_SECONDS`, ТАМ значение (default `45`) ДОЛЖНО определять максимальное время ожидания ответа от LLM-провайдера для одного вызова; при превышении таймаута адаптер ДОЛЖЕН прервать запрос и передать управление rule-based fallback (см. req 6.4).

### Requirement 12: Тестовая стратегия для correctness properties

**User Story:** Как разработчик, я хочу иметь автоматизированный набор тестов, покрывающий все correctness properties P1–P11, чтобы регрессии обнаруживались до деплоя в production.

#### Acceptance Criteria

1. ГДЕ определяется тестовый набор для SRE-агента, ТАМ ДОЛЖНЫ существовать property-based тесты (Hypothesis) для свойств P1 (redact removes secrets), P2 (redact idempotent), P3 (parse_alert deterministic), P7 (rule-based confidence=low), P8 (redact length bounded), P9 (probe timeout ≤ 30s).
2. ГДЕ определяется тестовый набор для SRE-агента, ТАМ ДОЛЖНЫ существовать unit-тесты с mock Cloud APIs для свойств P4 (dedup), P5 (budget enforcement), P6 (Telegram contains incident.id), P10 (correlation reduces LLM calls), P11 (suppression skips LLM).
3. КОГДА запускается CI pipeline (GitHub Actions), ТО все тесты из 12.1 и 12.2 ДОЛЖНЫ выполняться автоматически; pipeline ДОЛЖЕН блокировать merge при любом failing test.
4. ГДЕ определяется тестовый набор, ТАМ ДОЛЖЕН существовать integration-тест `test_e2e_happy_path`, эмулирующий полный цикл: Pub/Sub message → parse → context (mocked) → LLM (mocked) → Telegram (mocked) → Firestore (emulator), проверяющий корректность всей цепочки; тестовый набор (test suite) ДОЛЖЕН быть формально определён (pytest configuration, test markers, CI integration) до создания integration-тестов; e2e-тест МОЖЕТ существовать независимо от формального test suite definition.

### Requirement 13: Расширяемость на новых LLM-провайдеров

**User Story:** Как платформенный инженер, я хочу переключать LLM-провайдер между Gemini Flash, Claude Haiku и GPT-4o-mini только через env-переменную и обновление API-ключа, чтобы экспериментировать с качеством диагноза без переписывания вызывающего кода.

#### Acceptance Criteria

1. ГДЕ задаётся env-переменная `LLM_PROVIDER`, ТАМ допустимыми значениями ДОЛЖНЫ быть `"gemini"` (default), `"claude"`, `"openai"`.
2. ГДЕ задаётся env-переменная `LLM_MODEL`, ТАМ значение ДОЛЖНО передаваться в SDK выбранного провайдера без модификации; default — `"gemini-1.5-flash-002"`.
3. КОГДА провайдер переключается через env (`LLM_PROVIDER=claude`), ТО функция `analyze_with_llm` ДОЛЖНА вызвать соответствующий внутренний адаптер (`_call_claude`) без изменения сигнатуры или семантики возврата `Diagnosis`.
4. ЕСЛИ значение `LLM_PROVIDER` не входит в множество известных адаптеров, ТО функция `analyze_with_llm` ДОЛЖНА выбросить `ValueError` со строкой `"unknown provider <name>"`.
5. КОГДА любой адаптер LLM возвращает текстовый ответ, ТО агент ДОЛЖЕН выполнить client-side валидацию в два шага: (a) распарсить ответ как JSON через `json.loads`, (b) валидировать результат Pydantic-моделью `Diagnosis` со схемой `{hypothesis: str, evidence_refs: list[str], confidence ∈ {"low","medium","high"}, suggested_fix: str, suggested_command: str | null}`; ЕСЛИ шаг (a) выбрасывает `JSONDecodeError` ИЛИ шаг (b) выбрасывает `ValidationError` (schema-mismatch), ТО агент ДОЛЖЕН использовать rule-based fallback (см. требование 6.4); другие классы исключений из адаптера (5xx, timeout, сетевые ошибки) НЕ ДОЛЖНЫ автоматически переключаться на fallback по этому правилу — они обрабатываются собственными retry-механизмами адаптера.
6. КОГДА LLM-вызов завершается и возвращает ответ (независимо от того, прошёл ли ответ JSON-парсинг и Pydantic-валидацию), ТО агент ДОЛЖЕН зафиксировать `tokens_in`, `tokens_out`, `cost_usd`, `model`, `created_at` (UTC ISO-8601 timestamp), `status ∈ {"success", "parse_error", "validation_error"}` в структурированном логе `event=llm_call` и в Firestore-документе коллекции `diagnoses` для аудита; коллекция `diagnoses` ДОЛЖНА иметь TTL = 30 дней по полю `created_at`.

## Correctness Properties

Свойства корректности живут в `design.md` (раздел `Correctness Properties`) и являются единственным источником истины. Здесь — карта соответствия Property ↔ Requirement.

| Property (design.md) | Validates Requirement |
|---|---|
| **P1** Redact removes all secret patterns | 5.1 |
| **P2** Redact is idempotent | 5.2 |
| **P3** parse_alert is deterministic | 1.1 |
| **P4** Deduplication (TTL 1h по `incident.id`) | 4.1 |
| **P5** Token budget enforced (hard cap дневного бюджета) | 4.2 |
| **P6** Telegram message contains `incident.id` | 3.1 |
| **P7** Rule-based diagnosis confidence is low | 6.1 |
| **P8** Redact length bounded (`len(redact(s)) ≤ len(s) + 1024`) | 7.1 |
| **P9** External probe completes within timeout budget (≤ 30 s) | 8.1 |
| **P10** Correlation reduces LLM calls — same-kind ≤ 90 s (`CORRELATION_WINDOW_SEC`) и cross-kind ≤ 180 s (`CROSS_KIND_CORRELATION_WINDOW_SEC`) | 9.1 |
| **P11** Suppression skips LLM during Live Migration / bootstrap grace | 9.2 |

> Конкретные тесты Hypothesis для P1–P11 определены в `design.md → Testing Strategy → Покрытие correctness properties` и являются договорным интерфейсом между фазами Design и Implementation.

## Out of Scope

Следующие пункты явно вынесены из MVP (Phase 1). Они зафиксированы как «Не-цели MVP» в `design.md → Overview` и должны оставаться вне area of responsibility данной спецификации:

1. **Авто-ремедиация** (`docker restart`, `pg_terminate_backend`, `ALTER TABLE`, `compute.instances.reset` и т.д.) — отложено в Phase 5 с отдельной IAM-моделью (`roles/iap.tunnelResourceAccessor`) и обязательным human-in-the-loop через Telegram inline-кнопки.
2. **Полноценный vector-RAG** поверх постмортемов и снапшотов n8n docs — отложено в Phase 2 (Vertex AI Vector Search). MVP использует inline-excerpt `RUNBOOK_EXCERPT` (≤ 2 KB) в system-prompt.
3. **Multi-cluster / multi-VM** диагностика — текущий стек однонодный `e2-micro`, агент проектируется под этот контракт. Generalisation на множественные VM / k8s-кластеры — отдельная инициатива.
4. **Замена существующих SLO burn-rate alerts** (`n8n SLO fast burn` 14.4×, `n8n SLO slow burn` 6×) — агент **дополняет**, а не заменяет их. Эти алерты остаются в текущем `terraform/monitoring.tf` без изменений.
5. **Cloudflare Logpush correlation** для `cf_5xx`-spike сигналов — отложено в Phase 4 (Logpush job + GCS `cloudflare-logs` + BQ external table).
6. **LLM tool-calling / agentic loops** (LLM сам выбирает, какие данные собрать через `function_calling`) — отложено в Phase 3. В MVP контекст собирается детерминистическим кодом в `gather_context`.
7. **Внешний независимый монитор L3** (UptimeRobot / Better Stack / Healthchecks.io) — отложено в Phase 1.5; MVP опирается на GCP Uptime Check + Cloudflare Health Check (см. Q9).
8. **Включение Ops Agent metrics** на e2-micro ради точного memory-сигнала — оставлено logging-only, как сейчас (см. Q1). Memory-сигнал на Ubuntu и COS использует log-based метрику `n8n/oom_killed` из journald.

## Open Questions

Полный лог решений — в `design.md → Open Questions / Decision Log`. Здесь повторяется текущая резолюция Q1–Q15 для удобства ревью. Все Q* являются `frozen` решениями для MVP, кроме явно помеченных «owner после первого drill».

| # | Вопрос | Текущая резолюция | Статус |
|---|---|---|---|
| Q1 | Включать ли Ops Agent metrics ради точного memory-сигнала? | Нет, logging-only; используем log-based `oom_killed` | Open (owner после первого drill) |
| Q2 | Транспорт Alert→Function | Pub/Sub (`sre-incidents`), не HTTP webhook | Frozen |
| Q3 | Default LLM | Gemini 1.5 Flash; switch — env var `LLM_PROVIDER` | Open (owner) |
| Q4 | Где хранить дедуп-state | Firestore Native (transactional) | Frozen |
| Q5 | Передавать ли raw Cloudflare logs в LLM | Нет в MVP, только агрегаты в Phase 4 | Phase 4 |
| Q6 | RAG store | Inline excerpt в MVP; Vertex AI Vector Search в Phase 2 | Phase 2 |
| Q7 | Region для Cloud Function | `us-central1` (минимальная latency на Logging API) | Frozen |
| Q8 | Что делать с PII (IPv4) | Не редактировать по умолчанию; флаг конфигурации | Open (owner) |
| Q9 | L3 внешний монитор (UptimeRobot / Better Stack) — Phase 1 или 1.5? | Phase 1.5 — основа MVP это GCP Uptime + CF HC | Open (owner) |
| Q10 | `/healthz` vs `/healthz/deep` для Cloudflare Tunnel ingress | Два endpoint'а с разной семантикой; bootstrap grace только на `/healthz` | Frozen |
| Q11 | Docker log driver на COS | `json-file` (debug + shipping) | Frozen |
| Q12 | Реализация health-server'а на COS | Sidecar-контейнер `healthz-sidecar` в compose | Frozen |
| Q13 | Должен ли агент подавлять алерты во время Live Migration? | Да, ±300 s + короткое уведомление в Telegram | Frozen |
| Q14 | Bootstrap-grace окно для агента | 1800 s (синхронно с MIG `initial_delay_sec`); env-переопределяемо | Frozen |
| Q15 | Имена COS-вариантов log-based метрик | Без суффикса `_cos`, разные `count` за `var.host_os` | Frozen |
| Q16 | Firestore write throughput при alert storm | 1 write/sec per document — при 1000+ инцидентов/час (маловероятно на e2-micro) возможен bottleneck на incident_windows документе; для MVP допустимо, т.к. max_instance_count=5 и Pub/Sub queue absorbs burst | Known limitation (MVP) |

> Изменение любой строки `Frozen` требует amend `design.md` и пересмотра соответствующих требований 1–10.
