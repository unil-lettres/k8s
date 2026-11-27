path "{{ .Values.init.kv_path }}/*" { capabilities = ["create","read","update","patch","delete","list"] }
