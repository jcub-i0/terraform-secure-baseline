variable "vpc_id" {
  type = string
}

variable "compute_private_subnets" {
  type = map(any)
}