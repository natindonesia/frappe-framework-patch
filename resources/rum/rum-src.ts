// Fayolex RUM bundle — DevOps-owned, injected by nginx sub_filter.
// Configurable via window.__RUM_CONFIG (defaults below); no app-code changes.
import { WebTracerProvider, BatchSpanProcessor, BatchSpanProcessorConfig } from '@opentelemetry/sdk-trace-web';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { ZoneContextManager } from '@opentelemetry/context-zone';
import { registerInstrumentations, Instrumentation } from '@opentelemetry/instrumentation';
import { FetchInstrumentation } from '@opentelemetry/instrumentation-fetch';
import { XMLHttpRequestInstrumentation } from '@opentelemetry/instrumentation-xml-http-request';
import { DocumentLoadInstrumentation } from '@opentelemetry/instrumentation-document-load';
import { resourceFromAttributes, defaultResource } from '@opentelemetry/resources';
import {
  SEMRESATTRS_SERVICE_NAME,
  SEMRESATTRS_DEPLOYMENT_ENVIRONMENT,
} from '@opentelemetry/semantic-conventions';
import { Sampler, SamplingDecision, SamplingResult } from '@opentelemetry/sdk-trace-base';
import { onLCP, onINP, onTTFB, onCLS } from 'web-vitals';

interface RumConfig {
  endpoint: string;
  serviceName: string;
  environment: string;
  sampleRate: number;
  ignoredUrls: RegExp[];
}

declare global {
  interface Window {
    __RUM_CONFIG?: Partial<RumConfig>;
    __RUM_DISABLED__?: boolean;
  }
}

const cfg: RumConfig = Object.assign(
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

if (!window.__RUM_DISABLED__) {
  const rateSampler: Sampler = {
    shouldSample(
      _context,
      traceId,
      _spanName,
      _spanKind,
      attributes,
      _links
    ): SamplingResult {
      // SDK 2.x renamed RECORD_AND_SAMPLE -> RECORD_AND_SAMPLED
      return Math.random() < cfg.sampleRate
        ? { decision: SamplingDecision.RECORD_AND_SAMPLED, traceId, attributes }
        : { decision: SamplingDecision.NOT_RECORD, traceId };
    },
    toString: () => `RUMRateSampling(${cfg.sampleRate})`,
  };

  const exporter = new OTLPTraceExporter({
    url: `${cfg.endpoint}/v1/traces`,
    // beacon-style resilience: keep payloads small so retries stay cheap
    concurrencyLimit: 2,
  });

  const bspConfig: BatchSpanProcessorConfig = {
    maxQueueSize: 100,
    maxExportBatchSize: 20,
    scheduledDelayMillis: 5000,
  };

  // SDK 2.x: span processors are constructor arguments; addSpanProcessor is gone.
  const provider = new WebTracerProvider({
    spanProcessors: [new BatchSpanProcessor(exporter, bspConfig)],
    sampler: rateSampler,
    resource: defaultResource().merge(
      resourceFromAttributes({
        [SEMRESATTRS_SERVICE_NAME]: cfg.serviceName,
        [SEMRESATTRS_DEPLOYMENT_ENVIRONMENT]: cfg.environment,
        'user_agent.original': navigator.userAgent,
        'rum.instrumentation.version': '2',
        // Client-side absolute clock is NOT trusted downstream: the ingest
        // collector anchors every span with rum.received_time (server clock).
      })
    ),
  });

  provider.register({ contextManager: new ZoneContextManager() });

  // debug hook (kept: harmless, useful for DevOps triage)
  (window as unknown as Record<string, unknown>).__rum = { provider };

  const instrumentations: Instrumentation[] = [
    new DocumentLoadInstrumentation(), // PerformanceNavigationTiming spans
    new FetchInstrumentation({ ignoreUrls: cfg.ignoredUrls, clearTimingResources: false }),
    new XMLHttpRequestInstrumentation({ ignoreUrls: cfg.ignoredUrls }),
  ];
  registerInstrumentations({ instrumentations, tracerProvider: provider });

  // Web Vitals: user-perceived experience metrics, each as its own span.
  const tracer = provider.getTracer('rum-web-vitals');
  const sent = new Set<string>();
  const report = (
    metric: { id: string; value: number; delta: number; rating: string; entries?: unknown[]; pagePath?: string },
    name: string
  ): void => {
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
        'webvital.page': metric.pagePath ?? location.pathname,
      },
    });
    span.end(performance.now());
  };

  onTTFB((m) => report(m, 'rum.ttfb'));
  onLCP((m) => report(m, 'rum.lcp'));
  onINP((m) => report(m, 'rum.inp'));
  onCLS((m) => report(m, 'rum.cls'));

  // Flush on hide (mobile) / pagehide (desktop) so last vitals aren't lost.
  ['visibilitychange', 'pagehide'].forEach((ev) =>
    document.addEventListener(ev, () => window.dispatchEvent(new Event('rum-flush')), {
      once: ev === 'pagehide',
    })
  );
}
