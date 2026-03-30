# ── Etapa 1: Copiar archivos estáticos ──
FROM nginx:alpine AS production

# Eliminar configuración por defecto de Nginx
RUN rm -rf /usr/share/nginx/html/*

# Copiar archivos del sitio estático
COPY km-data-solutions.html /usr/share/nginx/html/index.html

# Configuración personalizada de Nginx
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Exponer puerto 80 (interno del contenedor)
EXPOSE 80

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://localhost/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
