- **Sticky filter pill on the RSS rows and in synced preferences.**
  `/rss_list_subscriptions` subscriptions and folders carry `default_filter`
  (`all` | `unread` | `favorite`, default `unread`), settable through
  `/rss_update_subscription` and `/rss_update_folder`; `/set_preferences`
  accepts `filter:feeds:all` and one `filter:mail:<folder>` key per mail
  folder (`all` | `unread` | `flagged`) in the `app` map.
