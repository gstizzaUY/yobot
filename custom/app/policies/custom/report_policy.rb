# Overlay custom de ReportPolicy (sin tocar core).
#
# ReportPolicy (core) define view? = @account_user.administrator? y el overlay
# enterprise agrega los roles custom con el permiso 'report_manage'.
# Acá habilitamos además a los AGENTES: el menú de Informes ya muestra Resumen,
# Conversaciones, Agentes, Etiquetas, Bandeja y Equipo para agentes (middleware),
# y este overlay permite que los endpoints de datos respondan (antes: 401).
#
# Nota: view? es genérico para todos los reportes; el menú sigue ocultando
# CSAT / SLA / Bot para agentes (esos endpoints, además, tienen sus propias
# policies enterprise). Los endpoints de bot_metrics/bot_summary quedan
# accesibles por API para agentes aunque no estén en el menú.
module Custom::ReportPolicy
  def view?
    super || @account_user&.agent?
  end
end
