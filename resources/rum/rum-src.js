// Fayolex RUM bundle — DevOps-owned, injected by nginx sub_filter.
// Configurable via window.__RUM_CONFIG (defaults below); no app-code changes.
import { WebTracerProvider, BatchSpanProcessor } from '@opentelemetry/sdk-trace-web';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { ZoneContextManager } from '@opentelemetry/context-zone';
import { registerInstrumentations } from '@opentelemetry/instrumentation';
import { FetchInstrumentation } from '@opentelemetry/instrumentation-fetch';
import { XMLHttpRequestInstrumentation } from '@opentelemetry/instrumentation-xml-http-request';
import { DocumentLoadInstrumentation } from '@opentelemetry/instrumentation-document-load';
import { resourceFromAttributes, defaultResource } from '@opentelemetry/resources';
import {
  SEMRESATTRS_SERVICE_NAME,
  SEMRESATTRS_DEPLOYMENT_ENVIRONMENT,
  SEMRESATTRS_BROWSER_USER_AGENT,
} from '@opentelemetry/semantic-conventions';
import { onLCP, onINP, onTTFB, onCLS } from 'web-vitals';

const cfg = Object.assign(
  {
    endpoint: `${location.origin}/ingest`,
    serviceName: 'fayolex-working-staging-browser',
    environment: 'staging',
    sampleRate: 1.0,
    ignoredUrls: [/api\/method\/ping$/, /socket\.io/, /__rum\.js$/, /\/ingest\//],
  },
  window.__RUM_CONFIG || {}
);

// Bots and automation: don't pollute UX baselines.
if (navigator.webdriver) {
  window.__RUM_DISABLED__ = true;
}

// Service-worker-driven page loads still emit navigation spans, which is fine.

if (!window.__RUM_DISABLED__) {
  const provider = new WebTracerProvider({
    resource: defaultResource().merge(
      resourceFromAttributes({
        [SEMRESATTRS_SERVICE_NAME]: cfg.serviceName,
        [SEMRESATTRS_DEPLOYMENT_ENVIRONMENT]: cfg.environment,
        'user_agent.original': navigator.userAgent,
        'rum.instrumentation.version': '1',
        // Client-side absolute clock is NOT trusted downstream: the ingest
        // collector anchors every span with rum.received_time (server clock).
      })
    ),
    sampler: {
      shouldSample: (context, traceId) =>
        Math.random() < cfg.sampleRate
          ? { decision: 1 }
          : { decision: 0 },
      toString: () => `RUMRateLimiting(${cfg.sampleRate})`,
    },
  });

  provider.addSpanProcessor(
    new BatchSpanProcessor(
      new OTLPTraceExporter({
        url: `${cfg.endpoint}/v1/traces`,
        // beacon-style resilience: keep payloads small so retries stay cheap
        concurrencyLimit: 2,
      }),
      {
        maxQueueSize: 100,
        maxExportBatchSize: 20,
        scheduledDelayMillis: 5000,
      }
    )
  );

  provider.register({ contextManager: new ZoneContextManager() });

  registerInstrumentations({
    instrumentations: [
      new DocumentLoadInstrumentation(), // PerformanceNavigationTiming spans
      new FetchInstrumentation({ ignoreUrls: cfg.ignoredUrls, clearTimingResources: false }),
      new XMLHttpRequestInstrumentation({ ignoreUrls: cfg.ignoredUrls }),
    ],
  });

  // Web Vitals: user-perceived experience metrics, each as its own span.
  const tracer = provider.getTracer('rum-web-vitals');
  const sent = new Set();
  const report = (metric, name) => {
    if (sent.has(name + metric.id)) return; // avoid duplicate final reports
    sent.add(name + metric.id);
    const span = tracer.startSpan(name, {
      startTime: performance.now() - metric.value,
      attributes: {
        'webvital.id': metric.id,
        'webvital.rating': metric.rating,
        'webvital.value_ms': metric.value,
        'webvital.delta_ms': metric.delta,
        'webvital.entries': metric.entries ? metric.entries.length : 0,
        'webvital.page': metric.pagePath || location.pathname,
      },
    });
    span.end(performance.now());
  };

  // Report both on interaction and on page lifecycle events.
  onTTFB((m) => report(m, 'rum.ttfb'));
  onLCP((m) => report(m, 'rum.lcp'));
  onINP((m) => report(m, 'rum.inp'));
  onCLS((m) => report(m, 'rum.cls'));
  // Flush on hide (mobile) / pagehide (desktop) so last vitals aren't lost.
  const flush = () => window.dispatchEvent(new Event('rum-flush'));
  ['visibilitychange', 'pagehide'].forEach((ev) =>
    document.addEventListener(ev, flush, { once: ev === 'pagehide' })
  );
}
