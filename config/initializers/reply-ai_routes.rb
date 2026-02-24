# config/initializers/reply-ai_routes.rb

Rails.application.routes.prepend do
  root to: 'landing#index', as: :reply_ai_marketing_root
  get '/signup' => 'landing#signup', as: :reply_ai_signup
  post '/signup' => 'landing#create_account', as: :signup_process
  
  # Callback de MercadoLibre (Ruta absoluta para evitar prefijos)
  get '/callback' => 'landing#meli_callback', as: :callback
  
  get '/dashboard' => 'landing#dashboard', as: :reply_ai_dashboard
  post '/dashboard/update' => 'landing#update_settings', as: :update_settings
  
  get '/go_to_chats' => 'landing#go_to_chats', as: :go_to_chats
end