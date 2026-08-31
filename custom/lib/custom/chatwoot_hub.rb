module Custom::ChatwootHub
  # Blindaje enterprise (custom layer).
  #
  # 1. base_url: nunca hablar con el hub real de Chatwoot. URL rota por defecto
  #    (el ping a /ping falla de forma determinista => @instance_info nil =>
  #    CheckNewVersionsJob#update_plan_info no sobrescribe INSTALLATION_PRICING_PLAN).
  #    CHATWOOT_HUB_URL queda disponible para apuntar a un hub propio futuro.
  #    upstream (Enterprise::ChatwootHub) solo honra el env en development; este
  #    override aplica en todos los entornos y precede a Enterprise en el chain
  #    (ChatwootApp.extensions = ['enterprise', 'custom']).
  def base_url
    ENV.fetch('CHATWOOT_HUB_URL', 'http://localhost#')
  end

  # 2. pricing_plan: Internal::ReconcilePlanConfigService desactiva los features
  #    premium de todas las cuentas cuando el plan leído es 'community'. Mientras
  #    exista el overlay enterprise/ devolvemos 'enterprise' => el reconcile
  #    nunca corre, sin importar el valor de la BD.
  def pricing_plan
    return 'enterprise' if ChatwootApp.enterprise?

    super
  end
end
