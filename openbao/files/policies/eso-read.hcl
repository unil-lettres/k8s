path "{{ .Values.init.kv_path }}/data/*"     { capabilities = ["read"] }
path "{{ .Values.init.kv_path }}/metadata/*" { capabilities = ["read","list"] }
