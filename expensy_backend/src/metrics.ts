import type { RequestHandler } from 'express';
import { collectDefaultMetrics, Counter, Histogram, type Registry } from 'prom-client';

export function httpMetrics(registry: Registry): RequestHandler {
  collectDefaultMetrics({ register: registry });
  const labelNames = ['method', 'route', 'status'] as const;
  const requests = new Counter({ name: 'http_requests_total', help: 'HTTP requests', labelNames, registers: [registry] });
  const duration = new Histogram({
    name: 'http_request_duration_seconds',
    help: 'HTTP request duration in seconds',
    labelNames,
    registers: [registry],
  });

  return (req, res, next) => {
    const stop = duration.startTimer();
    res.on('finish', () => {
      // The route template, not the URL, keeps the label set small
      const route = req.route ? req.baseUrl + req.route.path : 'unmatched';
      const labels = { method: req.method, route, status: String(res.statusCode) };
      requests.inc(labels);
      stop(labels);
    });
    next();
  };
}
