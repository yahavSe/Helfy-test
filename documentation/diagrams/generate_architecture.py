from diagrams import Diagram, Cluster, Edge
from diagrams.onprem.database import Mysql
from diagrams.onprem.queue import Kafka
from diagrams.onprem.monitoring import Grafana, Prometheus
from diagrams.elastic.elasticsearch import Elasticsearch
from diagrams.onprem.logging import Fluentbit
from diagrams.onprem.compute import Server

# -----------------------------
# Diagram visual tuning
# -----------------------------
graph_attr = {
    "fontsize": "18",
    "pad": "0.6",
    "splines": "spline",
    "nodesep": "0.55",
    "ranksep": "0.75",
}

node_attr = {
    "fontsize": "12",
}


def main():
    with Diagram(
            "TiDB CDC Architecture",
            filename="output/architecture",
            outformat="png",
            show=False,
            direction="LR",
            graph_attr=graph_attr,
            node_attr=node_attr,
    ):
        # =========================================================
        # DATA PLANE
        # =========================================================
        with Cluster("Data Plane"):
            tidb_init = Server("tidb-init\n(schema + user + seed)")

            pd = Server("PD\n:2379 / :2380")
            tikv = Server("TiKV\n:20160")
            tidb = Mysql("TiDB\n:4000")

            ticdc = Server("TiCDC\n(Changefeed)")
            kafka = Kafka("Kafka\n:9092")

            # TiDB cluster wiring
            pd >> Edge(label="metadata / placement") >> tikv
            tidb >> Edge(label="region info") >> pd
            tidb >> Edge(label="KV reads / writes") >> tikv

            # Init flow
            tidb_init >> Edge(label="SQL init") >> tidb

            # CDC flow
            pd >> Edge(label="cluster state") >> ticdc
            tikv >> Edge(label="raft change stream") >> ticdc
            ticdc >> Edge(label="row change events") >> kafka

        # =========================================================
        # OBSERVABILITY PLANE
        # =========================================================
        with Cluster("Observability Plane"):
            consumer = Server("Node.js CDC Consumer\n/metrics")
            prometheus = Prometheus("Prometheus")
            grafana = Grafana("Grafana")
            shipper = Fluentbit("Fluent Bit\n(Log Shipper)")
            elastic = Elasticsearch("Elasticsearch")

            # Kafka consumption
            kafka >> Edge(label="consume CDC topics") >> consumer

            # Metrics flow
            consumer >> Edge(label="/metrics scrape") >> prometheus
            prometheus >> Edge(label="PromQL") >> grafana

            # Logs flow
            consumer >> Edge(label="stdout JSON logs") >> shipper
            shipper >> Edge(label="index logs") >> elastic
            elastic >> Edge(label="search / query") >> grafana


if __name__ == "__main__":
    main()
