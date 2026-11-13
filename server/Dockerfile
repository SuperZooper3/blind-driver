FROM node:24-bookworm-slim
ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY index.mjs protocol.mjs diagnostics.html ./
USER node
EXPOSE 10000
CMD ["node", "index.mjs"]
