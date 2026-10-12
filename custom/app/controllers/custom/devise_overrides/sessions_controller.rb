# frozen_string_literal: true

# Limpia la sesión Warden del scope user al hacer logout.
# El logout de devise_token_auth solo invalida el token de la API y deja viva
# la sesión Rails creada por el flujo signup/OAuth; sin esto, esa identidad
# sobrevive al logout y sigue influyendo en requests posteriores del navegador.
# Se engancha vía `prepend_mod_with` (DeviseOverrides::SessionsController).
module Custom::DeviseOverrides::SessionsController
  def destroy
    sign_out(:user)
    super
  end
end
