# infrastructure/modules/app-site-association/variables.tf

variable "domain_name" {
  type        = string
  description = "The app's web domain (e.g. wynn.cn): serves https://<domain>/.well-known/apple-app-site-association. Must be the name of a public Route53 zone in this account, already DELEGATED at the registrar (the ACM DNS validation waits on it)."
}

variable "app_ids" {
  type        = list(string)
  description = "<Apple team id>.<bundle id> of every app the domain vouches for (public: they ship in every binary)."
}

variable "applinks_components" {
  type = list(object({
    path    = string
    comment = string
  }))
  description = "Universal-link paths the app claims (applinks.details[].components): iOS opens these URLs in the app instead of Safari."
}

variable "webcredentials" {
  type        = bool
  description = "Declare the apps under webcredentials: required for passkeys bound to this domain (auth's AUTH_WEBAUTHN_RP_ID) and for shared web credentials."
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to created resources."
  default     = {}
}
