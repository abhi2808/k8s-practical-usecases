prometheus:
  prometheusSpec:
    externalLabels:
      awsAccount: "${aws_account_label}"
      clusterName: "${cluster_name_label}"
    remoteWrite:
      - url: "${remote_write_url}"
    retention: ${retention}

alertmanager:
  enabled: false

grafana:
  enabled: false

nodeExporter:
  enabled: true

kubeStateMetrics:
  enabled: true
