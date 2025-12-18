const { Kafka } = require("kafkajs");
const express = require("express");
const client = require("prom-client");

const KAFKA_BROKER = process.env.KAFKA_BROKER || "kafka:9092";
const KAFKA_TOPIC = process.env.KAFKA_TOPIC || "app_cdc";
const KAFKA_GROUP = process.env.KAFKA_GROUP || "cdc-consumer";
const PORT = Number(process.env.METRICS_PORT || 9102);

client.collectDefaultMetrics();

const cdcCounter = new client.Counter({
    name: "cdc_events_total",
    help: "Total CDC row change events consumed",
    labelNames: ["table", "op"]
});

function parseJsonSafely(buf) {
    // Bail out early if it doesn't look like JSON text.
    if (!buf || buf.length === 0) return { ok: false, reason: "empty" };

    const first = buf[0];
    if (first !== 0x7b && first !== 0x5b) {
        // not "{" or "["
        return { ok: false, reason: "non_json_frame" };
    }

    const raw = buf.toString("utf8");
    try {
        return { ok: true, value: JSON.parse(raw), raw };
    } catch {
        return { ok: false, reason: "json_parse_error", raw };
    }
}

function classifyEvent(obj) {
    if (!obj || typeof obj !== "object") return { kind: "unknown" };

    // TiCDC resolved-ts / watermarks
    if (obj.t === 3 && obj.ts) return { kind: "control" };

    // Canal JSON row change: has database/table/type + data array
    const hasCanalShape =
        typeof obj.database === "string" &&
        typeof obj.table === "string" &&
        typeof obj.type === "string" &&
        Array.isArray(obj.data);

    if (hasCanalShape) {
        if (obj.isDdl) return { kind: "control" };

        const t = obj.type.toLowerCase();
        const op =
            t === "insert" ? "insert" :
                t === "update" ? "update" :
                    t === "delete" ? "delete" :
                        "unknown";

        return { kind: "row", op, table: obj.table, event: obj };
    }

    // (Optional) open-protocol events
    if (obj.u || obj.d) {
        const op = obj.d ? "delete" : "insert_update";
        return { kind: "row", op, table: "unknown", event: obj };
    }

    return { kind: "unknown" };
}

async function main() {
    // Metrics endpoint
    const app = express();
    app.get("/metrics", async (_req, res) => {
        res.set("Content-Type", client.register.contentType);
        res.end(await client.register.metrics());
    });
    app.get("/healthz", (_req, res) => res.json({ ok: true }));
    app.listen(PORT, () =>
        console.log(JSON.stringify({ level: "info", msg: "metrics server started", port: PORT }))
    );

    const kafka = new Kafka({ clientId: "cdc-consumer", brokers: [KAFKA_BROKER] });
    const consumer = kafka.consumer({ groupId: KAFKA_GROUP });

    await consumer.connect();
    await consumer.subscribe({ topic: KAFKA_TOPIC, fromBeginning: true });

    console.log(JSON.stringify({ level: "info", msg: "consumer started", broker: KAFKA_BROKER, topic: KAFKA_TOPIC, group: KAFKA_GROUP }));

    await consumer.run({
        eachMessage: async ({ topic, partition, message }) => {
            const buf = message.value;

            const parsed = parseJsonSafely(buf);
            if (!parsed.ok) {
                // ignore control/binary frames (don’t count as errors)
                // But log occasionally for visibility:
                if (parsed.reason !== "non_json_frame") {
                    console.log(JSON.stringify({
                        level: "warn",
                        msg: "dropped_message",
                        reason: parsed.reason,
                        topic,
                        partition,
                        preview: (parsed.raw || "").slice(0, 200)
                    }));
                }
                return;
            }

            const obj = parsed.value;
            const classified = classifyEvent(obj);

            if (classified.kind === "control") {
                // ignore resolved-ts, keep logs light
                return;
            }
            if (classified.kind === "row") {
                const table = classified.table || "unknown";
                const op = classified.op || "unknown";

                console.log(JSON.stringify({
                    level: "info",
                    msg: "cdc_event",
                    table,
                    op,
                    ts: new Date().toISOString(),
                    event: classified.event
                }));

                cdcCounter.inc({ table, op }, 1);
                return;
            }

            // Unknown JSON message type
            console.log(JSON.stringify({
                level: "warn",
                msg: "unknown_cdc_message",
                topic,
                partition,
                preview: JSON.stringify(obj).slice(0, 300)
            }));
        }
    });
}

main().catch((err) => {
    console.error(JSON.stringify({ level: "error", msg: "fatal", err: String(err), stack: err?.stack }));
    process.exit(1);
});
