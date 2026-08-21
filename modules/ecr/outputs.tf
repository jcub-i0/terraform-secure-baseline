output "repositories" {
  description = "Metadata for managed ECR repositories keyed by repository name."

  value = {
    for repository_name, repository in aws_ecr_repository.repositories : repository_name => {
      arn            = repository.arn
      name           = repository.name
      repository_url = repository.repository_url
      registry_id    = repository.registry_id
    }
  }
}
