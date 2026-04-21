output "dataset_name" {
  description = "Name of the DataBrew dataset"
  value       = aws_databrew_dataset.raw.name
}

output "recipe_name" {
  description = "Name of the DataBrew recipe"
  value       = aws_databrew_recipe.main.name
}

output "project_name" {
  description = "Name of the DataBrew project"
  value       = aws_databrew_project.main.name
}

output "job_name" {
  description = "Name of the DataBrew job"
  value       = aws_databrew_job.main.name
}

output "schedule_name" {
  description = "Name of the DataBrew schedule"
  value       = aws_databrew_schedule.main.name
}
