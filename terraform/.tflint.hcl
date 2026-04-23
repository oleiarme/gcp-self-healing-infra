plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

config {
  format     = "compact"
  call_module_type = "all"
}

plugin "google" {
  enabled = true
  version = "0.31.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}
