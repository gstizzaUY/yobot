# config/initializers/reply_ai_account_associations.rb
# Extiende Account con las asociaciones Reply-AI sin tocar el modelo core.

Rails.application.config.to_prepare do
  Account.class_eval do
    has_many :meli_products,    dependent: :destroy, class_name: 'MeliProduct'
    has_many :meli_categories,  dependent: :destroy, class_name: 'MeliCategory'
    has_many :meli_credentials, dependent: :destroy, class_name: 'MeliCredential'
    has_many :reply_ai_documents,    dependent: :destroy, class_name: 'ReplyAiDocument'
    has_many :reply_ai_pv_documents, dependent: :destroy, class_name: 'ReplyAiPvDocument'
  end
end
