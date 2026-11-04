# App Flutter Web — produção no Dokploy.
# O bridge é injetado em build time via --dart-define; o nginx serve o SPA.

FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /app
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get

COPY app/ ./

ARG NERUDS_BRIDGE_URL=https://api.neruds.org
ARG NERUDS_PORTAL_URL=https://neruds.org

# --no-tree-shake-icons: o flutter_quill resolve iconData dinamicamente
# (records/funções), então o shaker remove os glifos B/I/U/listas/link
# do subset de fonte — a toolbar renderiza invisível em produção.
RUN flutter build web --release --no-wasm-dry-run --no-tree-shake-icons \
      --dart-define=NERUDS_BRIDGE_URL=${NERUDS_BRIDGE_URL} \
      --dart-define=NERUDS_PORTAL_URL=${NERUDS_PORTAL_URL}

FROM nginx:1.27-alpine
COPY deploy/dokploy/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build/web /usr/share/nginx/html

EXPOSE 80
