FROM node:22-alpine AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
# CA bundle so the app can verify the RDS server certificate (RDS only accepts TLS connections)
ADD https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /app/rds-ca.pem
# ADD gives downloaded files mode 600 (root only); the app runs as 'node', so make it readable
RUN chmod 644 /app/rds-ca.pem
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
USER node
EXPOSE 3000
CMD ["node", "src/server.js"]
