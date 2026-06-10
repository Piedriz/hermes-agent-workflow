# =============================================================================
# Jarvis Agent — Dockerfile
# Hereda de la imagen oficial de Hermes Agent
# Solo añade nuestra configuracion personalizada encima
# =============================================================================

FROM nousresearch/hermes-agent:latest

COPY config/ /opt/data/

ENV HERMES_HOME=/opt/data
