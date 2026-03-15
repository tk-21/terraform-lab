variable "vector_dimension" {
  type    = number
  default = 1024
}

resource "opensearch_index" "kb" {
  name      = var.aoss_index_name
  index_knn = true

  # OpenSearch provider は settings/body を持たず、mappings(JSON文字列)で渡す
  mappings = jsonencode({
    properties = {
      vector = {
        type      = "knn_vector"
        dimension = var.vector_dimension
        method = {
          name       = "hnsw"
          engine     = "faiss"
          space_type = "l2"
        }
      }
      text = {
        type = "text"
      }
      metadata = {
        type  = "text"
        index = false
      }
    }
  })

  depends_on = [
    aws_opensearchserverless_collection.kb,
    aws_opensearchserverless_access_policy.kb,
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network
  ]
}
