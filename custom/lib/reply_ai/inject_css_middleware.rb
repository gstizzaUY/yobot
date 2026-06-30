# lib/reply_ai/inject_css_middleware.rb
#
# Rack middleware que inyecta CSS de personalización de UI en el dashboard
# de Chatwoot sin modificar ningún archivo core.
# Se registra via config/initializers/reply_ai_middleware.rb
#
module ReplyAi
  class InjectCssMiddleware
    # CSS inyectado en cada respuesta HTML del dashboard (/app/*)
    # Usar selectores :has() + href para máxima estabilidad ante actualizaciones.
    CUSTOM_CSS = <<~'CSS'.freeze
      <style id="reply-ai-custom-css">
        /* ── Ocultar sub-items del menú Informes (dejar solo Resumen) ── */
        li.child-item:has(a[href*="/reports/conversation"]),
        li.child-item:has(a[href*="/reports/agent"]),
        li.child-item:has(a[href*="/reports/inboxes"]),
        li.child-item:has(a[href*="/reports/label"]),
        li.child-item:has(a[href*="/reports/team"]),
        li.child-item:has(a[href*="/reports/sla"]),
        li.child-item:has(a[href*="/reports/csat"]),
        li.child-item:has(a[href*="/reports/bot"]) {
          display: none !important;
        }


        /* ── Ocultar panel central de estado vacío (sin conversaciones) ── */
        main .flex.flex-col.items-center.justify-center.h-full,
        section .flex.flex-col.items-center.justify-center.h-full,
        .conversation-details-wrap + div.flex.flex-col.items-center.justify-center.h-full,
        .conversation-details-wrap ~ div.flex.flex-col.items-center.justify-center.h-full {
          display: none !important;
        }

        /* ── Ocultar sección completa Campañas ── */
        li.grid:has(a[href*="/campaigns"]) {
          display: none !important;
        }

        /* ── Ocultar sección completa Centro de ayuda ── */
        li.grid:has(a[href*="/portals"]) {
          display: none !important;
        }

        /* ── Ocultar sub-items de Ajustes (dejar solo Respuestas personalizadas) ── */
        li.child-item:has(a[href*="/settings/"]):not(:has(a[href*="/settings/canned-response"])) {
          display: none !important;
        }

        /* ── Menú de perfil: dejar solo "Cerrar sesión" + nuestro ítem custom ── */
        /* Scoped a .w-80.bottom-12 que es exclusivo del DropdownBody del perfil */
        .bottom-12.w-80 .n-dropdown-section,
        .bottom-12.w-80 .border-b.border-n-strong,
        .bottom-12.w-80 li.n-dropdown-item:not(:has(.i-lucide-power)):not(#reply-ai-config-item) {
          display: none !important;
        }

        /* ── Ocultar botón "Redactar nueva conversación" (lápiz junto al buscador) ── */
        button:has(span.i-lucide-pen-line) {
          display: none !important;
        }

        /* ── Ocultar botones de acción de contacto en panel lateral ── */
        button:has(span.i-ph-chat-circle-dots),
        button:has(span.i-ph-pencil-simple),
        button:has(span.i-ph-arrows-merge),
        button:has(span.i-ph-trash) {
          display: none !important;
        }

        /* ── Ocultar sección "Etiquetas de conversación" del panel lateral ── */
        .sidebar-labels-wrap,
        div:has(+ .sidebar-labels-wrap) {
          display: none !important;
        }

        /* ── Ocultar sección "Macros" del panel lateral ── */
        [data-reply-ai-hidden="macros"] {
          display: none !important;
        }

        /* ── Ocultar botones del reply box cuando el inbox es MercadoLibre ── */
        /* Activo solo cuando el JS detecta el inbox y agrega .reply-ai-meli-inbox al body */
        body.reply-ai-meli-inbox .reply-box .left-wrap button:has(span.i-ph-smiley-sticker),
        body.reply-ai-meli-inbox .reply-box .left-wrap button:has(span.i-ph-paperclip),
        body.reply-ai-meli-inbox .reply-box .left-wrap .file-uploads,
        body.reply-ai-meli-inbox .reply-box .left-wrap button:has(span.i-ph-microphone),
        body.reply-ai-meli-inbox .reply-box .left-wrap button:has(span.i-ph-signature) {
          display: none !important;
        }

        /* ── Ocultar botón copilot/IA (+) del top panel cuando es MercadoLibre ── */
        body.reply-ai-meli-inbox .reply-box button:has(span.i-ph-sparkle-fill) {
          display: none !important;
        }
      </style>

      <script id="reply-ai-reports-patch">
        // Parchamos el meta de la ruta overview_reports para incluir 'agent'
        // de modo que Chatwoot la muestre en la barra lateral para agentes.
        (function () {
          function patchReportsPermissions() {
            var appEl = document.getElementById('app');
            if (!appEl || !appEl.__vue_app__) {
              setTimeout(patchReportsPermissions, 300);
              return;
            }
            var router = appEl.__vue_app__.config.globalProperties.$router;
            if (!router) return;
            var routes = router.getRoutes();
            var overviewRoute = routes.find(function (r) {
              return r.name === 'account_overview_reports';
            });
            if (
              overviewRoute &&
              overviewRoute.meta &&
              overviewRoute.meta.permissions &&
              !overviewRoute.meta.permissions.includes('agent')
            ) {
              overviewRoute.meta.permissions.push('agent');
            }
          }
          patchReportsPermissions();
        })();
      </script>

      <script id="reply-ai-meli-detector">
        (function () {
          var MELI_KEYWORD = 'MercadoLibre';
          var BODY_CLASS   = 'reply-ai-meli-inbox';

          function checkInbox() {
            // InboxName renderiza: .conversation--header--actions span.truncate
            // con el texto "Pre-venta (MercadoLibre)"
            var inboxNameEl = document.querySelector(
              '.conversation--header--actions span.truncate'
            );

            if (inboxNameEl && inboxNameEl.textContent.includes(MELI_KEYWORD)) {
              document.body.classList.add(BODY_CLASS);
            } else {
              document.body.classList.remove(BODY_CLASS);
            }

            // Ocultar acordeón de Macros detectando el h5 con texto "Macros"
            // h5 tiene clase text-sm, por eso no usamos closest('.text-sm')
            // subimos: h5 → .flex.justify-between → button.drag-handle → div.text-sm (AccordionItem) → div (woot-feature-toggle)
            document.querySelectorAll('.drag-handle h5').forEach(function(h5) {
              if (h5.textContent.trim() === 'Macros') {
                var btn = h5.closest('button.drag-handle');
                if (btn && btn.parentElement && btn.parentElement.parentElement) {
                  btn.parentElement.parentElement.setAttribute('data-reply-ai-hidden', 'macros');
                }
              }
            });
          }

          var timer = null;
          var observer = new MutationObserver(function () {
            if (timer) return;
            timer = setTimeout(function () {
              timer = null;
              checkInbox();
            }, 150);
          });

          function start() {
            var app = document.getElementById('app');
            if (!app) { setTimeout(start, 200); return; }
            observer.observe(app, { childList: true, subtree: true });
            checkInbox();
          }

          start();
        })();
      </script>

    CSS

    # Script del link "Configuración Bot" — se inyecta para TODOS los usuarios.
    # getHref() usa el Vue store como fuente principal del account_id, con
    # fallback al path de la URL. Esto asegura que el link sea correcto para
    # admins que navegan entre múltiples cuentas.
    CONFIG_LINK_JS = <<~'JS'.freeze
      <script id="reply-ai-config-link">
        (function () {
          var ITEM_ID = 'reply-ai-config-item';

          function getAccountId() {
            // Fuente 1: Vue store getter (sincronizado con vue-router via vuex-router-sync)
            var appEl = document.getElementById('app');
            if (appEl && appEl.__vue_app__) {
              var store = appEl.__vue_app__.config.globalProperties.$store;
              if (store) {
                var id = store.getters['getCurrentAccountId'];
                if (id) { return id; }
              }
            }
            // Fuente 2: data-account-id del selector de cuentas del sidebar
            // Vue lo actualiza reactivamente al cambiar de cuenta
            var switcher = document.getElementById('sidebar-account-switcher');
            if (switcher && switcher.dataset && switcher.dataset.accountId) {
              return switcher.dataset.accountId;
            }
            // Fuente 3: URL path
            var m = window.location.pathname.match(/\/app\/accounts\/(\d+)/);
            if (m) { return m[1]; }
            return null;
          }

          function getHref() {
            var id = getAccountId();
            return id ? '/dashboard?account_id=' + id : '/dashboard';
          }

          function modify() {
            // Ya existe: solo actualizar href con la cuenta activa
            var existing = document.getElementById(ITEM_ID);
            if (existing) {
              var ea = existing.querySelector('a');
              if (ea) { ea.href = getHref(); }
              return;
            }

            // El dropdown está abierto cuando existe span.i-lucide-power
            var powerSpan = document.querySelector('span.i-lucide-power');
            if (!powerSpan) { return; }

            var logoutLi      = powerSpan.closest('li.n-dropdown-item');
            if (!logoutLi) { return; }

            var logoutWrapper = logoutLi.parentElement;                      // <div> CustomBrandPolicyWrapper
            var ul            = logoutWrapper && logoutWrapper.parentElement; // <ul class="n-dropdown-body">
            if (!ul || ul.tagName !== 'UL') { return; }

            var li = document.createElement('li');
            li.id        = ITEM_ID;
            li.className = 'n-dropdown-item';

            var a = document.createElement('a');
            a.href      = getHref();
            a.className = 'flex text-left rtl:text-right items-center p-2 reset-base text-sm text-n-slate-12 w-full border-0 hover:bg-n-alpha-2 rounded-lg gap-3';
            // capture:true + stopImmediatePropagation evita que cualquier listener
            // de la página intercepte la navegación
            a.addEventListener('click', function (e) {
              e.preventDefault();
              e.stopImmediatePropagation();
              window.location.href = getHref();
            }, true);

            var icon = document.createElement('span');
            icon.className = 'i-lucide-settings size-4 text-n-slate-11';
            a.appendChild(icon);
            a.appendChild(document.createTextNode(' Configuración Bot'));
            li.appendChild(a);

            ul.insertBefore(li, logoutWrapper);
          }

          setInterval(modify, 100);

          new MutationObserver(function () { modify(); })
            .observe(document.documentElement, { childList: true, subtree: true });

          modify();
        })();
      </script>
    JS

    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)

      # Solo intervenir en rutas del dashboard de Chatwoot
      path = env['PATH_INFO'].to_s
      return [status, headers, body] unless path.start_with?('/app')

      content_type = headers['Content-Type'] || headers['content-type'] || ''
      return [status, headers, body] unless content_type.include?('text/html')

      # Leer y reconstruir el body
      full_body = +''
      body.each { |chunk| full_body << chunk }
      body.close if body.respond_to?(:close)

      if full_body.include?('</head>')
        if privileged_session?(env)
          # Admins y SuperAdmins: solo inyectar el link de Configuración Bot
          full_body.sub!('</head>', "#{CONFIG_LINK_JS}</head>")
        else
          # Agentes: CSS de restricciones + todos los scripts (incluye el link)
          full_body.sub!('</head>', "#{CUSTOM_CSS}#{CONFIG_LINK_JS}</head>")
        end
        headers['Content-Length'] = full_body.bytesize.to_s
      end

      [status, headers, [full_body]]
    end

    private

    # Devuelve true si el usuario es SuperAdmin de plataforma O administrador de la cuenta.
    # En ambos casos se muestra el UI completo de Chatwoot sin restricciones.
    def privileged_session?(env)
      session = env['rack.session'] || {}

      warden_key = session['warden.user.user.key']
      return false unless warden_key.is_a?(Array)

      user_id = warden_key.dig(0, 0)
      return false unless user_id

      # SuperAdmin de plataforma: siempre sin restricciones
      return true if User.where(id: user_id, type: 'SuperAdmin').exists?

      # Administrador de cualquier cuenta: sin restricciones
      # No dependemos del path porque en la carga inicial puede ser solo /app
      AccountUser.where(user_id: user_id, role: 'administrator').exists?
    rescue StandardError
      false
    end
  end
end
