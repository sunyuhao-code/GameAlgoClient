# GameAlgo REST Client Source

Dependency-free TypeScript helper for Protocol v1.

Exports:

- `GameAlgoRestClient`
- `GameAlgoApiError`
- `GameAlgoExperimentExecutor`
- `GameAlgoConfigReader`
- `createEvent`
- Protocol v1 TypeScript types

The helper keeps an in-memory snapshot after `start` or `fetchConfig`. Game logic should prefer local reads through `client.executor(key)` and `client.config`.

This helper is intentionally small. It does not own durable storage, background retry queues, or process lifecycle. Server-side integrators should wrap it with their own persistence/retry policy when needed.
