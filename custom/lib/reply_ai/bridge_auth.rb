module ReplyAi
  module BridgeAuth
    extend ActiveSupport::Concern

    BRIDGE_SECRET = ENV.fetch('BRIDGE_SECRET', nil)

    included do
      before_action :verify_bridge_auth, only: [:bridge_question, :bridge_message, :bridge_order,
                                                 :bridge_claim, :bridge_manual_response,
                                                 :bridge_seller_status, :bridge_register]
    end

    private

    def verify_bridge_auth
      token = request.headers['Authorization']&.gsub(/\ABearer /, '')
      signature = request.headers['X-Bridge-Signature']

      unless valid_bridge_request?(token, signature)
        render json: { error: 'No autorizado' }, status: :unauthorized
      end
    end

    def valid_bridge_request?(token, signature)
      return false if BRIDGE_SECRET.blank? || token.blank? || signature.blank?

      body = request.body.read
      request.body.rewind

      expected = OpenSSL::HMAC.hexdigest('SHA256', BRIDGE_SECRET, body)

      ActiveSupport::SecurityUtils.secure_compare(token, BRIDGE_SECRET) &&
        ActiveSupport::SecurityUtils.secure_compare(signature, expected)
    end

    def find_bridge_account
      ml_user_id = params[:ml_user_id].presence || request.request_parameters[:ml_user_id]
      # Cualquier credencial con ese ml_user_id (nativa, migrada o bridge): los forwards de
      # Yobot entran igual (HMAC). El tipo de ejecución lo decide la credencial (ver MeliApi.for).
      @account = Account.joins(:meli_credentials)
                        .where(meli_credentials: { ml_user_id: ml_user_id })
                        .first

      unless @account
        render json: { error: 'Seller no encontrado' }, status: :not_found
      end
    end
  end
end
