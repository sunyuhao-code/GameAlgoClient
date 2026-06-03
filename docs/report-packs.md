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
        "duration_ms": { "path": "$.duration_ms", "type": "number" }
      }
    }
  },
  "datasets": {
    "level_attempts": {
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
    }
  },
  "reports": [
    {
      "id": "level_overview",
      "title": "Level Overview",
      "dataset": "level_attempts",
      "groupBy": ["dt", "level_id", "experiment.level_generator"],
      "metrics": ["attempts", "users", "avg_duration", "win_rate"]
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
- `datasets` define reusable statistical views over one event type.
- `dimensions` are fields allowed in report `groupBy`.
- `metrics` are aggregated values.
- Supported metric aggregations are `count`, `count_distinct`, `sum`, `avg`, `min`, `max`, and `ratio`.
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

## Current Boundary

The platform currently stores and validates report packs, generates SQL preview, and can run an active report online from the admin console. It does not yet schedule MaxCompute jobs or create materialized result tables.
