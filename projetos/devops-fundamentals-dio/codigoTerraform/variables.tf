variable "location" {
  description = "Região dos recursos do site; não altera a região do backend."
  type        = string
  default     = "westeurope"
}

variable "tags" {
  description = "Tags dos recursos do site."
  type        = map(string)
  default = {
    Ambiente   = "Desenvolvimento"
    Integracao = "Processo Devops"
    Compania   = "Aula Devops"
    Area       = "Marketing"
  }
}
