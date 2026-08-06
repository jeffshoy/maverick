output "vpc_id" {
  value = aws_vpc.build.id
}

output "subnet_id" {
  value = aws_subnet.build.id
}
