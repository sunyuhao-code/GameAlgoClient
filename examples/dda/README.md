# DDA 策略模板

`level-dda.js` 和 `level-dda.lua` 是同一套关卡 DDA 策略的 JavaScript / Lua 实现。

模板把最近行为按实验配置中的 `behaviorWeights` 折算为每关摩擦分，并只输出三个稳定动作：

- `increase`：提高下一关难度。
- `keep`：保持当前难度。
- `decrease`：降低下一关难度。

游戏必须提供 Adapter，把这三个动作映射为安全的游戏参数。模板中的行为名称和权重只是默认值，可以通过实验 variant 的 config 修改，不需要改脚本：

```json
{
  "behaviorWeights": {
    "level_failed": 1,
    "level_retry": 0.75,
    "item_used": 0.25,
    "mistake": 0.5
  },
  "minRecentSteps": 3,
  "decreaseThreshold": 0.8,
  "increaseThreshold": 0
}
```

发布时使用对应客户端能执行的语言：

```bash
gamealgo script publish examples/dda/level-dda.js --message "DDA template v1" --json
gamealgo script publish examples/dda/level-dda.lua --message "Lua DDA template v1" --json
```
