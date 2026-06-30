# Forzar refresco de tokens de MercadoLibre YA.
# Ejecutar en producción:
#   bundle exec rails runner custom/refresh_tokens.rb

puts "Refrescando tokens ML..."
ReplyAi::TokenRefreshWorker.new.perform
puts "Hecho. Verificá meli_credentials:"
MeliCredential.all.each do |c|
  puts "  cuenta=#{c.account_id} status=#{c.status} expira=#{c.expires_at} token=#{c.access_token&.first(30)}..."
end
