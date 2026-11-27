variable "region" {
  type        = string
  description = "AWS region the target instance and its SSM Agent are registered in."
}

variable "instance_id" {
  type        = string
  description = "EC2 instance ID to run the commands on."
}

variable "commands" {
  type        = list(string)
  description = "Shell commands to run on the instance via SSM Run Command (AWS-RunShellScript)."
}

variable "triggers" {
  type        = map(string)
  description = "Additional triggers merged with the ones this module always sets (instance_id and a hash of commands) -- use for conditions outside of those two that should also force a re-run."
  default     = {}
}

variable "wait_timeout_seconds" {
  type        = number
  description = "How long to wait for the instance to register with SSM before giving up."
  default     = 300
}

variable "poll_interval_seconds" {
  type        = number
  description = "How often to poll SSM for the instance's registration status while waiting."
  default     = 10
}
