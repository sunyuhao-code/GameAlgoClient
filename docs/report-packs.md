# Report Packs

Report packs define how a game turns raw SDK event payloads into analytics reports.

The SDK sends business fields as event `payload`. GameAlgo stores that payload as raw JSON first; it does not expand every custom field during ingestion. A report pack tells the platform which payload fields matter, how to aggregate them, and which report views should be generated.

## Where To Submit

In the admin console, select a game, then open the `Reports` tab.

Use the `Reports` tab to view the active dashboard. Use `Manage Pack` when you need to edit the report pack JSON, validate SQL preview, or save a new version.

In `Manage Pack` you can:

- create a version such as `1.0.0`
- paste or edit the report pack JSON
- click `Validate` to preview validation results and generated SQL
- choose `draft`, `active`, or `disabled`
- click `Save`

In the main `Reports` view you can:

- choose an active report pack version
- choose a date range
- switch configured report tabs
- click `Run` to execute the charts in the active tab

## Example

```json
{
  "version": "1.0.0",
  "events": {
    "level_end": {
      "fields": {
        "level_id": { "path": "$.level_id", "type": "string" },
        "result": { "path": "$.result", "type": "string" },
        "level_no": { "path": "$.level_no", "type": "number" },
        "duration_ms": { "path": "$.duration_ms", "type": "number" }
      }
    },
    "ad_view": {
      "fields": {
        "placement": { "path": "$.placement", "type": "string" },
        "ad_type": { "path": "$.adType", "type": "string" },
        "revenue": { "path": "$.revenue", "type": "number" },
        "currency": { "path": "$.currency", "type": "string" },
        "network": { "path": "$.network", "type": "string" }
      }
    },
    "session_end": {
      "fields": {
        "session_duration_ms": { "path": "$.sessionDurationMs", "type": "number" }
      }
    }
  },
  "datasets": {
    "level_attempts": {
      "type": "event",
      "fromEvent": "level_end",
      "dimensions": ["level_id", "result"],
      "metrics": {
        "attempts": { "agg": "count" },
        "users": { "agg": "count_distinct", "field": "userId" },
        "avg_duration": { "agg": "avg", "field": "duration_ms" },
        "win_rate": {
          "agg": "ratio",
          "numerator": { "field": "result", "op": "eq", "value": "win" },
          "denominator": { "op": "all" }
        }
      }
    },
    "user_progress": {
      "type": "rollup",
      "fromEvent": "level_end",
      "stages": [
        {
          "id": "user_rollup",
          "entity": "userId",
          "metrics": {
            "user_max_level": { "agg": "max", "field": "level_no" }
          }
        }
      ],
      "metrics": {
        "avg_max_level": { "agg": "avg", "field": "user_max_level" },
        "users": { "agg": "count" }
      }
    },
    "new_user_ltv": {
      "type": "cohort",
      "fromEvent": "ad_view",
      "cohort": { "dateField": "userCreatedAt" },
      "windowDays": 14,
      "metrics": {
        "cohort_users": { "agg": "count_distinct", "field": "userId" },
        "revenue": { "agg": "sum", "field": "revenue" },
        "ltv": { "formula": "revenue / cohort_users" }
      }
    },
    "new_user_lifetime_duration": {
      "type": "cohort",
      "fromEvent": "session_end",
      "cohort": { "dateField": "userCreatedAt" },
      "windowDays": 14,
      "stages": [
        {
          "id": "session_rollup",
          "entity": "sessionId",
          "metrics": {
            "session_max_duration_ms": { "agg": "max", "field": "session_duration_ms" }
          }
        },
        {
          "id": "user_rollup",
          "entity": "userId",
          "metrics": {
            "user_lifetime_duration_ms": { "agg": "sum", "field": "session_max_duration_ms" }
          }
        }
      ],
      "metrics": {
        "cohort_users": { "agg": "count_distinct", "field": "userId" },
        "avg_lifetime_duration_ms": { "agg": "avg", "field": "user_lifetime_duration_ms" }
      }
    }
  },
  "reports": [
    {
      "id": "level_overview",
      "title": "Level Overview",
      "dataset": "level_attempts",
      "groupBy": ["dt", "level_id", "experiment.level_generator"],
      "metrics": ["attempts", "users", "avg_duration", "win_rate"]
    },
    {
      "id": "progress_overview",
      "title": "Progress Overview",
      "dataset": "user_progress",
      "groupBy": ["dt", "experiment.level_generator"],
      "metrics": ["avg_max_level", "users"]
    },
    {
      "id": "ltv_overview",
      "title": "LTV Overview",
      "dataset": "new_user_ltv",
      "groupBy": ["cohort_dt", "day_offset", "experiment.level_generator"],
      "metrics": ["cohort_users", "revenue", "ltv"]
    },
    {
      "id": "lifetime_duration_overview",
      "title": "Lifetime Duration Overview",
      "dataset": "new_user_lifetime_duration",
      "groupBy": ["cohort_dt", "day_offset", "experiment.level_generator"],
      "metrics": ["cohort_users", "avg_lifetime_duration_ms"]
    }
  ],
  "dashboard": {
    "title": "Mahjong Reports",
    "tabs": [
      {
        "id": "overview",
        "title": "Overview",
        "charts": [
          {
            "id": "win_rate_trend",
            "title": "Win Rate Trend",
            "type": "line",
            "report": "level_overview",
            "x": "dt",
            "y": "win_rate",
            "series": "level_id",
            "format": "percent",
            "size": "lg"
          },
          {
            "id": "attempt_share",
            "title": "Attempt Share",
            "type": "pie",
            "report": "level_overview",
            "label": "level_id",
            "value": "attempts"
          },
          {
            "id": "level_table",
            "title": "Level Detail",
            "type": "table",
            "report": "level_overview",
            "size": "full"
          }
        ]
      }
    ]
  }
}
```

## Semantics

- `events` declares fields inside each event type's `payload`.
- Field ids must be SQL-safe identifiers: letters, numbers, and underscores.
- `path` uses JSON path syntax such as `$.level_id`.
- Field `type` is `string`, `number`, or `boolean`.
- `datasets` define reusable statistical views. `type` defaults to `event`.
- `dimensions` are fields allowed in report `groupBy`.
- `metrics` are aggregated values.
- Supported metric aggregations are `count`, `count_distinct`, `sum`, `avg`, `min`, `max`, and `ratio`.
- `stages` define multi-step aggregation. Each stage groups by `entity` and emits stage metrics that the next stage or final `metrics` can use.
- Top-level `entity` and `rollupMetrics` are not supported; use `stages[].entity` and `stages[].metrics`.
- Any non-`ratio` metric can include `filter`.
- Formula metrics use a safe arithmetic expression over non-formula metrics in the same dataset, for example `"ltv": { "formula": "revenue / cohort_users" }`.
- `reports` define visible report queries.
- `groupBy` supports `dt`, dataset dimensions, and `experiment.<strategy_name>`.
- `dashboard.tabs` defines how the admin console lays out reports.
- A dashboard tab can either reference one built-in standard dashboard with `standard.ref` or contain multiple custom `charts`.
- Chart `type` supports `line`, `pie`, and `table`.
- Line charts use `x`, `y`, and optional `series` result columns.
- Pie charts use `label` and `value` result columns.
- Tables render the full report result.

Identity fields available to metrics are:

```text
contextId
userId
sessionId
```

Experiment groups are not duplicated in event payloads. The platform joins SDK context data by `contextId` and reads experiment assignments from the SDK context.

## Standard Dashboard References

Standard dashboards are built-in dashboard modules that can be referenced from a game's own report pack. They are not separate packs. A pack can mix standard tabs and custom tabs:

```json
{
  "dashboard": {
    "title": "Game Reports",
    "tabs": [
      {
        "id": "overview",
        "title": "Overview",
        "standard": { "ref": "core.overview@1" }
      },
      {
        "id": "custom_progress",
        "title": "Custom Progress",
        "charts": []
      }
    ]
  }
}
```

Each tab must choose one mode: `standard.ref` or `charts`. A standard tab stores the ref directly, so platform fixes or new query implementations can be applied without rewriting the game pack. The version suffix is part of the contract; use `@1` to keep the first standard definition.

The first reserved standard dashboard refs are:

| Ref | Purpose | Standard data expected |
| --- | --- | --- |
| `core.overview@1` | Overall traffic and session health: DAU, new users, sessions, average session duration, sessions per user. | SDK context rows plus `session_end.payload.sessionDurationMs`. |
| `retention.cohort@1` | New-user retention cohorts by cohort date and day offset. Includes the built-in `Retention Trend` line chart with `x = cohort_dt`, `y = retention_rate`, and `series = day_offset_label` for D1, D2, D3, and D7. | `adn.dws_gamealgo_standard_cohort_di`, produced from SDK context rows and activity events carrying `userId`, `sessionId`, and `contextId`. |
| `retention.activation_time@1` | Retention cohorts grouped by local activation time segment. | SDK context rows with `userCreatedAt` and `timezone`, plus later user activity. |
| `engagement.cohort@1` | New-user engagement cohorts: cumulative active days, cumulative play time, and sessions per user. | SDK context rows plus `session_end.payload.sessionDurationMs`. |
| `revenue.overview@1` | Daily revenue, ARPU, ARPDAU, payer count, and payment rate. | `ad_view` and `purchase` events with `revenue` and `currency` fields. |
| `revenue.ltv@1` | New-user LTV cohorts: cohort users, cumulative revenue, and LTV. | SDK context rows plus revenue events. |
| `revenue.placement@1` | Daily revenue by ad placement/type/network. | `ad_view` events with required `placement`, `adType`, `revenue`, and `currency`, plus optional `network`. |
| `progression.overview@1` | Progression funnel and difficulty health: starts, finishes, success rate, average duration, and drop-off by progression point. | `progression_start` and `progression_end` events with progression identity, order, result, and duration fields. |
| `events.health@1` | Data quality and event volume: event counts, users, sessions, and debug-event volume by event type. | Any SDK events in `gamealgo_events_payload`. |

Recommended standard event payload fields:

```json
{
  "session_end": {
    "sessionDurationMs": 125000
  },
  "ad_view": {
    "revenue": 0.18,
    "currency": "USD",
    "network": "admob",
    "adType": "reward",
    "placement": "rewarded_level_end"
  },
  "purchase": {
    "revenue": 4.99,
    "currency": "USD",
    "productId": "starter_pack"
  },
  "progression_end": {
    "progressionType": "level",
    "progressionId": "level_12",
    "progressionNo": 12,
    "result": "success",
    "durationMs": 82000
  }
}
```

The current validator accepts the refs above. These refs are contracts for platform-provided dashboards. Standard aggregate jobs live in `gamealgo-server/sql/standard_v2_*.sql` and are scheduled in DataWorks by the platform operator. Saving a report pack only records the `standard.ref`; it does not create, backfill, or schedule DataWorks tasks.

Standard dashboard query execution is intentionally separate from custom report SQL generation. Standard tabs read platform-managed aggregate tables, while custom tabs generate SQL from the pack's `events`, `datasets`, and `reports`. The first executable standard query is `standard.retention_trend` for `retention.cohort@1`; it filters `exp_info = 'glob'`, aggregates all activation-time rows for each cohort date, and hides immature cohort/day pairs by requiring `DATE_ADD(cohort_dt, day_offset) <= end_dt`.

## Dataset Types

`event` datasets aggregate event rows directly.

`rollup` datasets aggregate rows through one or more `stages`, then aggregate the final stage rows. Use this for metrics like average user max level:

```json
{
  "type": "rollup",
  "fromEvent": "level_end",
  "stages": [
    {
      "id": "user_rollup",
      "entity": "userId",
      "metrics": {
        "user_max_level": { "agg": "max", "field": "level_no" }
      }
    }
  ],
  "metrics": {
    "avg_max_level": { "agg": "avg", "field": "user_max_level" }
  }
}
```

`cohort` datasets build cohorts from SDK context rows and join later activity events by user. Use this for LTV and retention-style reports:

```json
{
  "type": "cohort",
  "fromEvent": "ad_view",
  "cohort": { "dateField": "userCreatedAt" },
  "windowDays": 14,
  "metrics": {
    "cohort_users": { "agg": "count_distinct", "field": "userId" },
    "revenue": { "agg": "sum", "field": "revenue" },
    "ltv": { "formula": "revenue / cohort_users" }
  }
}
```

`cohort` datasets can also use `stages`. For example, average new-user lifetime duration through each cohort day is session max duration by `sessionId`, then user total duration by `userId`, then final average across users:

```json
{
  "type": "cohort",
  "fromEvent": "session_end",
  "cohort": { "dateField": "userCreatedAt" },
  "windowDays": 14,
  "stages": [
    {
      "id": "session_rollup",
      "entity": "sessionId",
      "metrics": {
        "session_max_duration_ms": { "agg": "max", "field": "session_duration_ms" }
      }
    },
    {
      "id": "user_rollup",
      "entity": "userId",
      "metrics": {
        "user_lifetime_duration_ms": { "agg": "sum", "field": "session_max_duration_ms" }
      }
    }
  ],
  "metrics": {
    "avg_lifetime_duration_ms": { "agg": "avg", "field": "user_lifetime_duration_ms" }
  }
}
```

## Payload Guidelines

Keep event payloads flat for the first version:

```json
{
  "level_id": "level_001",
  "result": "win",
  "duration_ms": 12500
}
```

Do not put secrets, phone numbers, emails, full account identifiers, device metadata, or experiment assignments in payload. SDK context already carries identity, device, app, and experiment metadata.

## Validation

For AI or local validation before saving, call the admin preview endpoint with the same fields the save flow uses:

```json
{
  "version": "1.0.0",
  "status": "active",
  "content": {
    "version": "1.0.0"
  }
}
```

When `version` is provided, preview also verifies `content.version` matches the save version. It still does not write to the management database.

Server-side local validators should use `validateReportPackForSave(content, version)`, not the lower-level content-only validator, when they need save-equivalent validation.

## Current Boundary

The platform currently stores and validates report packs, generates SQL preview for custom reports and supported standard dashboards, and can run active reports online from the admin console through the analytics bridge.

Report query results are cached by `gameId + version + reportId + startDate + endDate`. The Cloudflare worker refreshes all queryable reports in active report packs for the default dashboard range every two hours when the report cache cron is configured. Queryable reports include custom `reports[]` entries and supported standard reports such as `standard.retention_trend`.

Standard dashboards are declared by `standard.ref` and backed by platform DataWorks jobs. DataWorks task scheduling and historical backfill are operational setup steps outside of the report pack save flow.
