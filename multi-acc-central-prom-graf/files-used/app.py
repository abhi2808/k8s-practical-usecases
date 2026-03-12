from flask import Flask, jsonify
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
import time
import random

app = Flask(__name__)

# ── Custom Prometheus Metrics ──────────────────────────────────────────
# Counter: total requests per endpoint
REQUEST_COUNT = Counter(
    'sample_app_requests_total',
    'Total number of requests',
    ['endpoint', 'status']
)

# Histogram: request duration in seconds
REQUEST_LATENCY = Histogram(
    'sample_app_request_duration_seconds',
    'Request duration in seconds',
    ['endpoint']
)

# Counter: simulated orders placed
ORDERS_TOTAL = Counter(
    'sample_app_orders_total',
    'Total number of orders placed',
    ['product']
)

# Gauge: currently active users (simulated)
ACTIVE_USERS = Gauge(
    'sample_app_active_users',
    'Number of currently active users'
)

# ── Routes ─────────────────────────────────────────────────────────────
@app.route('/')
def home():
    start = time.time()
    ACTIVE_USERS.set(random.randint(10, 100))
    REQUEST_COUNT.labels(endpoint='/', status='200').inc()
    REQUEST_LATENCY.labels(endpoint='/').observe(time.time() - start)
    return jsonify({"message": "Sample App Running", "client": "account-a"})

@app.route('/order')
def order():
    start = time.time()
    products = ['widget', 'gadget', 'doohickey']
    product = random.choice(products)
    ORDERS_TOTAL.labels(product=product).inc()
    REQUEST_COUNT.labels(endpoint='/order', status='200').inc()
    REQUEST_LATENCY.labels(endpoint='/order').observe(time.time() - start)
    return jsonify({"order": product, "status": "placed"})

@app.route('/metrics')
def metrics():
    return generate_latest(), 200, {'Content-Type': CONTENT_TYPE_LATEST}

@app.route('/health')
def health():
    return jsonify({"status": "healthy"}), 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
