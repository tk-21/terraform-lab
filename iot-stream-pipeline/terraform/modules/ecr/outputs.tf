output "processor_repository_url" {
  value = aws_ecr_repository.processor.repository_url
}

output "reader_repository_url" {
  value = aws_ecr_repository.reader.repository_url
}
