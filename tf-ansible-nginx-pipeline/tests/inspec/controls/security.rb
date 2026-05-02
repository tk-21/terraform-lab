# =============================================================================
# InSpec: インフラのセキュリティポリシー準拠確認
# 設計思想: 「こうあるべき」をコードで表現し、継続的に検証する
# これにより手動確認を排除し、ポリシー逸脱を自動検知できる
# =============================================================================

# EC2インスタンスのセキュリティ確認
control 'ec2-sg-no-inbound-ssh' do
  impact 1.0
  title 'EC2セキュリティグループにSSH(22)インバウンドが存在しないこと'
  desc 'SSMセッションマネージャーを使用するため、SSH接続は不要かつ禁止'

  aws_security_groups.where(group_name: /handson-dev-ec2/).entries.each do |sg|
    describe aws_security_group(group_id: sg.group_id) do
      it { should_not have_inbound_rule(port: 22) }
      it { should_not have_inbound_rule(port: 3389) } # RDPも禁止
    end
  end
end

control 'ec2-ebs-encrypted' do
  impact 1.0
  title 'EC2のEBSボリュームが暗号化されていること'
  desc '静止時暗号化はセキュリティ要件'

  aws_ec2_instances.where(tags: { 'Project' => 'handson' }).instance_ids.each do |id|
    describe aws_ec2_instance(id) do
      it { should have_root_volume_encrypted }
    end
  end
end

control 's3-tfstate-not-public' do
  impact 1.0
  title 'tfstateバケットがパブリックアクセスブロックされていること'
  desc 'tfstateにはシークレット情報が含まれるため、公開厳禁'

  describe aws_s3_bucket(bucket_name: 'handson-dev-tfstate') do
    it { should have_access_control_list_enabled }
    it { should_not be_public }
    it { should have_default_encryption_enabled }
  end
end

control 'iam-no-wildcard-actions' do
  impact 0.7
  title 'IAMポリシーにワイルドカードアクションが存在しないこと'

  # handsonプロジェクトのカスタムポリシーを全て確認
  aws_iam_policies.where(scope: 'Local').entries
    .select { |p| p.policy_name.start_with?('handson-') }
    .each do |policy|
      describe aws_iam_policy(policy_arn: policy.arn) do
        it { should_not have_statement(Action: '*') }
      end
    end
end
