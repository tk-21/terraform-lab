TF_DIR=terraform/envs/dev
ANS_DIR=ansible

tf-init:
	cd $(TF_DIR) && terraform init

tf-apply:
	cd $(TF_DIR) && terraform plan -out tfplan && terraform apply tfplan

tf-destroy:
	cd $(TF_DIR) && terraform destroy

deploy:
	cd $(ANS_DIR) && ansible-playbook -i localhost, playbooks/deploy.yml

migrate:
	cd $(ANS_DIR) && ansible-playbook -i localhost, playbooks/migrate.yml

output:
	cd $(TF_DIR) && terraform output
