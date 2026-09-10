FROM debian:trixie

COPY infra /opt/schermes/infra
RUN /opt/schermes/infra/install.sh

CMD ["sleep", "infinity"]
