# =============================================================================
# Jarvis Agent — Dockerfile
# Hereda de la imagen oficial de Hermes Agent
# Solo añade nuestra configuracion personalizada encima
# =============================================================================

FROM nousresearch/hermes-agent:latest

# Semilla para inicializar el volumen en Railway
COPY config/ /opt/seed/
# Tambien copiar skills a la ruta correcta dentro de la semilla
COPY skills/ /opt/seed/skills/

ENV HERMES_HOME=/opt/data
