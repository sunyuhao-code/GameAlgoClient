# Report Packs

Report packs define how a game turns raw SDK event payloads into analytics reports.

The SDK sends business fields as event `payload`. A report pack tells GameAlgo which payload fields matter, how to aggregate them, and which report views should be generated.

## Where To Submit

In the GameAlgo console, select a game, then open the `Reports` tab.

Use the `Reports` tab to view the active dashboard. Use `Manage Pack` when you need to edit the report pack JSON, validate it, or save a new version.

In `Manage Pack` you can:

- create a version such as `1.0.0`
- paste or edit the report pack JSON
- click `Validate` to preview validation results
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
        "groups": [
          {
            "id": "level_progress",
            "title": "Level Progress",
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
    ]
  }
}
```

## Semantics

- `events` declares fields inside each event type's `payload`.
- Field ids must use letters, numbers, and underscores.
- `path` uses JSON path syntax such as `$.level_id`.
- Field `type` is `string`, `number`, or `boolean`.
- `datasets` define reusable statistical views. `type` defaults to `event`.
- `dimensions` are fields allowed in report `groupBy`.
- `metrics` are aggregated values.
- Supported metric aggregations are `count`, `count_distinct`, `sum`, `avg`, `min`, `max`, `ratio`, and `penetration`.
- `stages` define multi-step aggregation. Each stage groups by `entity` and emits stage metrics that the next stage or final `metrics` can use.
- Top-level `entity` and `rollupMetrics` are not supported; use `stages[].entity` and `stages[].metrics`.
- Any non-`ratio` metric can include `filter`.
- Formula metrics use a safe arithmetic expression over non-formula metrics in the same dataset, for example `"ltv": { "formula": "revenue / cohort_users" }`.
- `penetration` computes distinct entity penetration for event datasets. The default entity is `userId`; `denominator` can be `event_users`, `active_users`, or `new_users`. `active_users` and `new_users` use SDK context rows as the denominator, so reports using them can only group by `dt`, experiment fields, or SDK context fields such as `platform` and `appVersion`.
- `reports` define visible report queries.
- `groupBy` supports `dt`, dataset dimensions, `experiment.<strategy_name>`, and `experiment`.
- `dashboard.tabs` defines how the GameAlgo console lays out reports.
- A tab can contain one or more `groups`. A group visually wraps related charts and owns a shared selector list. Not every chart in the group has to use every selector.
- Older packs can still define top-level `standard.ref` or `charts`; the console treats `standard.ref` as one generated standard group and splits top-level `charts` into custom groups by `chart.report`.
- Chart `type` supports `line`, `pie`, and `table`.
- Line charts use `x`, `y`, and optional `series` result columns.
- Pie charts use `label` and `value` result columns.
- Tables render the full report result.
- Use `"format": "percent"` explicitly for custom ratio metrics that should render as percentages. Otherwise decimal values render as plain numbers, except platform standard retention columns such as `retention_rate` and `d1_rate`.

Identity fields available to metrics are:

```text
contextId
userId
sessionId
```

Experiment groups are not duplicated in event payloads. The platform joins SDK context data by `contextId` and reads experiment assignments from the SDK context.

Use `experiment.<strategy_name>` when a report should always split by one known strategy. The result column is named like `experiment_level_generator`.

Use bare `experiment` when the dashboard should let the viewer choose a strategy at runtime. The report returns global rows plus experiment rows with these result columns:

| Column | Meaning |
| --- | --- |
| `scope` | `global` for all users, or `experiment` for strategy/variant rows. |
| `strategy` | Strategy name for experiment rows, empty for global rows. |
| `variant` | Variant name for experiment rows, empty for global rows. |

## Standard Dashboard References

Standard dashboards are built-in dashboard modules that can be referenced from a game's own report pack. They are not separate packs. A pack can mix standard groups and custom groups:

```json
{
  "dashboard": {
    "title": "Game Reports",
    "tabs": [
      {
        "id": "overview",
        "title": "Overview",
        "groups": [
          {
            "id": "core",
            "title": "Core Overview",
            "standard": { "ref": "core.overview@1" }
          }
        ]
      },
      {
        "id": "custom_progress",
        "title": "Custom Progress",
        "groups": [
          {
            "id": "progression",
            "title": "Progression",
            "charts": []
          }
        ]
      }
    ]
  }
}
```

Each tab should use `groups` for new packs. A group must choose one mode: `standard.ref` or `charts`. A standard group stores the ref directly, so platform fixes or new query implementations can be applied without rewriting the game pack. The version suffix is part of the contract; use `@1` to keep the first standard definition.

Group selectors are UI controls scoped to one group:

```json
{
  "id": "retention_cohort",
  "title": "Retention Cohort",
  "standard": { "ref": "retention.cohort@1" },
  "selectors": [
    { "id": "strategy", "label": "Strategy", "source": "experimentStrategies" },
    { "id": "dayOffset", "label": "Dx", "options": ["D1", "D2", "D3", "D7"] }
  ]
}
```

The built-in `retention.cohort@1` and `revenue.ltv@1` groups automatically provide Strategy and Dx selectors. These selectors only affect the charts in their own group.

Custom groups can use the same experiment selector by declaring `type: "experimentStrategy"` and using a report grouped by bare `experiment`:

```json
{
  "reports": [
    {
      "id": "ad_revenue_by_variant",
      "dataset": "ad_revenue",
      "groupBy": ["dt", "placement", "experiment"],
      "metrics": ["revenue"]
    }
  ],
  "dashboard": {
    "tabs": [
      {
        "id": "revenue",
        "title": "Revenue",
        "groups": [
          {
            "id": "ad_revenue",
            "title": "Ad Revenue",
            "selectors": [
              { "id": "experiment", "label": "Experiment", "type": "experimentStrategy" }
            ],
            "charts": [
              {
                "id": "revenue_trend",
                "title": "Revenue Trend",
                "type": "line",
                "report": "ad_revenue_by_variant",
                "x": "dt",
                "y": "revenue",
                "series": "variant"
              }
            ]
          }
        ]
      }
    ]
  }
}
```

The experiment selector only filters rows. `Global` means `scope = global`; selecting a strategy means `scope = experiment AND strategy = selected`. The chart still owns its `x`, `y`, `series`, `label`, and `value` mappings.

The first reserved standard dashboard refs are:

| Ref | Purpose | Required data |
| --- | --- | --- |
| `core.overview@1` | Overall traffic and session health. Includes built-in line charts for DAU, new users, sessions, average session duration, sessions per user, plus a detail table. | SDK context rows plus `session_end.payload.sessionDurationMs`. |
| `retention.cohort@1` | New-user retention cohorts by cohort date and day offset. Includes the built-in `Retention Trend` line chart for D1, D2, D3, and D7, plus a `Retention Cohort Matrix` table for D0-D14. The console can switch between global retention and experiment split views with runtime Strategy and Dx selectors. | SDK context rows and later user activity events. |
| `retention.activation_time@1` | Retention cohorts grouped by local activation time segment. | SDK context rows with `userCreatedAt` and `timezone`, plus later user activity. |
| `engagement.cohort@1` | New-user engagement cohorts: cumulative active days, cumulative play time, and sessions per user. | SDK context rows plus `session_end.payload.sessionDurationMs`. |
| `revenue.overview@1` | Daily revenue, ARPU, ARPDAU, payer count, and payment rate. | `ad_view` and `purchase` events with `revenue` and `currency` fields. |
| `revenue.ltv@1` | New-user LTV cohorts. Includes the built-in `LTV Trend` line chart for D0, D1, D2, D3, D7, and D14, plus an `LTV Cohort Matrix` table for D0-D14. The console can switch between global LTV and experiment split views with runtime Strategy and Dx selectors. | SDK context rows plus revenue events. |
| `revenue.placement@1` | Daily revenue by ad placement/type/network. | `ad_view` events with required `placement`, `adType`, `revenue`, and `currency`, plus optional `network`. |
| `progression.overview@1` | Progression funnel and difficulty health: starts, finishes, success rate, average duration, and drop-off by progression point. | `progression_start` and `progression_end` events with progression identity, order, result, and duration fields. |
| `events.health@1` | Data quality and event volume: event counts, users, sessions, and debug-event volume by event type. | Any SDK events. |

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

The current validator accepts the refs above. These refs are contracts for platform-provided dashboards. Saving a report pack records the selected `standard.ref`; the platform prepares the data behind standard dashboards separately. LTV and retention dashboards hide immature cohort/day pairs, so a D7 value appears only after that cohort has had enough time to reach day 7.

## Dataset Types

`event` datasets aggregate event rows directly. Use `penetration` when the numerator is users who triggered an event and the denominator is a user base:

```json
{
  "events": {
    "feature_use": {
      "fields": {
        "feature": { "path": "$.feature", "type": "string" }
      }
    }
  },
  "datasets": {
    "feature_penetration": {
      "fromEvent": "feature_use",
      "metrics": {
        "daily_bonus_penetration": {
          "agg": "penetration",
          "entity": "userId",
          "numerator": { "field": "feature", "op": "eq", "value": "daily_bonus" },
          "denominator": "active_users"
        }
      }
    }
  },
  "reports": [
    {
      "id": "feature_penetration_overview",
      "dataset": "feature_penetration",
      "groupBy": ["dt", "experiment"],
      "metrics": ["daily_bonus_penetration"]
    }
  ]
}
```

For `denominator: "event_users"`, the denominator is distinct users in the same event dataset and can use event dimensions. For `active_users` and `new_users`, the denominator comes from SDK context rows; keep `groupBy` to context-level fields. In dashboard charts, add `"format": "percent"` when the penetration value should render as a percentage.

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

Use `Validate` in `Manage Pack` before saving. Validation checks the JSON shape, report references, chart mappings, dataset definitions, standard dashboard refs, and that the top-level `version` matches the version being saved.

After saving an `active` pack, return to the main `Reports` view, choose a date range, and click `Run` to load the configured dashboard.
