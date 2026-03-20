config:
  inputs: |
    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        multiline.parser  docker, cri
        Tag               kube.*
        Mem_Buf_Limit     50MB
        Skip_Long_Lines   On

  filters: |
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_URL            https://kubernetes.default.svc:443
        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        Kube_Tag_Prefix     kube.var.log.containers.
        Merge_Log           On
        Keep_Log            Off
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On

    [FILTER]
        Name    record_modifier
        Match   kube.*
        Record  awsAccount ${aws_account_label}
        Record  clusterName ${cluster_name_label}

  outputs: |
    [OUTPUT]
        Name         loki
        Match        kube.*
        Host         ${loki_host}
        Port         ${loki_port}
        Labels       job=fluent-bit,awsAccount=${aws_account_label},clusterName=${cluster_name_label}
        line_format  json
