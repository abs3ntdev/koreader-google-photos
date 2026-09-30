// Container healthcheck: GET http://127.0.0.1:$PORT/healthz, exit 0 on 200.
const port = process.env.PORT || "8787";
try {
  const res = await fetch(`http://127.0.0.1:${port}/healthz`, { signal: AbortSignal.timeout(4000) });
  process.exit(res.ok ? 0 : 1);
} catch {
  process.exit(1);
}
