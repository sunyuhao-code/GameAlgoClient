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
    "ad_revenue": {
      "fields": {
        "revenue": { "path": "$.revenue", "type": "number" }
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
      "fromEvent": "ad_revenue",
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
- A dashboard tab contains multiple `charts`.
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
  "fromEvent": "ad_revenue",
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

The platform currently stores and validates report packs, generates SQL preview, and can run an active report online from the admin console. It does not yet schedule MaxCompute jobs or create materialized result tables.
