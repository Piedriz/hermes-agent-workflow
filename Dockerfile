# =============================================================================
# Jarvis Agent — Dockerfile
# Hereda de la imagen oficial de Hermes Agent
# Solo añade nuestra configuracion personalizada encima
# =============================================================================

FROM nousresearch/hermes-agent:latest

# Semilla para inicializar el volumen en Railway (no se pisa si el volumen ya tiene datos)
COPY config/ /opt/seed/
COPY config/ /opt/data/

ENV HERMES_HOME=/opt/data
