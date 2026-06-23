# Report Packs 报表配置

Report pack 用来定义一个游戏如何把 SDK 上报的事件 `payload` 转成分析报表。

SDK 会把业务字段放在事件 `payload` 中。Report pack 告诉 GameAlgo 哪些 payload 字段需要用于报表、如何聚合，以及最终生成哪些报表视图。

## 提交位置

在 GameAlgo 控制台选择游戏，然后打开 `Reports` tab。

`Reports` tab 用于查看当前生效的看板。需要编辑 report pack JSON、校验或保存新版本时，点击 `Manage Pack`。

在 `Manage Pack` 中可以：

- 创建版本，例如 `1.0.0`
- 粘贴或编辑 report pack JSON
- 点击 `Validate` 查看校验结果
- 选择 `draft`、`active` 或 `disabled`
- 点击 `Save`

在主 `Reports` 页面中可以：

- 选择一个 active 的 report pack 版本
- 选择日期范围
- 切换配置好的报表 tab
- 点击 `Run` 运行当前 tab 下的图表

## 示例

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
                "id": "level_dropoff_bar",
                "title": "Level Drop-off",
                "type": "bar",
                "report": "level_overview",
                "x": "level_id",
                "y": "dropoff_rate",
                "format": "percent",
                "size": "lg"
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

## 字段语义

- `events` 声明每种事件 `payload` 里的字段。
- 字段 id 只能使用字母、数字和下划线。
- `path` 使用 JSON path 语法，例如 `$.level_id`。
- 字段 `type` 支持 `string`、`number` 或 `boolean`。
- `datasets` 定义可复用的统计视图。`type` 默认是 `event`。
- `dimensions` 是允许在报表 `groupBy` 中使用的字段。
- `metrics` 是聚合指标。
- 支持的指标聚合方式包括 `count`、`count_distinct`、`sum`、`avg`、`min`、`max`、`ratio` 和 `penetration`。
- `stages` 定义多步聚合。每个 stage 按 `entity` 分组，并输出 stage metrics，供下一个 stage 或最终 `metrics` 使用。`entity` 可以是单个字段，也可以是数组，例如 `["userId", "mode"]`。stage 可以配置 `filter`，表示先过滤再聚合。
- `derivedDimensions` 可用于 `rollup` dataset。第一版支持 `bucket`，可以把 `user_max_level` 这类 rollup 后才出现的指标转换成 `level_bucket` / `bucket_order` 这样的分组维度。
- 不支持顶层 `entity` 和 `rollupMetrics`；请使用 `stages[].entity` 和 `stages[].metrics`。
- 除 `ratio` 外，其他 metric 都可以包含 `filter`。
- formula metric 使用同一个 dataset 中非 formula metric 的安全算术表达式，例如 `"ltv": { "formula": "revenue / cohort_users" }`。
- `penetration` 用于计算事件 dataset 的去重实体渗透率。默认实体是 `userId`；`denominator` 可以是 `event_users`、`active_users` 或 `new_users`。`active_users` 和 `new_users` 使用 SDK context 作为分母，因此使用它们的报表只能按 `dt`、实验字段或 `platform`、`appVersion` 等 SDK context 字段分组。
- `calculations` 可以声明平台预置的计算模板。常见问题可以优先用模板配置，少写一层 dataset/report，也更不容易写错。
- `reports` 定义可见报表查询。
- `groupBy` 支持 `dt`、dataset dimensions、`experiment.<strategy_name>` 和 `experiment`。
- `dashboard.tabs` 定义 GameAlgo 控制台如何布局报表。
- 一个 tab 可以包含一个或多个 `groups`。group 会在 UI 上包裹一组相关图表，并拥有一组共享 selector。group 内的图表不一定都要使用每个 selector。
- 老版本 pack 仍可以定义顶层 `standard.ref` 或 `charts`；控制台会把 `standard.ref` 视为一个生成的标准 group，并按 `chart.report` 把顶层 `charts` 拆成自定义 group。
- 图表 `type` 支持 `line`、`bar`、`pie` 和 `table`。
- 折线图使用结果列里的 `x`、`y` 和可选 `series`。
- 柱状图也使用结果列里的 `x`、`y` 和可选 `series`，适合展示分关卡流失率、分广告位收入、分模式人数等离散维度对比。离散桶需要稳定顺序时，配置 `sort` 指向结果里的排序列，例如 `bucket_order`；`sortDirection` 支持 `asc` 和 `desc`，默认 `asc`。第一版 `barMode` 支持 `grouped`，后续可扩展 `stacked`。
- 饼图使用结果列里的 `label` 和 `value`。
- 表格会渲染完整报表结果。
- 自定义 ratio metric 如果要按百分比展示，需要显式设置 `"format": "percent"`。否则小数会按普通数值展示，平台标准留存列如 `retention_rate`、`d1_rate` 除外。

分桶柱状图示例：

```json
{
  "id": "max_level_distribution",
  "title": "Max Level Distribution",
  "type": "bar",
  "report": "mode_max_level_distribution",
  "x": "level_bucket",
  "y": "users",
  "series": "mode",
  "sort": "bucket_order",
  "sortDirection": "asc",
  "barMode": "grouped"
}
```

metrics 可使用的身份字段：

```text
contextId
userId
sessionId
```

实验分组不会复制到事件 payload 中。平台会通过 `contextId` 关联 SDK context，并从 SDK context 读取实验分组。

如果一个报表总是按某个已知 strategy 拆分，可以使用 `experiment.<strategy_name>`。结果列名形如 `experiment_level_generator`。

如果希望看板查看者在运行时选择 strategy，可以使用裸 `experiment`。报表会返回 global 行和 experiment 行，包含这些结果列：

| 列 | 含义 |
| --- | --- |
| `scope` | `global` 表示全量用户，`experiment` 表示 strategy/variant 行。 |
| `strategy` | experiment 行中的 strategy 名称；global 行为空。 |
| `variant` | experiment 行中的 variant 名称；global 行为空。 |

## 计算模板

`breakdown_experiment_line@1` 用来标准化“业务 breakdown 维度 + 可选实验对比”这类看板。它适合配置按模式的收入贡献、模式渗透率、按内容类型的人均行为次数等常见指标。

这个模板的 UI 有两种状态：

- 未选择实验：`series = breakdown`，例如每个 mode 一条线。
- 选择实验后：查看者还需要选择一个 breakdown 值，然后 `series = variant`。

内置指标模板 `measure_per_actor@1` 的计算公式是：

```text
value_per_actor = measure_value / denominator_count
```

分子全局按 `dt + breakdown` 聚合，实验态按 `dt + breakdown + strategy + variant` 聚合。分母全局按 `dt` 聚合，实验态按 `dt + strategy + variant` 聚合。分母不会包含 breakdown 维度。比如分模式 ARPU 算的是 `normal 模式收入 / 该 variant 下全部活跃用户`，不是 `normal 模式收入 / normal 模式用户`。

```json
{
  "calculations": [
    {
      "id": "mode_arpu",
      "title": "Mode ARPU",
      "template": "breakdown_experiment_line@1",
      "breakdown": {
        "id": "mode",
        "label": "Mode",
        "measureField": "mode",
        "options": ["normal", "vita", "sheep"],
        "default": "all"
      },
      "metric": {
        "template": "measure_per_actor@1",
        "measure": {
          "event": "ad_view",
          "agg": "sum",
          "field": "revenue"
        },
        "denominator": {
          "base": "active_users"
        }
      },
      "dashboard": {
        "tab": "Revenue",
        "group": "Mode Revenue",
        "format": "currency"
      }
    }
  ]
}
```

上面的配置会自动生成两个可查询报表：

| Report id | 行粒度 |
| --- | --- |
| `mode_arpu_global` | 按 `dt` 和 `mode` 聚合 |
| `mode_arpu_experiment` | 按 `dt`、`mode`、`scope`、`strategy`、`variant` 聚合 |

两个报表都会返回 `measure_value`、`denominator_count` 和 `value_per_actor`。控制台会自动创建一个 group，里面带 Experiment selector 和 breakdown selector。没有选择实验时，折线图按 `mode` 出多条线；选择实验后，需要再选择一个具体 mode，然后折线图按 variant 出多条线。

如果要配置渗透率，可以把分子写成 `count_distinct`：

```json
{
  "id": "mode_ad_penetration",
  "title": "Mode Ad Penetration",
  "template": "breakdown_experiment_line@1",
  "breakdown": {
    "id": "mode",
    "label": "Mode",
    "measureField": "mode",
    "options": ["normal", "vita", "sheep"],
    "default": "all"
  },
  "metric": {
    "template": "measure_per_actor@1",
    "measure": {
      "event": "mode_start",
      "agg": "count_distinct",
      "field": "userId"
    },
    "denominator": {
      "base": "active_users"
    }
  },
  "dashboard": {
    "tab": "Revenue",
    "group": "Mode Ad Penetration",
    "format": "percent"
  }
}
```

## 标准看板引用

标准看板是平台内置的看板模块，可以在游戏自己的 report pack 里引用。它们不是独立 pack。一个 pack 可以同时包含标准 group 和自定义 group：

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

新 pack 建议每个 tab 都使用 `groups`。一个 group 只能选择一种模式：`standard.ref` 或 `charts`。标准 group 直接保存 ref，因此平台修复或升级查询实现时，不需要重写游戏 pack。版本后缀是契约的一部分；使用 `@1` 表示使用第一版标准定义。

Group selector 是只作用于当前 group 的 UI 控件：

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

内置的 `retention.cohort@1` 和 `revenue.ltv@1` group 会自动提供 Strategy 和 Dx selector。这些 selector 只影响所在 group 内的图表。

自定义 group 也可以使用同样的实验 selector：声明 `type: "experimentStrategy"`，并让对应 report 使用裸 `experiment` 分组：

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

实验 selector 默认只负责过滤行。`Global` 表示 `scope = global`；选择某个 strategy 表示 `scope = experiment AND strategy = selected`。Dimension selector 可以用 `"type": "dimension"` 声明，按结果列过滤当前 group 的图表。多个 selector 会按 AND 叠加。图表仍然通过自己的 `x`、`y`、`series`、`label` 和 `value` 字段决定如何渲染。

如果一个图表在「未选实验」和「选中实验」时需要不同的数据粒度，可以配置 `views.global` 和 `views.experiment`。控制台会在 group 的 experiment selector 选中具体 strategy 时使用 `views.experiment`，否则使用 `views.global` 或 chart 本身的配置。`requiredSelectors` 用来要求某个 dimension selector 必须选具体值，不能是 `all`，避免前端把不同粒度的行错误聚合：

```json
{
  "reports": [
    {
      "id": "mode_level_completion_global",
      "dataset": "level_attempts",
      "groupBy": ["dt", "mode"],
      "metrics": ["completed_levels", "users"]
    },
    {
      "id": "mode_level_completion_experiment",
      "dataset": "level_attempts",
      "groupBy": ["dt", "mode", "experiment"],
      "metrics": ["completed_levels", "users"]
    }
  ],
  "dashboard": {
    "tabs": [
      {
        "id": "levels",
        "title": "Levels",
        "groups": [
          {
            "id": "mode_level_completion",
            "title": "Mode Level Completion",
            "selectors": [
              { "id": "experiment", "label": "Experiment", "type": "experimentStrategy" },
              {
                "id": "mode",
                "label": "Mode",
                "type": "dimension",
                "field": "mode",
                "options": ["classic", "vita", "sheep"],
                "default": "classic"
              }
            ],
            "charts": [
              {
                "id": "completed_levels",
                "title": "Completed Levels",
                "type": "line",
                "report": "mode_level_completion_global",
                "x": "dt",
                "y": "completed_levels",
                "series": "mode",
                "valueAgg": "sum",
                "views": {
                  "global": {
                    "report": "mode_level_completion_global",
                    "series": "mode"
                  },
                  "experiment": {
                    "report": "mode_level_completion_experiment",
                    "series": "variant",
                    "requiredSelectors": ["mode"]
                  }
                }
              }
            ]
          }
        ]
      }
    ]
  }
}
```

当前预留的标准看板 ref：

| Ref | 用途 | 所需数据 |
| --- | --- | --- |
| `core.overview@1` | 总览流量和会话健康度。包含 DAU、新用户、会话数、平均会话时长、用户会话数的内置折线图，以及明细表。 | SDK context 行，以及 `session_end.payload.sessionDurationMs`。 |
| `retention.cohort@1` | 按 cohort date 和 day offset 计算新用户留存。包含内置 `Retention Trend` 折线图（D1、D2、D3、D7）和 `Retention Cohort Matrix` 表格（D0-D14）。控制台可通过运行时 Strategy 和 Dx selector 在全局留存和分实验留存之间切换。 | SDK context 行，以及后续用户活跃事件。 |
| `retention.activation_time@1` | 按本地激活时间段分组的留存 cohort。 | 带 `userCreatedAt` 和 `timezone` 的 SDK context 行，以及后续用户活跃事件。 |
| `engagement.cohort@1` | 新用户互动 cohort：累计活跃天数、累计游戏时长、用户会话数。 | SDK context 行，以及 `session_end.payload.sessionDurationMs`。 |
| `revenue.overview@1` | 每日收入、ARPU、ARPDAU、付费人数和付费率。 | 带 `revenue` 和 `currency` 字段的 `ad_view`、`purchase` 事件。 |
| `revenue.ltv@1` | 新用户 LTV cohort。包含内置 `LTV Trend` 折线图（D0、D1、D2、D3、D7、D14）和 `LTV Cohort Matrix` 表格（D0-D14）。控制台可通过运行时 Strategy 和 Dx selector 在全局 LTV 和分实验 LTV 之间切换。 | SDK context 行，以及收入事件。 |
| `revenue.placement@1` | 按广告 placement/type/network 拆分的每日收入。 | 成功曝光的 `ad_view` 事件，必填 `placement`、`adType`、`revenue`、`currency`，可选 `network`。广告失败、未填充、取消或未完成有效曝光时不要上报到 `ad_view`。 |
| `progression.overview@1` | 进度漏斗和难度健康度：开始、完成、成功率、平均时长、按进度点流失。 | `progression_start` 和 `progression_end` 事件，包含进度标识、顺序、结果和时长字段。 |
| `events.health@1` | 数据质量和事件量：按事件类型统计事件数、用户数、会话数和 debug 事件量。 | 任意 SDK 事件。 |

推荐标准事件 payload 字段：

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

当前校验器接受上表中的 ref。这些 ref 是平台提供标准看板的契约。保存 report pack 时只会记录选择的 `standard.ref`；标准看板背后的数据由平台准备。LTV 和留存看板会隐藏尚未成熟的 cohort/day 组合，例如 D7 只有在对应 cohort 已经过了 7 天后才会出现。

## Dataset 类型

`event` dataset 会直接聚合事件行。当分子是触发某个事件的用户，分母是某个用户基数时，可以使用 `penetration`：

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

当 `denominator: "event_users"` 时，分母是同一个事件 dataset 中的去重用户，可以使用事件维度。当 denominator 是 `active_users` 或 `new_users` 时，分母来自 SDK context 行；此时 `groupBy` 应限制为 context 级字段。看板图表需要按百分比展示渗透率时，添加 `"format": "percent"`。

`rollup` dataset 会先经过一个或多个 `stages` 聚合，再对最终 stage 行继续聚合。适合“用户最大关卡均值”这类指标：

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

`cohort` dataset 会从 SDK context 行构建 cohort，并按用户关联后续活跃或收入事件。适合 LTV、留存这类报表：

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

如果要做分布图，可以把 rollup metric 派生为分桶维度。典型场景是“用户最大关卡分布”：先按 `userId + mode` 算出每个用户在每个模式下的最大关卡，再把最大关卡映射到离散桶，最后按 `mode + level_bucket` 统计人数。

```json
{
  "type": "rollup",
  "fromEvent": "level_end",
  "stages": [
    {
      "id": "user_mode_rollup",
      "entity": ["userId", "mode"],
      "filter": { "field": "passed", "op": "eq", "value": true },
      "metrics": {
        "user_max_level": { "agg": "max", "field": "level_no" }
      }
    }
  ],
  "derivedDimensions": {
    "level_bucket": {
      "type": "bucket",
      "source": "user_max_level",
      "buckets": [
        { "label": "1", "eq": 1, "order": 1 },
        { "label": "2", "eq": 2, "order": 2 },
        { "label": "3-5", "gt": 2, "lte": 5, "order": 3 },
        { "label": "6-10", "gt": 5, "lte": 10, "order": 4 }
      ]
    }
  },
  "dimensions": ["mode", "level_bucket", "bucket_order"],
  "metrics": {
    "users": { "agg": "count" }
  }
}
```

`bucket.source` 必须引用最终 rollup stage 输出的数值字段。bucket 条件支持 `eq`、`gt`、`gte`、`lt`、`lte`。一个 dataset 只有一个 bucket dimension 时，排序列默认叫 `bucket_order`；如果有多个 bucket dimension，默认排序列是 `<dimension_id>_order`，也可以用 `orderDimension` 显式指定。report 和 chart 如果要稳定排序，需要把 label 和 order 都放进 `dimensions` / `groupBy`：

```json
{
  "id": "max_level_distribution",
  "dataset": "user_max_level_distribution",
  "groupBy": ["mode", "level_bucket", "bucket_order"],
  "metrics": ["users"]
}
```

对应柱状图配置：

```json
{
  "id": "max_level_distribution",
  "title": "Max Level Distribution",
  "type": "bar",
  "report": "max_level_distribution",
  "x": "level_bucket",
  "y": "users",
  "series": "mode",
  "sort": "bucket_order",
  "barMode": "grouped"
}
```

`cohort` dataset 也可以使用 `stages`。例如“新用户生命周期平均时长”可以先按 `sessionId` 取 session 最大时长，再按 `userId` 汇总用户总时长，最后对用户求平均：

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

## Payload 建议

第一版建议事件 payload 保持扁平结构：

```json
{
  "level_id": "level_001",
  "result": "win",
  "duration_ms": 12500
}
```

不要把密钥、手机号、邮箱、完整账号标识、设备元数据或实验分组放进 payload。SDK context 已经携带身份、设备、App 和实验元数据。

## 校验

保存前请在 `Manage Pack` 中点击 `Validate`。校验会检查 JSON 结构、report 引用、chart 映射、dataset 定义、标准看板 ref，以及顶层 `version` 是否和要保存的版本一致。

保存 `active` pack 后，回到主 `Reports` 页面，选择日期范围并点击 `Run`，即可加载配置好的看板。
