# Bedrock KB が格納するベクトル・本文・メタデータの index 形式を定義する。
variable "vector_dimension" {
  type    = number
  default = 1024
}

resource "opensearch_index" "kb" {
  name      = var.aoss_index_name
  index_knn = true

  # ベクトル検索に必要な field 定義を mappings JSON としてまとめて渡す。
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
