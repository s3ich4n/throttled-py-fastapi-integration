from enum import StrEnum

from opentelemetry import metrics
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.metrics.view import ExplicitBucketHistogramAggregation, View

from fastapi import FastAPI, Path
from fastapi.responses import JSONResponse
from throttled import Throttled, rate_limiter
from throttled.asyncio import Throttled as AsyncThrottled
from throttled.asyncio.contrib.otel import AsyncOTelHook
from throttled.contrib.otel import OTelHook

duration_view = View(
    instrument_name="throttled.duration",
    aggregation=ExplicitBucketHistogramAggregation(
        boundaries=[
            0.000005,  # 5μs
            0.00001,  # 10μs
            0.000025,  # 25μs
            0.00005,  # 50μs
            0.0001,  # 100μs
            0.00025,  # 250μs
            0.0005,  # 500μs
            0.001,  # 1ms
            0.005,  # 5ms
            0.01,  # 10ms
        ]
    ),
)

reader = PeriodicExportingMetricReader(
    OTLPMetricExporter(endpoint="otel-collector:4317", insecure=True),
    export_interval_millis=5000,
)
metrics.set_meter_provider(MeterProvider(metric_readers=[reader], views=[duration_view]))

meter = metrics.get_meter("throttled-example")
hook = OTelHook(meter)
async_hook = AsyncOTelHook(meter)


class Algorithm(StrEnum):
    TOKEN_BUCKET = "token_bucket"
    FIXED_WINDOW = "fixed_window"
    SLIDING_WINDOW = "sliding_window"
    LEAKING_BUCKET = "leaking_bucket"
    GCRA = "gcra"


sync_throttles: dict[Algorithm, Throttled] = {
    algo: Throttled(
        key=f"/sync/{algo}/pay",
        using=algo.value,
        quota=rate_limiter.per_min(500),
        hooks=[hook],
    )
    for algo in Algorithm
}

async_throttles: dict[Algorithm, Throttled] = {
    algo: AsyncThrottled(
        key=f"/async/{algo}/pay",
        using=algo.value,
        quota=rate_limiter.per_min(500),
        hooks=[async_hook],
    )
    for algo in Algorithm
}

app = FastAPI()


@app.post("/sync/{algorithm}/pay")
def sync_pay(algorithm: Algorithm = Path(...)):
    result = sync_throttles[algorithm].limit()
    if result.limited:
        return JSONResponse(
            status_code=429,
            content={"detail": "요청이 너무 많습니다. 잠시 후 다시 시도해주세요."},
            headers={"Retry-After": str(result.state.retry_after)},
        )
    return {"message": "결제완료"}


@app.post("/async/{algorithm}/pay")
async def async_pay(algorithm: Algorithm = Path(...)):
    result = await async_throttles[algorithm].limit()
    if result.limited:
        return JSONResponse(
            status_code=429,
            content={"detail": "요청이 너무 많습니다. 잠시 후 다시 시도해주세요."},
            headers={"Retry-After": str(result.state.retry_after)},
        )
    return {"message": "결제완료"}
