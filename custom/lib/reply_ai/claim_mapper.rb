module ReplyAi
  # Normaliza un claim de la API de ML al modelo MeliClaim.
  # Compartido entre el webhook (claims_webhook) y el sync (claims/sync).
  module ClaimMapper
    module_function

    def map(data, account_id)
      {
        account_id: account_id,
        claim_id: data['id'],
        resource: data['resource'],
        resource_id: data['resource_id'],
        claim_type: data['type'],
        stage: data['stage'],
        status: data['status'],
        reason_id: data['reason_id'],
        players: data['players'] || [],
        expected_resolutions: data['expected_resolutions'] || [],
        affects_reputation: data['affects_reputation'] || false,
        raw_data: data
      }
    end
  end
end
