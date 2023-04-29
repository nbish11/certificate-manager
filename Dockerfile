# version 3.0.6
FROM neilpang/acme.sh@sha256:ae7c0d1138e0499f45cb8ebf65fdc31dd3c1247d7e9841fe0ec97501493435cf

LABEL org.opencontainers.image.authors="Nathan Bishop <nbish11@hotmail.com>"
LABEL org.opencontainers.image.url="https://github.com/nbish11/certificate-manager"
LABEL org.opencontainers.image.documentation="https://github.com/nbish11/certificate-manager/wiki"
LABEL org.opencontainers.image.source="https://github.com/nbish11/certificate-manager"
LABEL org.opencontainers.image.vendor="Nathan Bishop"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.title="Certificate Manager"
LABEL org.opencontainers.image.description="Manage certificates for Docker containers automatically, issuing and renewing them via the ACME protocol (Let's Encrypt)."
LABEL org.opencontainers.image.base.name="docker.io/neilpang/acme.sh"

RUN apk --no-cache add -f docker

COPY rootfs /
RUN chown root:root /certificate-manager.sh && chmod +x /certificate-manager.sh

ENTRYPOINT [ "/certificate-manager.sh" ]

CMD [ "start" ]
