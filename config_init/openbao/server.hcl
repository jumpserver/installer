ui = true
disable_mlock = true

storage "raft" {
  path = "/openbao/file"
  node_id = "openbao"
}

listener "tcp" {
  address = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable = false
  tls_disable_client_certs = true
  tls_cert_file = "/openbao/tls/server.crt"
  tls_key_file = "/openbao/tls/server.key"
}

api_addr = "https://openbao:8200"
cluster_addr = "https://openbao:8201"
