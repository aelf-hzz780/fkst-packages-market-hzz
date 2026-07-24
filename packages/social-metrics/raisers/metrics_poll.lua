-- Cron raiser: periodic metrics sweep. Emits a tick the collect department turns into a read.
-- Interval is a placeholder; a host can also raise metrics_request on demand for a fresh read.
return {
  type = "cron",
  interval = "6h",
  produces = "metrics_tick",
}
