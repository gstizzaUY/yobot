module LandingHelper
  # Genera un encabezado de columna ordenable para la tabla de productos
  def sort_link(col, label, current_col, current_dir, q)
    next_dir = (current_col == col && current_dir == 'asc') ? 'desc' : 'asc'
    arrow    = current_col == col ? (current_dir == 'asc' ? ' ↑' : ' ↓') : ''
    link_to "#{label}#{arrow}",
            reply_ai_dashboard_path(tab: 'prods', sort: col, dir: next_dir, q: q),
            class: 'hover:text-[#fd5101] transition'
  end

  # Extrae el SKU del array attributes_data (campo SELLER_SKU de ML)
  def sku_for(product)
    return nil if product.attributes_data.blank?
    attr = product.attributes_data.find { |a| a['id'] == 'SELLER_SKU' }
    attr&.[]('value_name').presence
  end

  # Formatea precio con símbolo de moneda
  def format_price(amount, currency)
    return '—' if amount.nil?
    symbol = currency == 'BRL' ? 'R$' : '$'
    "#{symbol} #{number_with_delimiter(amount.to_f.round(2), delimiter: '.', separator: ',')}"
  end
end
