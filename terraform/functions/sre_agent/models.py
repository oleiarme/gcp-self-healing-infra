"""Pydantic-модели данных SRE-агента.

Модели:
  - LogLine — одна строка лога
  - Metric — точка метрики
  - Signal — единица контекста (лог, метрика, probe)
  - Incident — нормализованный инцидент из Cloud Monitoring
  - Diagnosis — результат анализа (LLM или rule-based)
  - Notification — отправленное уведомление

Requirements: 1.1–1.6, 3.1, 6.5
"""

from datetime import datetime
from typing import Literal, Optional, Union

from pydantic import BaseModel


class LogLine(BaseModel):
    """Одна строка лога из Cloud Logging.

    Attributes:
        timestamp: Время записи лога.
        text: Текст лог-строки.
        container: Имя контейнера-источника (optional, может отсутствовать
                   для системных логов — OOM, kernel messages).
    """

    timestamp: datetime
    text: str
    container: Optional[str] = None


class Metric(BaseModel):
    """Точка метрики (CPU utilization, memory, etc.).

    Attributes:
        timestamp: Время снятия метрики.
        value: Числовое значение метрики.
        metric_type: Тип метрики (e.g. "cpu_utilization", "memory_percent").
    """

    timestamp: datetime
    value: float
    metric_type: str


class Signal(BaseModel):
    """Единица контекста, собранная агентом для инцидента.

    Signal — это обёртка над данными из разных источников:
    логи (n8n_logs, pg_logs), метрики (cpu_metric), результат
    внешнего пробинга (external_probe).

    Attributes:
        kind: Тип сигнала (произвольная строка, e.g. "n8n_logs", "cpu_metric").
        source: Источник данных (e.g. "n8n_logs", "pg_logs", "cpu_metric",
                "external_probe").
        data: Данные сигнала — список (для логов/метрик) или dict (для probe).
    """

    kind: str
    source: str
    data: Union[list, dict]


class Incident(BaseModel):
    """Нормализованный инцидент из Cloud Monitoring.

    Создаётся парсером `parse_alert` из raw payload Cloud Monitoring.
    Поле `kind` ограничено 5 классами сигналов MVP.

    Attributes:
        id: Уникальный ID инцидента (из payload.incident.incident_id).
        kind: Класс инцидента — один из 5 типов MVP.
        severity: Уровень серьёзности — "warning" или "critical".
        started_at: Время начала инцидента.
        resource: Ресурс-источник (dict с vm и/или public_host).
        raw_payload: Исходный payload Cloud Monitoring (для аудита).
        source: Источник инцидента (e.g. "cloud-monitoring").
    """

    id: str
    kind: Literal["cpu", "mem", "pg_fatal", "n8n_error", "external_unreachable"]
    severity: Literal["warning", "critical"]
    started_at: datetime
    resource: dict
    raw_payload: dict
    source: str


class Diagnosis(BaseModel):
    """Результат анализа инцидента (LLM или rule-based fallback).

    Содержит гипотезу root-cause, ссылки на evidence, предложение
    фикса и метаданные LLM-вызова (модель, токены, стоимость).

    Attributes:
        hypothesis: Гипотеза root-cause (текст для оператора).
        evidence_refs: Ссылки на evidence (log entry IDs, metric URIs).
        confidence: Уровень уверенности — "low", "medium", "high".
        suggested_fix: Предложение фикса (текст для оператора).
        suggested_command: Опциональная команда для выполнения.
        model: Модель, создавшая диагноз (e.g. "gemini-2.0-flash",
               "rule-based-v1").
        tokens_in: Количество входных токенов LLM-вызова (0 для rule-based).
        tokens_out: Количество выходных токенов LLM-вызова (0 для rule-based).
        cost_usd: Стоимость LLM-вызова в USD (0.0 для rule-based).
        created_at: Время создания диагноза.
    """

    hypothesis: str
    evidence_refs: list[str]
    confidence: Literal["low", "medium", "high"]
    suggested_fix: str
    suggested_command: Optional[str] = None
    model: str
    tokens_in: int
    tokens_out: int
    cost_usd: float
    created_at: datetime


class Notification(BaseModel):
    """Отправленное уведомление в Telegram.

    Attributes:
        incident_id: ID инцидента, к которому относится уведомление.
        channel: Канал отправки (telegram).
        message_id: ID сообщения в канале (пустая строка при неудаче).
        sent_at: Время отправки.
        success: Успешность отправки.
        error: Описание ошибки (optional, только при success=False).
    """

    incident_id: str
    channel: Literal["telegram"]
    message_id: str
    sent_at: datetime
    success: bool
    error: Optional[str] = None
