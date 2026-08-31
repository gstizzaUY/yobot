module Custom::ChatwootApp
  # Blindaje enterprise (custom layer).
  #
  # Los gates de features premium (audit_logs, sla, custom_roles, captain,
  # disable_branding, etc.) consultan ChatwootApp.self_hosted_enterprise?,
  # que upstream resuelve leyendo INSTALLATION_PRICING_PLAN de la BD
  # (config frágil: un ping exitoso del hub la sobrescribe con 'community'
  # y locked=true). Acá el gate depende solo de que exista el overlay
  # enterprise/, inmune a actualizaciones y a valores de BD.
  def self_hosted_enterprise?
    enterprise? && !chatwoot_cloud?
  end
end
