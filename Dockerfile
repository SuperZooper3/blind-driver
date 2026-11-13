# Railway's frontend service builds the game; the final image only serves files.
FROM debian:bookworm-slim AS export
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip libfontconfig1 libx11-6 libxcursor1 libxinerama1 libxi6 libxrandr2 libgl1 libasound2 libpulse0 nodejs && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp/godot
RUN curl -fsSL --retry 3 https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip -o editor.zip \
    && echo '9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65  editor.zip' | sha512sum -c - \
    && unzip -q editor.zip && mv Godot_v4.7.2-stable_linux.x86_64 /usr/local/bin/godot && rm editor.zip
RUN curl -fsSL --retry 3 https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz -o templates.tpz \
    && echo 'ca4d71c4d7b81dfc15d1a98baa07534aa95b03fdda78a0075b06672e1648d2e5f40980c9adc28d23e1b92e732ee7bf3461997aa804af74ec2fcd7a93ccb84079  templates.tpz' | sha512sum -c - \
    && mkdir -p /root/.local/share/godot/export_templates/4.7.2.stable \
    && unzip -j -q templates.tpz 'templates/web*' -d /root/.local/share/godot/export_templates/4.7.2.stable && rm templates.tpz
WORKDIR /project
COPY project.godot export_presets.cfg icon.svg ./
COPY scenes/ scenes/
COPY scripts/ scripts/
COPY shaders/ shaders/
COPY frontend/ frontend/
COPY tools/export_web.sh tools/export_web.sh
RUN bash tools/export_web.sh

FROM node:24-bookworm-slim
ENV NODE_ENV=production PORT=8080
WORKDIR /app
COPY --from=export /project/build/web/ build/web/
COPY frontend/server.mjs frontend/server.mjs
COPY server/protocol.mjs server/protocol.mjs
USER node
EXPOSE 8080
CMD ["node", "frontend/server.mjs"]
