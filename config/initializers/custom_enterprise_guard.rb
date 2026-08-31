# frozen_string_literal: true

# Blindaje enterprise (custom layer) — ver TECHNICAL.md "Enterprise sin licencia".
#
# ChatwootApp no usa prepend_mod_with (a diferencia de ChatwootHub), por lo que
# el módulo Custom::ChatwootApp se precede explícitamente al singleton acá.
# Custom::ChatwootHub se engancha solo vía prepend_mod_with en lib/chatwoot_hub.rb.
Rails.application.config.to_prepare do
  ChatwootApp.singleton_class.prepend(Custom::ChatwootApp) if defined?(Custom::ChatwootApp)
end
