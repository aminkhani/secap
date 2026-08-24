# ── Stage 1: development ─────────────────────────────────────
FROM node:20-alpine AS development

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .

ARG DOCS_URL
ENV DOCS_URL=${DOCS_URL}

EXPOSE 3000
CMD ["npm", "start", "--", "--host", "0.0.0.0"]

# ── Stage 2: builder (for production) ──────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

COPY package*.json ./
RUN npm ci

ARG DOCS_URL
ENV DOCS_URL=${DOCS_URL}

COPY . .
RUN npm run build

# ── Stage 3: production (static file server) ──────────────────
FROM nginx:1.27-alpine AS production

COPY --from=builder /app/build /usr/share/nginx/html

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
