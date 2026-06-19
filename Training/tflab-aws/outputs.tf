output "vm_app_private_ip" {
  description = "Private IP of the app VM"
  value       = aws_instance.app.private_ip
}

output "vm_db_private_ip" {
  description = "Private IP of the database VM"
  value       = aws_instance.db.private_ip
}

output "vm_win_private_ip" {
  description = "Private IP of the Windows VM"
  value       = aws_instance.win.private_ip
}

output "s3_bucket_name" {
  description = "S3 bucket name (replaces Azure Storage Account)"
  value       = aws_s3_bucket.lab.bucket
}

output "eice_id" {
  description = "EC2 Instance Connect Endpoint ID (replaces Azure Bastion). Connect via: aws ec2-instance-connect ssh --instance-id <id> --endpoint-id <eice_id>"
  value       = aws_ec2_instance_connect_endpoint.lab.id
}

output "nat_gateway_public_ip" {
  description = "NAT Gateway public IP — source IP for all outbound traffic from private subnets"
  value       = aws_eip.nat.public_ip
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.lab.id
}
