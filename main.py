from fastapi import FastAPI
from fastapi.responses import JSONResponse
from throttled import Throttled, rate_limiter


throttle = Throttled(
    key="/api/pay",
    quota=rate_limiter.per_min(5),
)

app = FastAPI()


@app.post("/api/pay")
def pay():
    result = throttle.limit()
    if result.limited:
        return JSONResponse(
            status_code=429,
            content={"detail": "Try again later."},
            headers={"Retry-After": str(result.state.retry_after)},
        )
    return {"message": "Payment success"}
