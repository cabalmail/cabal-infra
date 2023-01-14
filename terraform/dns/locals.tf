locals {
  lambdas  = [
    "nodejs",        "python",           "assign_osid",
    "list",          "new",              "revoke",
    "delete_folder", "fetch_attachment", "fetch_inline_image",
    "fetch_message", "list_attachments", "list_envelopes",
    "list_folders",  "move_messages",    "new_folder",
    "set_flag"
  ]
  base_url = "https://api.github.com/repos/cabalmail/cabal-infra/actions/workflows"
}