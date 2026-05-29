# GameAlgo REST Client Source

Dependency-free TypeScript helper for Protocol v1.

Exports:

- `GameAlgoRestClient`
- `GameAlgoApiError`
- `GameAlgoEventTracker`
- `GameAlgoExperimentExecutor`
- `GameAlgoConfigReader`
- `createEvent`
- Protocol v1 TypeScript types

The helper keeps an in-memory snapshot after `start` or `fetchConfig`. Game logic should prefer local reads through `client.executor(key)` and `client.config`.

`client.tracker` owns an in-memory event queue, periodic flush, and one-batch retry. It does not own durable event storage or process lifecycle; server-side integrators that require guaranteed delivery should wrap it with their own persistence policy.
